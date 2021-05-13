-- #################################################################################################
-- # RISC-V Debug Transport Module (DTM) - compatible to the RISC-V debug specification            #
-- # ********************************************************************************************* #
-- # Provides a JTAG-compatible TAP to access the DMI register interface.                          #
-- # ********************************************************************************************* #
-- # BSD 3-Clause License                                                                          #
-- #                                                                                               #
-- # Copyright (c) 2021, Stephan Nolting. All rights reserved.                                     #
-- #                                                                                               #
-- # Redistribution and use in source and binary forms, with or without modification, are          #
-- # permitted provided that the following conditions are met:                                     #
-- #                                                                                               #
-- # 1. Redistributions of source code must retain the above copyright notice, this list of        #
-- #    conditions and the following disclaimer.                                                   #
-- #                                                                                               #
-- # 2. Redistributions in binary form must reproduce the above copyright notice, this list of     #
-- #    conditions and the following disclaimer in the documentation and/or other materials        #
-- #    provided with the distribution.                                                            #
-- #                                                                                               #
-- # 3. Neither the name of the copyright holder nor the names of its contributors may be used to  #
-- #    endorse or promote products derived from this software without specific prior written      #
-- #    permission.                                                                                #
-- #                                                                                               #
-- # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS   #
-- # OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF               #
-- # MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE    #
-- # COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,     #
-- # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE #
-- # GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED    #
-- # AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING     #
-- # NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED  #
-- # OF THE POSSIBILITY OF SUCH DAMAGE.                                                            #
-- # ********************************************************************************************* #
-- # https://github.com/stnolting/riscv-debug-dtm                              (c) Stephan Nolting #
-- #################################################################################################

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity riscv_debug_dtm is
  generic (
    IDCODE_VERSION : std_ulogic_vector(03 downto 0) := x"0"; -- version
    IDCODE_PARTID  : std_ulogic_vector(15 downto 0) := x"cafe"; -- part number
    IDCODE_MANID   : std_ulogic_vector(10 downto 0) := "00000000000" -- manufacturer id
  );
  port (
    -- global control --
    clk_i             : in  std_ulogic; -- global clock line
    rstn_i            : in  std_ulogic; -- global reset line, low-active
    -- jtag connection --
    jtag_trst_i       : in  std_ulogic;
    jtag_tck_i        : in  std_ulogic;
    jtag_tdi_i        : in  std_ulogic;
    jtag_tdo_o        : out std_ulogic;
    jtag_tms_i        : in  std_ulogic;
    -- debug module interface (DMI) --
    dmi_rstn_o        : out std_ulogic;
    dmi_req_valid_o   : out std_ulogic;
    dmi_req_ready_i   : in  std_ulogic; -- DMI is allowed to make new requests when set
    dmi_req_addr_o    : out std_ulogic_vector(06 downto 0);
    dmi_req_op_o      : out std_ulogic; -- 0=read, 1=write
    dmi_req_data_o    : out std_ulogic_vector(31 downto 0);
    dmi_resp_valid_i  : in  std_ulogic; -- response valid when set
    dmi_resp_ready_o  : out std_ulogic; -- ready to receive respond
    dmi_resp_data_i   : in  std_ulogic_vector(31 downto 0);
    dmi_resp_err_i    : in  std_ulogic -- 0=ok, 1=error
  );
end riscv_debug_dtm;

architecture riscv_debug_dtm_rtl of riscv_debug_dtm is

  -- DMI Configuration (fixed!) --
  constant dmi_idle_c    : std_ulogic_vector(02 downto 0) := "010"; -- minimum number if idle cycles
  constant dmi_version_c : std_ulogic_vector(03 downto 0) := "0001"; -- version (0.13)
  constant dmi_abits_c   : std_ulogic_vector(05 downto 0) := "000111"; -- number of DMI address bits (7)

  -- tap controller - fsm --
  type tap_ctrl_state_t is (LOGIC_RESET, DR_SCAN, DR_CAPTURE, DR_SHIFT, DR_EXIT1, DR_PAUSE, DR_EXIT2, DR_UPDATE,
                               RUN_IDLE, IR_SCAN, IR_CAPTURE, IR_SHIFT, IR_EXIT1, IR_PAUSE, IR_EXIT2, IR_UPDATE);
  type tap_ctrl_t is record
    state      : tap_ctrl_state_t;
    state_prev : tap_ctrl_state_t;
    trst_sync  : std_ulogic_vector(01 downto 0);
    tck_sync   : std_ulogic_vector(02 downto 0);
    tdi_sync   : std_ulogic_vector(01 downto 0);
    tdo_sync   : std_ulogic;
    tms_sync   : std_ulogic_vector(01 downto 0);
  end record;
  signal tap_ctrl : tap_ctrl_t;

  -- tap registers --
  type tap_reg_t is record
    ireg             : std_ulogic_vector(04 downto 0);
    bypass           : std_ulogic;
    idcode           : std_ulogic_vector(31 downto 0);
    dtmcs, dtmcs_nxt : std_ulogic_vector(31 downto 0);
    dmi,   dmi_nxt   : std_ulogic_vector((7+32+2)-1 downto 0); -- 7-bit address + 32-bit data + 2-bit operation
  end record;
  signal tap_reg : tap_reg_t;

  -- debug module interface --
  type dmi_ctrl_state_t is (DMI_IDLE, DMI_READ_WAIT, DMI_READ, DMI_READ_BUSY,
                            DMI_WRITE_WAIT, DMI_WRITE, DMI_WRITE_BUSY);
  type dmi_ctrl_t is record
    state        : dmi_ctrl_state_t;
    --
    dmihardreset : std_ulogic;
    dmireset     : std_ulogic;
    --
    err          : std_ulogic; -- sticky error
    rdata        : std_ulogic_vector(31 downto 0);
    wdata        : std_ulogic_vector(31 downto 0);
    addr         : std_ulogic_vector(06 downto 0);
  end record;
  signal dmi_ctrl : dmi_ctrl_t;

begin

  -- Tap Control FSM ------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  tap_control: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      tap_ctrl.trst_sync <= (others => '0');
      tap_ctrl.tck_sync  <= (others => '0');
      tap_ctrl.tdi_sync  <= (others => '0');
      tap_ctrl.tms_sync  <= (others => '0');
      jtag_tdo_o         <= '0';
      --
      tap_ctrl.state      <= LOGIC_RESET;
      tap_ctrl.state_prev <= LOGIC_RESET;
    elsif rising_edge(clk_i) then
      -- synchronizer --
      tap_ctrl.trst_sync <= tap_ctrl.trst_sync(0) & jtag_trst_i;
      tap_ctrl.tck_sync  <= tap_ctrl.tck_sync(1 downto 0) & jtag_tck_i;
      tap_ctrl.tdi_sync  <= tap_ctrl.tdi_sync(0) & jtag_tdi_i;
      tap_ctrl.tms_sync  <= tap_ctrl.tms_sync(0) & jtag_tms_i;
      jtag_tdo_o         <= tap_ctrl.tdo_sync;

      -- state machine --
      tap_ctrl.state_prev <= tap_ctrl.state;
      if (tap_ctrl.trst_sync(1) = '0') then -- reset
        tap_ctrl.state <= LOGIC_RESET;
      elsif (tap_ctrl.tck_sync(2) = '0') and (tap_ctrl.tck_sync(1) = '1') then -- clock pulse (trigger on rising edge)
        case tap_ctrl.state is -- JTAG state machine
          when LOGIC_RESET => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= RUN_IDLE;   else tap_ctrl.state <= LOGIC_RESET; end if;
          when RUN_IDLE    => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= RUN_IDLE;   else tap_ctrl.state <= DR_SCAN;     end if;
          when DR_SCAN     => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= DR_CAPTURE; else tap_ctrl.state <= IR_SCAN;     end if;
          when DR_CAPTURE  => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= DR_SHIFT;   else tap_ctrl.state <= DR_EXIT1;    end if;
          when DR_SHIFT    => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= DR_SHIFT;   else tap_ctrl.state <= DR_EXIT1;    end if;
          when DR_EXIT1    => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= DR_PAUSE;   else tap_ctrl.state <= DR_UPDATE;   end if;
          when DR_PAUSE    => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= DR_PAUSE;   else tap_ctrl.state <= DR_EXIT2;    end if;
          when DR_EXIT2    => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= DR_SHIFT;   else tap_ctrl.state <= DR_UPDATE;   end if;
          when DR_UPDATE   => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= RUN_IDLE;   else tap_ctrl.state <= DR_SCAN;     end if;
          when IR_SCAN     => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= IR_CAPTURE; else tap_ctrl.state <= LOGIC_RESET; end if;
          when IR_CAPTURE  => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= IR_SHIFT;   else tap_ctrl.state <= IR_EXIT1;    end if;
          when IR_SHIFT    => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= IR_SHIFT;   else tap_ctrl.state <= IR_EXIT1;    end if;
          when IR_EXIT1    => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= IR_PAUSE;   else tap_ctrl.state <= IR_UPDATE;   end if;
          when IR_PAUSE    => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= IR_PAUSE;   else tap_ctrl.state <= IR_EXIT2;    end if;
          when IR_EXIT2    => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= IR_SHIFT;   else tap_ctrl.state <= IR_UPDATE;   end if;
          when IR_UPDATE   => if (tap_ctrl.tms_sync(1) = '0') then tap_ctrl.state <= RUN_IDLE;   else tap_ctrl.state <= DR_SCAN;     end if;
          when others      => tap_ctrl.state <= LOGIC_RESET;
        end case;
      end if;
    end if;
  end process tap_control;


  -- Tap Register Access --------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  reg_access: process(clk_i)
  begin
    if rising_edge(clk_i) then
      if (tap_ctrl.trst_sync(1) = '0') then -- reset
        tap_reg.ireg <= "00001"; -- IDCODE
      elsif (tap_ctrl.tck_sync(2) = '0') and (tap_ctrl.tck_sync(1) = '1') then -- clock pulse (trigger on rising edge)

        -- instruction register --
        if (tap_ctrl.state = LOGIC_RESET) then -- reset
          tap_reg.ireg <= "00001"; -- IDCODE
        elsif (tap_ctrl.state = IR_CAPTURE) then -- preload phase
          tap_reg.ireg <= "00001"; -- IDCODE
        elsif (tap_ctrl.state = IR_SHIFT) then -- access phase
          tap_reg.ireg <= tap_ctrl.tdi_sync(1) & tap_reg.ireg(tap_reg.ireg'left downto 1);
        end if;

        -- data register --
        if (tap_ctrl.state = DR_CAPTURE) then -- preload phase
          case tap_reg.ireg is
            when "00001" => tap_reg.idcode <= IDCODE_VERSION & IDCODE_PARTID & IDCODE_MANID & '1'; -- IDCODE (LBS has to be always set!)
            when "10000" => tap_reg.dtmcs  <= tap_reg.dtmcs_nxt;-- dtmcs
            when "10001" => tap_reg.dmi    <= tap_reg.dmi_nxt; -- dmi
            when others  => tap_reg.bypass <= '0'; -- BYPASS
          end case;
        elsif (tap_ctrl.state = DR_SHIFT) then -- access phase
          case tap_reg.ireg is
            when "00001" => tap_reg.idcode <= tap_ctrl.tdi_sync(1) & tap_reg.idcode(tap_reg.idcode'left downto 1); -- IDCODE
            when "10000" => tap_reg.dtmcs  <= tap_ctrl.tdi_sync(1) & tap_reg.dtmcs(tap_reg.dtmcs'left downto 1); -- dtmcs
            when "10001" => tap_reg.dmi    <= tap_ctrl.tdi_sync(1) & tap_reg.dmi(tap_reg.dmi'left downto 1); -- dmi
            when others  => tap_reg.bypass <= tap_ctrl.tdi_sync(1); -- BYPASS
          end case;
        end if;
      end if;

      -- serial data output --
      if (tap_ctrl.state = IR_SHIFT) then
        tap_ctrl.tdo_sync <= tap_reg.ireg(0);
      else
        case tap_reg.ireg is
          when "00001" => tap_ctrl.tdo_sync <= tap_reg.idcode(0); -- IDCODE
          when "10000" => tap_ctrl.tdo_sync <= tap_reg.dtmcs(0); -- dtmcs
          when "10001" => tap_ctrl.tdo_sync <= tap_reg.dmi(0); -- dmi
          when others  => tap_ctrl.tdo_sync <= tap_reg.bypass; -- BYPASS
        end case;
      end if;
    end if;
  end process reg_access;


  -- Debug Module Interface -----------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------

  -- DTM Control and Status Register (dtmcs) --
  tap_reg.dtmcs_nxt(31 downto 18) <= (others => '0'); -- unused
  tap_reg.dtmcs_nxt(17)           <= '0'; -- dmihardreset, always reads as zero
  tap_reg.dtmcs_nxt(16)           <= '0'; -- dmireset, always reads as zero
  tap_reg.dtmcs_nxt(15)           <= '0'; -- unused
  tap_reg.dtmcs_nxt(14 downto 12) <= dmi_idle_c; -- minimum number if idle cycles
  tap_reg.dtmcs_nxt(11 downto 10) <= tap_reg.dmi_nxt(1 downto 0); -- dmistat
  tap_reg.dtmcs_nxt(09 downto 04) <= dmi_abits_c; -- number of DMI address bits
  tap_reg.dtmcs_nxt(03 downto 00) <= dmi_version_c; -- version


  -- Debug Module Interface Access Register (dmi) --
  dmi_controller: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      dmi_ctrl.state        <= DMI_IDLE;
      dmi_ctrl.dmihardreset <= '1';
      dmi_ctrl.dmireset     <= '1';
      dmi_ctrl.err          <= '0';
      dmi_ctrl.rdata        <= (others => '-');
      dmi_ctrl.wdata        <= (others => '-');
      dmi_ctrl.addr         <= (others => '-');
    elsif rising_edge(clk_i) then

      -- DMI status and control --
      dmi_ctrl.dmihardreset <= '0'; -- default
      dmi_ctrl.dmireset     <= '0'; -- default
      if (tap_ctrl.state = DR_UPDATE) and (tap_ctrl.state_prev /= DR_UPDATE) and (tap_reg.ireg = "10000") then
        dmi_ctrl.dmireset     <= tap_reg.dtmcs(16);
        dmi_ctrl.dmihardreset <= tap_reg.dtmcs(17);
      end if;

      -- DMI interface arbiter --
      if (dmi_ctrl.dmihardreset = '1') then -- DMI hard reset
        dmi_ctrl.state <= DMI_IDLE;
        dmi_ctrl.err   <= '0';
      else
        case dmi_ctrl.state is

          when DMI_IDLE => -- waiting for new request
            if (tap_ctrl.state = DR_UPDATE) and (tap_ctrl.state_prev /= DR_UPDATE) and (tap_reg.ireg = "10001") then -- update <dmi>
              case tap_reg.dmi(1 downto 0) is -- op field
                when "01"   => dmi_ctrl.state <= DMI_READ_WAIT; -- read
                when "10"   => dmi_ctrl.state <= DMI_WRITE_WAIT; -- write
                when others => NULL;
              end case;
              dmi_ctrl.addr   <= tap_reg.dmi(40 downto 34);
              dmi_ctrl.wdata  <= tap_reg.dmi(33 downto 02);
            end if;

          when DMI_READ_WAIT => -- wait for DMI to become ready
            if (dmi_req_ready_i = '1') then
              dmi_ctrl.state <= DMI_READ;
            end if;

          when DMI_READ => -- start read access
            dmi_ctrl.state <= DMI_READ_BUSY;

          when DMI_READ_BUSY => -- pending read access
            if (dmi_resp_valid_i = '1') then
              dmi_ctrl.rdata <= dmi_resp_data_i;
              dmi_ctrl.err   <= dmi_ctrl.err or dmi_resp_err_i; -- sticky error
              dmi_ctrl.state <= DMI_IDLE;
            end if;

          when DMI_WRITE_WAIT => -- wait for DMI to become ready
            if (dmi_req_ready_i = '1') then
              dmi_ctrl.state <= DMI_WRITE;
            end if;

          when DMI_WRITE => -- start write access
            dmi_ctrl.state <= DMI_WRITE_BUSY;

          when DMI_WRITE_BUSY => -- pending write access
            if (dmi_resp_valid_i = '1') then
              dmi_ctrl.err   <= dmi_ctrl.err or dmi_resp_err_i; -- sticky error
              dmi_ctrl.state <= DMI_IDLE;
            end if;

          when others => -- undefined
            dmi_ctrl.state <= DMI_IDLE;

        end case;
        -- override sticky error flag --
        if (dmi_ctrl.dmireset = '1') then
          dmi_ctrl.err <= '0';
        end if;
      end if;
    end if;
  end process dmi_controller;

  -- DMI register read access --
  tap_reg.dmi_nxt(40 downto 34) <= dmi_ctrl.addr; -- address
  tap_reg.dmi_nxt(33 downto 02) <= dmi_ctrl.rdata; -- read data
  tap_reg.dmi_nxt(01 downto 00) <= "11" when (dmi_ctrl.state /= DMI_IDLE) else (dmi_ctrl.err & '0'); -- status

  -- direct DMI output --
  dmi_rstn_o       <= '0' when (dmi_ctrl.dmihardreset = '1') else '1';
  dmi_req_valid_o  <= '1' when (dmi_ctrl.state = DMI_READ) or (dmi_ctrl.state = DMI_WRITE) else '0';
  dmi_req_op_o     <= '1' when (dmi_ctrl.state = DMI_WRITE) or (dmi_ctrl.state = DMI_WRITE_BUSY) else '0';
  dmi_resp_ready_o <= '1' when (dmi_ctrl.state = DMI_READ_BUSY) or (dmi_ctrl.state = DMI_WRITE_BUSY) else '0';
  dmi_req_addr_o   <= dmi_ctrl.addr;
  dmi_req_data_o   <= dmi_ctrl.wdata;


end riscv_debug_dtm_rtl;
