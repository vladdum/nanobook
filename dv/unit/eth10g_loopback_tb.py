# dv/unit/eth10g_loopback_tb.py
# Requires: cocotb, cocotbext-eth
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


@cocotb.test()
async def loopback_idles_on_reset(dut):
    cocotb.start_soon(Clock(dut.clk, 6.4, units="ns").start())
    dut.rst.value = 1
    dut.xgmii_rxd.value = 0xDEADBEEFDEADBEEF
    dut.xgmii_rxc.value = 0x00
    await Timer(50, "ns")
    await RisingEdge(dut.clk)
    assert dut.xgmii_txd.value == 0x0707070707070707
    assert dut.xgmii_txc.value == 0xFF


@cocotb.test()
async def loopback_copies_rx_to_tx(dut):
    cocotb.start_soon(Clock(dut.clk, 6.4, units="ns").start())
    dut.rst.value = 0
    test_data = 0xCAFEBABEDEADBEEF
    dut.xgmii_rxd.value = test_data
    dut.xgmii_rxc.value = 0x01
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    assert dut.xgmii_txd.value == test_data
    assert dut.xgmii_txc.value == 0x01
