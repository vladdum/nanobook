create_ip -name hbm -vendor xilinx.com -library ip \
  -module_name hbm -dir [file dirname [info script]]
# XCU50: 1 HBM device, 8 GB (2 internal dies x 4 GB).
# USER_MC_ENABLE_ALL removed in 2025.2; MCs enabled per-channel.
# REF_CLK parameter renamed to per-stack suffix in 2025.2.
set_property -dict [list \
  CONFIG.USER_HBM_STACK         {2} \
  CONFIG.USER_HBM_DENSITY       {4GB} \
  CONFIG.USER_HBM_REF_CLK_0     {100} \
  CONFIG.USER_HBM_REF_CLK_PS_0  {10000} \
  CONFIG.USER_HBM_REF_CLK_1     {100} \
  CONFIG.USER_HBM_REF_CLK_PS_1  {10000} \
  CONFIG.USER_SAXI_00           {true} \
] [get_ips hbm]
generate_target all [get_ips hbm]
