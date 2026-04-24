# Vivado IP regeneration script for Xilinx XDMA IP.
# Run inside a Vivado project: source this file to recreate xdma_pcie.xci.
create_ip -name xdma -vendor xilinx.com -library ip \
  -module_name xdma_pcie -dir [file dirname [info script]]
set_property -dict [list \
  CONFIG.mode_selection {Advanced} \
  CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
  CONFIG.pl_link_cap_max_link_width {X4} \
  CONFIG.axi_data_width {256_bit} \
  CONFIG.axilite_master_en {true} \
  CONFIG.axilite_master_size {64} \
  CONFIG.pf0_device_id {903F} \
  CONFIG.xdma_num_usr_irq {1} \
] [get_ips xdma_pcie]
generate_target all [get_ips xdma_pcie]
