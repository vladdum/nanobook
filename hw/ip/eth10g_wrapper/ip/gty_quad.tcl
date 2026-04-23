# hw/ip/eth10g_wrapper/ip/gty_quad.tcl
# Vivado IP regen for GTY Wizard UltraScale+ — single channel, 10GBASE-R preset.
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip \
  -module_name gty_quad -dir [file dirname [info script]]
set_property -dict [list \
  CONFIG.CHANNEL_ENABLE {X0Y0} \
  CONFIG.PRESET {GTY-10GBASE-R} \
  CONFIG.TX_LINE_RATE {10.3125} \
  CONFIG.RX_LINE_RATE {10.3125} \
  CONFIG.TX_REFCLK_FREQUENCY {156.25} \
  CONFIG.RX_REFCLK_FREQUENCY {156.25} \
  CONFIG.TX_DATA_ENCODING {64B66B_ASYNC} \
  CONFIG.RX_DATA_DECODING {64B66B_ASYNC} \
  CONFIG.INS_LOSS_NYQ {20} \
] [get_ips gty_quad]
generate_target all [get_ips gty_quad]
