# hw/ip/eth10g_wrapper/ip/eth_xcvr_gty.tcl
# Creates eth_xcvr_gty_full and eth_xcvr_gty_channel for 10GBASE-R on XCU50.
# Module names must match the instantiations in Corundum's
# eth_xcvr_phy_10g_gty_wrapper.v.
#
# 10G config: 10.3125 Gbps, 156.25 MHz refclk, 64-bit datapath, no secondary QPLL.

set dir [file dirname [info script]]

set line_rate    10.3125
set refclk_freq  156.25
set data_width   64
set freerun_freq 125

# Extra channel ports expected by Corundum wrapper
set extra_ports [list \
  drpclk_in drpaddr_in drpdi_in drpen_in drpwe_in drpdo_out drprdy_out \
  gttxreset_in txuserrdy_in txpmareset_in txpcsreset_in \
  txresetdone_out txpmaresetdone_out \
  gtrxreset_in rxuserrdy_in rxpmareset_in rxdfelpmreset_in \
  eyescanreset_in rxpcsreset_in rxresetdone_out rxpmaresetdone_out \
  txpd_in txpdelecidlemode_in rxpd_in \
  txsysclksel_in txpllclksel_in rxsysclksel_in rxpllclksel_in \
  txpolarity_in rxpolarity_in \
  txelecidle_in txinhibit_in txdiffctrl_in txmaincursor_in \
  txprecursor_in txpostcursor_in \
  rxcdrlock_out rxcdrhold_in rxlpmen_in dmonitorout_out \
  txprbsforceerr_in txprbssel_in rxprbscntreset_in rxprbssel_in \
  rxprbserr_out rxprbslocked_out eyescandataerror_out loopback_in \
]

set extra_pll_ports [list \
  drpclk_common_in drpaddr_common_in drpdi_common_in \
  drpen_common_in drpwe_common_in drpdo_common_out drprdy_common_out \
  qpll0reset_in qpll1reset_in qpll0pd_in qpll1pd_in \
  gtrefclk00_in qpll0lock_out qpll0outclk_out qpll0outrefclk_out \
  gtrefclk01_in qpll1lock_out qpll1outclk_out qpll1outrefclk_out \
  pcierateqpll0_in pcierateqpll1_in \
]

proc create_xcvr_ip {name locate_common extra_ports dir} {
    global line_rate refclk_freq data_width freerun_freq
    create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip \
        -module_name $name -dir $dir
    set ip [get_ips $name]
    set_property CONFIG.preset GTY-10GBASE-R $ip
    set_property -dict [list \
        CONFIG.TX_LINE_RATE            $line_rate   \
        CONFIG.TX_REFCLK_FREQUENCY     $refclk_freq \
        CONFIG.TX_USER_DATA_WIDTH      $data_width  \
        CONFIG.TX_INT_DATA_WIDTH       $data_width  \
        CONFIG.RX_LINE_RATE            $line_rate   \
        CONFIG.RX_REFCLK_FREQUENCY     $refclk_freq \
        CONFIG.RX_USER_DATA_WIDTH      $data_width  \
        CONFIG.RX_INT_DATA_WIDTH       $data_width  \
        CONFIG.SECONDARY_QPLL_ENABLE   false        \
        CONFIG.LOCATE_COMMON           $locate_common \
        CONFIG.LOCATE_RESET_CONTROLLER EXAMPLE_DESIGN \
        CONFIG.LOCATE_TX_USER_CLOCKING CORE         \
        CONFIG.LOCATE_RX_USER_CLOCKING CORE         \
        CONFIG.LOCATE_USER_DATA_WIDTH_SIZING CORE   \
        CONFIG.FREERUN_FREQUENCY       $freerun_freq \
        CONFIG.DISABLE_LOC_XDC         1            \
        CONFIG.ENABLE_OPTIONAL_PORTS   $extra_ports \
    ] $ip
    generate_target all $ip
}

# Full variant: channel + common (QPLL inside)
create_xcvr_ip eth_xcvr_gty_full CORE \
    [concat $extra_pll_ports $extra_ports] $dir

# Channel-only variant: QPLL external
create_xcvr_ip eth_xcvr_gty_channel EXAMPLE_DESIGN $extra_ports $dir
