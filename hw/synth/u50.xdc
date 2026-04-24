# Alveo U50 (xcu50-fsvh2104-2-e) pin constraints for nanobook shell
# IMPORTANT: Verify every PACKAGE_PIN against UG1280 before first build.

# -----------------------------------------------------------------------------
# PCIe reference clock (100 MHz differential)
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN AM11 [get_ports pcie_refclk_p]
set_property PACKAGE_PIN AM10 [get_ports pcie_refclk_n]

# PCIe reset (active-low, LVCMOS18 with pull-up)
set_property PACKAGE_PIN AT30          [get_ports pcie_rstn]
set_property IOSTANDARD  LVCMOS18      [get_ports pcie_rstn]
set_property PULLUP      true          [get_ports pcie_rstn]

# -----------------------------------------------------------------------------
# HBM reference clock (100 MHz differential)
# create_clock is handled by the HBM IP; keep the set_property for pin
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN BJ43 [get_ports hbm_refclk_p]
set_property PACKAGE_PIN BJ44 [get_ports hbm_refclk_n]
create_clock -period 10.000 -name hbm_refclk [get_ports hbm_refclk_p]

# -----------------------------------------------------------------------------
# QSFP0 reference clock (156.25 MHz differential, period = 6.400 ns)
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN M11 [get_ports qsfp0_refclk_p]
set_property PACKAGE_PIN M10 [get_ports qsfp0_refclk_n]
create_clock -period 6.400 -name qsfp0_refclk [get_ports qsfp0_refclk_p]

# -----------------------------------------------------------------------------
# QSFP0 control signals (LVCMOS18)
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN BE14     [get_ports qsfp0_modsell]
set_property IOSTANDARD  LVCMOS18 [get_ports qsfp0_modsell]

set_property PACKAGE_PIN AT20     [get_ports qsfp0_resetl]
set_property IOSTANDARD  LVCMOS18 [get_ports qsfp0_resetl]

set_property PACKAGE_PIN AY21     [get_ports qsfp0_modprsl]
set_property IOSTANDARD  LVCMOS18 [get_ports qsfp0_modprsl]

set_property PACKAGE_PIN AU22     [get_ports qsfp0_intl]
set_property IOSTANDARD  LVCMOS18 [get_ports qsfp0_intl]

set_property PACKAGE_PIN BE16     [get_ports qsfp0_lpmode]
set_property IOSTANDARD  LVCMOS18 [get_ports qsfp0_lpmode]

# -----------------------------------------------------------------------------
# GPIO LEDs (LVCMOS18)
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN BC24     [get_ports {gpio_led[0]}]
set_property IOSTANDARD  LVCMOS18 [get_ports {gpio_led[0]}]

set_property PACKAGE_PIN BD24     [get_ports {gpio_led[1]}]
set_property IOSTANDARD  LVCMOS18 [get_ports {gpio_led[1]}]

set_property PACKAGE_PIN BE24     [get_ports {gpio_led[2]}]
set_property IOSTANDARD  LVCMOS18 [get_ports {gpio_led[2]}]

set_property PACKAGE_PIN BF24     [get_ports {gpio_led[3]}]
set_property IOSTANDARD  LVCMOS18 [get_ports {gpio_led[3]}]
