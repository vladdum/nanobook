create_ip -name hbm -vendor xilinx.com -library ip \
  -module_name hbm -dir [file dirname [info script]]
set_property -dict [list \
  CONFIG.USER_HBM_STACK {2} \
  CONFIG.USER_HBM_DENSITY {8GB} \
  CONFIG.USER_HBM_REF_CLK_PS {10000} \
  CONFIG.USER_MC_ENABLE_ALL {true} \
  CONFIG.USER_MC0_ECC_SCRUB_PERIOD {0} \
  CONFIG.USER_SAXI_00 {true} \
] [get_ips hbm]
generate_target all [get_ips hbm]
