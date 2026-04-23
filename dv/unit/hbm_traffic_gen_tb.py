# NOTE: Requires cocotb and cocotbext-axi — not installed in CI.
# Run manually with: make -f Makefile.hbm_traffic_gen
# Requires: cocotb, cocotbext-axi
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

@cocotb.test()
async def hbm_traffic_gen_writes_then_reads(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    dut.rstn.value = 0
    dut.start.value = 0
    dut.num_bytes.value = 0x10000
    await Timer(20, "ns")
    dut.rstn.value = 1
    dut.start.value = 1
    deadline = 0
    while not dut.done.value and deadline < 100000:
        await RisingEdge(dut.clk)
        deadline += 1
    assert dut.done.value, "hbm_traffic_gen never asserted done"
    assert int(dut.axi_errors.value) == 0
    assert int(dut.data_mismatches.value) == 0
