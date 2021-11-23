# RISC-V Debug Transport Module (DTM)

[![License](https://img.shields.io/github/license/stnolting/riscv-debug-dtm)](https://github.com/stnolting/riscv-debug-dtm/blob/main/LICENSE)

This project implements a JTAG-base *debug transport module* (DTM) for the RISC-V on-chip debugger that can connect to a *RISC-V debug module* (DM)
via the *debug module interface* (DMI).
The DTM is compatible to the official [RISC-V debug specification](https://github.com/riscv/riscv-debug-spec) (version 0.13)
and can be used with the [RISC-V port of OpenOCD](https://github.com/riscv/riscv-openocd). Prebuilt RISC-V binaries of the OpenOCD port
can be obtained from [SiFive](https://www.sifive.com/software). However, the upstream openOCD version also provides built-in
RISC-V support.

The DTM is written in plain synthesizable VHDL and does not require any further modules or special libraries.
It is not limited to the RISC-V debug specification. You can also use it as general purpose *JTAG-to-register-interface* interface
to control fancy LEDs or to interact with your non-RISC-V FPGA logic.

:information_source: This project is a "spin-off" project of the [NEORV32 RISC-V Processor](https://github.com/stnolting/neorv32), where
this DTM is used as a part of the on-chip debugger. More information regarding the DTM can be found in the
["NEORV32 Data Sheet - On-Chip Debugger (OCD)"](https://stnolting.github.io/neorv32/#_on_chip_debugger_ocd).


## Hardware Overview

The module's rtl file is [`rtl/riscv_debug_dtm.vhd`](https://github.com/stnolting/riscv-debug-dtm/blob/main/rtl/riscv_debug_dtm.vhd) and provides the following entity:

```vhdl
  entity riscv_debug_dtm is
    generic (
      IDCODE_VERSION : std_ulogic_vector(03 downto 0); -- version
      IDCODE_PARTID  : std_ulogic_vector(15 downto 0); -- part number
      IDCODE_MANID   : std_ulogic_vector(10 downto 0)  -- manufacturer id
    );
    port (
      -- global control --
      clk_i             : in  std_ulogic;
      rstn_i            : in  std_ulogic;
      -- jtag connection --
      jtag_trst_i       : in  std_ulogic;
      jtag_tck_i        : in  std_ulogic;
      jtag_tdi_i        : in  std_ulogic;
      jtag_tdo_o        : out std_ulogic;
      jtag_tms_i        : in  std_ulogic;
      -- debug module interface (DMI) --
      dmi_rstn_o        : out std_ulogic;
      dmi_req_valid_o   : out std_ulogic;
      dmi_req_ready_i   : in  std_ulogic;
      dmi_req_addr_o    : out std_ulogic_vector(06 downto 0);
      dmi_req_op_o      : out std_ulogic;
      dmi_req_data_o    : out std_ulogic_vector(31 downto 0);
      dmi_resp_valid_i  : in  std_ulogic;
      dmi_resp_ready_o  : out std_ulogic;
      dmi_resp_data_i   : in  std_ulogic_vector(31 downto 0);
      dmi_resp_err_i    : in  std_ulogic
    );
  end riscv_debug_dtm;
```

The module requires a system clock (`clk_i`) and reset (`rstn_i`). The actual JTAG clock signal is **not** used as primary clock. Instead it is used to synchronize
JTGA accesses, while all internal operations trigger on the system clock. Hence, no additional clock domain is required when integrating this module. Nevertheless, this
reduces the maximal JTAG clock frequency as the JTAG clock (`jtag_tck_i`) has to be less than or equal to 1/4 of the system clock (`clk_i`) frequency.


### TAP Registers

JTAG access is conducted via the *instruction register* `IR`, which is 5 bit wide, and several *data registers* `DR` with different sizes. The data registers are accessed
by writing the according address to the instruction register. The following table shows the available data registers:

| Address (via `IR`) | Name     | Size [bit] | Description |
|:-------------------|:---------|:-----------|:------------|
| `00001`            | `IDCODE` | 32         | identifier, configurable via the module's generics |
| `10000`            | `DTMCS`  | 32         | *debug transport module control and status register* |
| `10001`            | `DMI`    | 41         | *debug module interface*; 7-bit address, 32-bit read/write data, 2-bit operation |
| others             | `BYPASS` | 1          | default JTAG bypass register |

:information_source: See the [RISC-V debug specification](https://github.com/riscv/riscv-debug-spec) for more information regarding the data registers and operations.


### Debug Module (DM) Interface

The *debug module interface* (DMI) is a simple register interface. The interface uses the system clock `clk_i` and is controlled via the `DMI` register.
The table below shows the signals and tries to illustrate the protocol ("Direction" is seen from the DTM):

| Signal              | Direction | Size [bit] | Description |
|:--------------------|:----------|:-----------|:------------|
| `dmi_rstn_o`        | out       | 1          | reset DMI (low-active), set/cleared via bit in `DTMCS` |
| `dmi_req_valid_o`   | out       | 1          | valid new request, high-active, active for one cycle |
| `dmi_req_ready_i`   | in        | 1          | DTM is allowed to make new request when high |
| `dmi_req_addr_o`    | out       | 7          | address of DM register for the current access |
| `dmi_req_op_o`      | out       | 1          | actual operation; `1` = write, `0` = read |
| `dmi_req_data_o`    | out       | 32         | data to write to DM register |
| `dmi_resp_valid_i`  | in        | 1          | response is valid when high, active for one cycle |
| `dmi_resp_ready_o`  | out       | 1          | DTM can accept repsonse from DM when high |
| `dmi_resp_data_i`   | in        | 32         | data read from the DM register, applied with `dmi_resp_valid_i` |
| `dmi_resp_err_i`    | in        | 1          | error during operation, applied with `dmi_resp_valid_i` |


## Usage Example

I have connected the TDM's debug module interface to a simple memory to test the read/write functionality and synthesized it for an Intel Cyclone IV FPGA (Terasic DE0-nano board).
The DTM was tested using **Open On-Chip Debugger 0.11.0-rc1+dev (SiFive OpenOCD 0.10.0-2020.12.1)** on *Windows 10* with a **FTDI FT2232H-56Q Mini Module** using the
following pin wiring:

```
  TCK:  D0
  TDI:  D1
  TDO:  D2
  TMS:  D3
  TRST: D4
```

Starting OpenOCD from the console using the provided configuration file
([`openocd\riscv_debug_ftdi.cfg`](https://github.com/stnolting/riscv-debug-dtm/blob/main/openocd/riscv_debug_ftdi.cfg)):

```
  N:\Projects\riscv-debug-dtm>openocd -f openocd\riscv_debug_ftdi.cfg
  Open On-Chip Debugger 0.11.0-rc1+dev (SiFive OpenOCD 0.10.0-2020.12.1)
  Licensed under GNU GPL v2
  For bug reports:
          https://github.com/sifive/freedom-tools/issues
  1
  Info : Listening on port 6666 for tcl connections
  Info : Listening on port 4444 for telnet connections
  Info : clock speed 100 kHz
  Info : JTAG tap: riscv.cpu tap/device found: 0x0cafe001 (mfg: 0x000 (<invalid>), part: 0xcafe, ver: 0x0)
  Error: OpenOCD only supports Debug Module version 2 (0.13) and 3 (0.14), not 0 (dmstatus=0x0). This error might be caused by a JTAG signal issue. Try reducing the JTAG clock speed.
  Warn : target riscv.cpu.0 examination failed
  Info : starting gdb server for riscv.cpu.0 on 3333
  Info : Listening on port 3333 for gdb connections
```

:information_source: The default IDCODE does not belong to any *valid* manufacturer / part number. The error shown by OpenOCD appears because OpenOCD tries
to fetch information from the RISC-V deug module (`dmstatus`). But since I am using a simple memory instead, there is no useful information to fetch. :wink:

Connect to OpenOCD via `telnet`:

```
  N:\> telnet 127.0.0.1 4444
  Open On-Chip Debugger
  >
```

Show the devices that were found while scanning the JTAG chain:

```
  > scan_chain
     TapName             Enabled  IdCode     Expected   IrLen IrCap IrMask
  -- ------------------- -------- ---------- ---------- ----- ----- ------
   0 riscv.cpu              Y     0x0cafe001 0x0cafe001     5 0x01  0x03
```

The RISC-V OpenOCD port features two command for directly reading from / writing to the debug module interface: `riscv dmi_read [address]` and `riscv dmi_write [address] [value]`.
The following example shows a read from DMI register `0x00` (which is zero after reset), followed by writing `0xdeadbeef` to that register and reading the same register again:

```
  > riscv dmi_read 0x00
  0x0
  > riscv dmi_write 0x00 0xdeadbeef
  > riscv dmi_read 0x00
  0xdeadbeef
```


## FPGA Implementation Results

FPGA: Intel Cyclone IV `EP4CE22F17C6N`

Utilization: 256 logic cells, 218 registers, running at 100MHz. No constraints were used at all.


## Legal

This project is released under the [BSD 3-Clause license](https://github.com/stnolting/riscv-debug-dtm/blob/main/LICENSE). No copyright infringement intended.
Other implied or used projects might have different licensing - see their documentation to get more information.

#### Limitation of Liability for External Links

Our website contains links to the websites of third parties ("external links"). As the
content of these websites is not under our control, we cannot assume any liability for
such external content. In all cases, the provider of information of the linked websites
is liable for the content and accuracy of the information provided. At the point in time
when the links were placed, no infringements of the law were recognisable to us. As soon
as an infringement of the law becomes known to us, we will immediately remove the
link in question.
