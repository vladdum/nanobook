# Third-party submodules

| Path                | Upstream                                   | Tag                           | Commit                                     | License      |
|---------------------|--------------------------------------------|-------------------------------|--------------------------------------------|--------------|
| `verilog-ethernet`  | github.com/alexforencich/verilog-ethernet  | *(no tags — HEAD of master)*  | `77320a9471d19c7dd383914bc049e02d9f4f1ffb` | MIT          |
| `corundum`          | github.com/corundum/corundum               | *(no tags — HEAD of master)*  | `1ca0151b97af85aa5dd306d74b6bcec65904d2ce` | BSD-2-Clause |

We consume only:

- `verilog-ethernet/rtl/` — 10G MAC RTL (eth_mac_10g_fifo and dependencies)
- `corundum/fpga/mqnic/Alveo/fpga_100g/fpga_U50/rtl/` — U50 GTY transceiver wrapper

Upgrades: bump the submodule pin, run `make lint` and unit TBs, document in this file.
