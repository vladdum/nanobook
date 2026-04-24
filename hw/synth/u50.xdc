# Alveo U50 (xcu50-fsvh2104-2-e) pin constraints for nanobook shell
# Pin assignments verified against Corundum fpga_au50.xdc (fpga_25g / fpga_100g).
# GT pins use set_property -dict {LOC ...}; regular I/O also use -dict for consistency.

# -----------------------------------------------------------------------------
# PCIe reference clock (100 MHz, MGTREFCLK0P_227 = AB9)
# Bank 227 contains the x4 PCIe lanes (GTYE4_CHANNEL_X1Y12-X1Y15).
# IBUFDS_GTE4 is instantiated in xdma_wrapper and auto-placed by Vivado
# based on this LOC — no explicit IBUFDS_GTE4 cell LOC constraint needed.
# -----------------------------------------------------------------------------
set_property -dict {LOC AB9} [get_ports pcie_refclk_p] ;# MGTREFCLK0P_227
set_property -dict {LOC AB8} [get_ports pcie_refclk_n] ;# MGTREFCLK0N_227
create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_p]

# PCIe reset (active-low, from PCIe edge connector via board pull-up)
set_property -dict {LOC AW27 IOSTANDARD LVCMOS18 PULLUP true} [get_ports pcie_rstn]
set_false_path -from [get_ports pcie_rstn]
set_input_delay 0 [get_ports pcie_rstn]

# PCIe GT lanes (x4, GTYE4_CHANNEL_X1Y12-X1Y15, bank 227)
set_property -dict {LOC AL2} [get_ports {pcie_rx_p[0]}] ;# MGTYRXP3_227 GTYE4_CHANNEL_X1Y15
set_property -dict {LOC AL1} [get_ports {pcie_rx_n[0]}]
set_property -dict {LOC Y5 } [get_ports {pcie_tx_p[0]}] ;# MGTYTXP3_227 GTYE4_CHANNEL_X1Y15
set_property -dict {LOC Y4 } [get_ports {pcie_tx_n[0]}]

set_property -dict {LOC AM4} [get_ports {pcie_rx_p[1]}] ;# MGTYRXP2_227 GTYE4_CHANNEL_X1Y14
set_property -dict {LOC AM3} [get_ports {pcie_rx_n[1]}]
set_property -dict {LOC AA7} [get_ports {pcie_tx_p[1]}] ;# MGTYTXP2_227 GTYE4_CHANNEL_X1Y14
set_property -dict {LOC AA6} [get_ports {pcie_tx_n[1]}]

set_property -dict {LOC AK4} [get_ports {pcie_rx_p[2]}] ;# MGTYRXP1_227 GTYE4_CHANNEL_X1Y13
set_property -dict {LOC AK3} [get_ports {pcie_rx_n[2]}]
set_property -dict {LOC AB5} [get_ports {pcie_tx_p[2]}] ;# MGTYTXP1_227 GTYE4_CHANNEL_X1Y13
set_property -dict {LOC AB4} [get_ports {pcie_tx_n[2]}]

set_property -dict {LOC AN2} [get_ports {pcie_rx_p[3]}] ;# MGTYRXP0_227 GTYE4_CHANNEL_X1Y12
set_property -dict {LOC AN1} [get_ports {pcie_rx_n[3]}]
set_property -dict {LOC AC7} [get_ports {pcie_tx_p[3]}] ;# MGTYTXP0_227 GTYE4_CHANNEL_X1Y12
set_property -dict {LOC AC6} [get_ports {pcie_tx_n[3]}]

# -----------------------------------------------------------------------------
# HBM reference clock (100 MHz differential from board oscillator)
# On U50 the 100 MHz board clock (BB18/BC18, LVDS) is used as HBM_REF_CLK.
# The IBUFDS in hbm_wrapper converts it to single-ended hbm_ref_clk.
# -----------------------------------------------------------------------------
set_property -dict {LOC BB18 IOSTANDARD LVDS} [get_ports hbm_refclk_p]
set_property -dict {LOC BC18 IOSTANDARD LVDS} [get_ports hbm_refclk_n]
create_clock -period 10.000 -name hbm_refclk [get_ports hbm_refclk_p]

# -----------------------------------------------------------------------------
# QSFP0 reference clock (156.25 MHz, MGTREFCLK0P_131 = N36)
# Bank 131 contains QSFP0 GTY lanes (GTYE4_CHANNEL_X0Y28-X0Y31).
# IBUFDS_GTE4 instantiated in nanobook_shell_top; auto-placed by Vivado.
# -----------------------------------------------------------------------------
set_property -dict {LOC N36} [get_ports qsfp0_refclk_p] ;# MGTREFCLK0P_131
set_property -dict {LOC N37} [get_ports qsfp0_refclk_n] ;# MGTREFCLK0N_131
create_clock -period 6.400 -name qsfp0_refclk [get_ports qsfp0_refclk_p]

# QSFP0 GT lane 0 (GTYE4_CHANNEL_X0Y28, bank 131)
set_property -dict {LOC J45} [get_ports qsfp0_rx_p] ;# MGTYRXP0_131 GTYE4_CHANNEL_X0Y28
set_property -dict {LOC J46} [get_ports qsfp0_rx_n]
set_property -dict {LOC D42} [get_ports qsfp0_tx_p] ;# MGTYTXP0_131 GTYE4_CHANNEL_X0Y28
set_property -dict {LOC D43} [get_ports qsfp0_tx_n]

# -----------------------------------------------------------------------------
# GPIO LEDs (LVCMOS18 — 3 physical LEDs on U50: act=E18, stat_g=E16, stat_y=F17)
# QSFP module management (modsell/resetl/lpmode/modprsl/intl) is routed via the
# U50 satellite controller (MSP430/CMS) — NOT directly to FPGA I/O pins.
# -----------------------------------------------------------------------------
set_property -dict {LOC E18 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {gpio_led[0]}]
set_property -dict {LOC E16 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {gpio_led[1]}]
set_property -dict {LOC F17 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {gpio_led[2]}]
set_false_path -to [get_ports {gpio_led[0] gpio_led[1] gpio_led[2]}]
set_output_delay 0 [get_ports {gpio_led[0] gpio_led[1] gpio_led[2]}]

# HBM catastrophic over-temperature output (J18) — board safety: must be driven low.
# Driving high indicates over-temperature and forces a card power-off; tie to GND.
set_property -dict {LOC J18 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports hbm_cattrip]
set_false_path -to [get_ports hbm_cattrip]
set_output_delay 0 [get_ports hbm_cattrip]
