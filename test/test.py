# SPDX-FileCopyrightText: © 2026 Goh Swee Thian, Shahum Saeed
# SPDX-License-Identifier: Apache-2.0
"""
Cocotb 2.x testbench for tt_um_sweethian_aes.

Byte-serial AES wrapper, checked against NIST CAVS AES-128 ECB known-answer
vectors (ECBVarKey128.rsp, ECBVarTxt128.rsp).

Protocol (from AES_serial_wrapper):
  INPUT  (S_IDLE): each clk with shift_enable=1 shifts ui_in into shift_reg_in
                   from the LSB end. Feed 32 bytes: KEY (16, MSB-first) then
                   PLAINTEXT (16, MSB-first). 32nd byte auto-fires start.
  RUN    (S_RUN):  wait for done = uio_out[2].
  OUTPUT (S_DONE): uo_out shows ciphertext MSB byte; each clk with
                   shift_enable=1 advances by one byte. Read 16 bytes.

Pin map:
  ui_in      = serial_in
  uio_in[0]  = shift_enable      (the ONLY uio pin the design treats as input)
  uo_out     = serial_out
  uio_out[1] = busy , uio_out[2] = done

Reset is ACTIVE-LOW (rst_n = 0 to reset).
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, Timer

# Settle delay (optional, after FallingEdge sampling is the real safeguard).
# Ceiling: must be < one clock period. At 100 MHz period=10 ns -> keep < 10 ns.
# At a 10 MHz target, period=100 ns -> ceiling < 100 ns. Default 0 because we
# sample relative to FallingEdge, which already avoids the rising-edge race.
SETTLE_NS = int(os.environ.get("SETTLE_NS", "0"))

BUSY_BIT = 1
DONE_BIT = 2


def hexstr_to_bytes(s):
    b = bytes.fromhex(s.strip())
    assert len(b) == 16, f"expected 16 bytes, got {len(b)} from {s!r}"
    return list(b)


def parse_rsp(path):
    """Return [(key, plaintext, cipher)] hex triples under [ENCRYPT]."""
    vectors, in_encrypt = [], False
    key = pt = None
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("["):
                in_encrypt = line.upper() == "[ENCRYPT]"
                continue
            if not in_encrypt:
                continue
            if line.startswith("KEY"):
                key = line.split("=", 1)[1].strip()
            elif line.startswith("PLAINTEXT"):
                pt = line.split("=", 1)[1].strip()
            elif line.startswith("CIPHERTEXT"):
                ct = line.split("=", 1)[1].strip()
                if key is not None and pt is not None:
                    vectors.append((key, pt, ct))
                key = pt = None
    assert vectors, f"no ENCRYPT vectors parsed from {path}"
    return vectors


def read_byte_safe(sig):
    """Read an 8-bit signal as int, raising a clear error on x/z."""
    val = sig.value
    if not val.is_resolvable:        # contains x or z
        raise AssertionError(f"unresolved (x/z) value on {sig._name}: {val!r}")
    return int(val) & 0xFF


def read_bit(sig, bit):
    """Read a single bit; treat unresolved as 0 only after reset is safe."""
    val = sig.value
    if not val.is_resolvable:
        # During steady operation this shouldn't happen on busy/done; surface it
        raise AssertionError(f"unresolved (x/z) on {sig._name}[{bit}]: {val!r}")
    return (int(val) >> bit) & 1


async def reset_dut(dut):
    """Active-low reset; hold long enough to clear x before any read."""
    dut._log.info("Reset (active-low)")
    dut.ena.value = 1                 # always 1 when device is powered
    dut.ui_in.value = 0
    dut.uio_in.value = 0              # shift_enable (bit 0) low; others unused
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def set_shift_enable(dut, on):
    """Drive ONLY uio_in[0]; never touch bits the design drives."""
    dut.uio_in.value = 1 if on else 0


async def shift_in_byte(dut, byte_val):
    """Change inputs after FallingEdge so they're stable at next RisingEdge."""
    await FallingEdge(dut.clk)
    dut.ui_in.value = byte_val
    dut.uio_in.value = 1              # shift_enable = uio_in[0]
    await ClockCycles(dut.clk, 1)     # rising edge samples the byte


async def run_vector(dut, key_hex, pt_hex, exp_hex, label=""):
    key = hexstr_to_bytes(key_hex)
    pt = hexstr_to_bytes(pt_hex)
    exp = hexstr_to_bytes(exp_hex)

    await reset_dut(dut)

    # INPUT: KEY then PLAINTEXT, each MSB-first (32 bytes total)
    for b in key + pt:
        await shift_in_byte(dut, b)

    # stop shifting
    await FallingEdge(dut.clk)
    dut.uio_in.value = 0
    dut.ui_in.value = 0

    # WAIT for done
    timeout = 0
    while True:
        await ClockCycles(dut.clk, 1)
        if read_bit(dut.uio_out, DONE_BIT):
            break
        timeout += 1
        assert timeout < 10000, f"{label}: timeout waiting for done"

    # OUTPUT: read 16 bytes; sample after FallingEdge, then advance one byte
    out_bytes = []
    for _ in range(16):
        await FallingEdge(dut.clk)
        if SETTLE_NS:
            await Timer(SETTLE_NS, "ns")
        out_bytes.append(read_byte_safe(dut.uo_out))
        # advance: pulse shift_enable for one clock
        dut.uio_in.value = 1
        await ClockCycles(dut.clk, 1)
        await FallingEdge(dut.clk)
        dut.uio_in.value = 0

    got_hex = bytes(out_bytes).hex()
    assert out_bytes == exp, (
        f"{label} MISMATCH\n"
        f"  KEY       = {key_hex}\n"
        f"  PLAINTEXT = {pt_hex}\n"
        f"  expected  = {exp_hex}\n"
        f"  got       = {got_hex}"
    )
    dut._log.info(f"{label} OK  ct={got_hex}")


def _path(name):
    return os.path.join(os.path.dirname(__file__), name)


@cocotb.test()
async def test_aes_known_answer(dut):
    """All NIST CAVS AES-128 ECB VarKey + VarTxt vectors, looped."""
    dut._log.info("Start AES known-answer test")
    clock = Clock(dut.clk, 10, unit="ns")     # 100 MHz sim clock
    cocotb.start_soon(clock.start())

    for fname in ("ECBVarKey128.rsp", "ECBVarTxt128.rsp"):
        vectors = parse_rsp(_path(fname))
        dut._log.info(f"{fname}: {len(vectors)} vectors")
        for i, (k, p, c) in enumerate(vectors):
            await run_vector(dut, k, p, c, label=f"{fname} COUNT={i}")

    dut._log.info("All vectors passed")