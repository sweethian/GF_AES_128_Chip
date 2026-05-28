<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This project is a compact **AES-128 encryption core** with a byte-serial
interface, designed to fit Tiny Tapeout's limited pin budget. Because a full
AES block uses 128-bit key, 128-bit plaintext, and 128-bit ciphertext —
far more than the available I/O — all data is streamed one byte at a time.

The design is built for **minimum area**: it uses a single shared S-box
(`NUM_SBOX = 1`) and the iterative (multi-cycle) controller rather than an
unrolled or pipelined datapath, trading throughput for silicon area.

Internally an FSM (`AES_serial_wrapper`) manages three phases:

1. **Load (IDLE):** On every clock where `shift_enable` is high, the byte on
   `ui_in` is shifted into a 256-bit input register. You load **32 bytes
   total** — the **16-byte key first**, then the **16-byte plaintext**, each
   sent **most-significant byte first**. After the 32nd byte, the core starts
   automatically.

2. **Compute (RUN):** The AES core performs the encryption rounds. The `busy`
   output is high during this phase. When finished, `done` goes high and the
   128-bit ciphertext is latched into an output register.

3. **Unload (DONE):** The most-significant byte of the ciphertext appears on
   `uo_out`. Each clock where `shift_enable` is high shifts the next byte out,
   most-significant byte first, for 16 bytes. The FSM then returns to IDLE,
   ready for the next block.

**Pin usage**

| Signal        | Pin         | Direction | Description                          |
|---------------|-------------|-----------|--------------------------------------|
| `ui_in[7:0]`  | dedicated in  | in      | Serial data byte (key/plaintext in) |
| `uio_in[0]`   | bidir       | in        | `shift_enable` — clocks a byte in/out |
| `uo_out[7:0]` | dedicated out | out     | Serial data byte (ciphertext out)   |
| `uio_out[1]`  | bidir       | out       | `busy` (high during computation)    |
| `uio_out[2]`  | bidir       | out       | `done` (high when result ready)     |

The reset (`rst_n`) is **active-low** and synchronous: hold it low to clear
the FSM and all registers to a known state before loading data.

## How to test

The core is verified against the **NIST CAVS AES-128 ECB known-answer
vectors** (`ECBVarKey128.rsp` and `ECBVarTxt128.rsp`) using the cocotb
testbench in this project. Each vector loads a key and plaintext and checks
that the streamed-out ciphertext matches the expected value.

To exercise the design (in simulation or on hardware), follow the protocol:

1. **Reset:** Drive `rst_n` low for several clock cycles, then release it
   high. Keep `ena` high (it is always high when the design is selected).

2. **Load key (16 bytes):** For each key byte, most-significant byte first,
   place it on `ui_in`, set `shift_enable` (`uio_in[0]`) high, and pulse the
   clock once.

3. **Load plaintext (16 bytes):** Immediately continue with the 16 plaintext
   bytes the same way, most-significant byte first. The 32nd byte
   automatically starts encryption.

4. **Wait for completion:** Deassert `shift_enable`. Wait until `done`
   (`uio_out[2]`) goes high. `busy` (`uio_out[1]`) is high while computing.

5. **Read ciphertext (16 bytes):** Read the byte on `uo_out`, then pulse the
   clock once with `shift_enable` high to advance to the next byte. Repeat
   for all 16 bytes, most-significant byte first.

**Worked example** (first VarKey vector):
`KEY = 80000000000000000000000000000000`,
`PLAINTEXT = 00000000000000000000000000000000`
should produce
`CIPHERTEXT = 0edd33d3c621e546455bd8ba1418bec8`.

To run the included simulation:

```sh

## External hardware
None

List external hardware used in your project (e.g. PMOD, LED display, etc), if any
