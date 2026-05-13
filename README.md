# Nanobook

Hardware L3 limit order book on AMD/Xilinx Alveo U50. Ingests real NASDAQ TotalView-ITCH 5.0
market data off 10 GbE, maintains a full per-order book for the top 100 symbols entirely on FPGA,
and emits top-of-book deltas over PCIe via Xilinx XDMA.

**Headline target:** frame-to-top-of-book-update latency p99.99 ≤ 500 ns, bit-exact against a
reference C++ book on three pinned NASDAQ trading days.

> **Research prototype, not production trading software.** This repository is a personal
> learning/research project. It is not a supported product, has no SLA, has not been audited
> for security, and must not be used in any production trading or market-data path. See
> [`SECURITY.md`](SECURITY.md) and [`LICENSE`](LICENSE) (Apache 2.0, no warranty).

Full architecture: [`docs/design.md`](docs/design.md).

## Status

**Month 6 of 12 — in progress.** M06 Phase J synth closed at WNS = +0.080 ns;
Phase H (multi-symbol cosim) and Phase L (full-day exit gate) are next.

| Month | Scope | Status |
| --- | --- | --- |
| M01 | Toolchain, shell bitstream (XDMA + HBM + 10G), BAR0 freeze | done |
| M02 | C++17 reference book + pybind11 + synthetic ITCH generator | done |
| M03 | `itch_decoder` (MoldUDP64 + ITCH 5.0 → `book_event_t`), Vivado OOC at 400 MHz | done |
| M04 | Real-pcap regression: RTL output bit-exact vs Python ITCH parser on 3 pinned NASDAQ captures | done |
| M05 | `lob_core` v1 — single-symbol L3 book on URAM (order_pool, order_id_hash, price_ladder, tob_tracker) | done |
| M06 | Multi-symbol (100-sym) book + sliding-window rebase + pipelined CLZ + URAM synth at 250 MHz | in progress |
| M07 | HBM-backed `order_pool` extension (≥ 100 K live orders) | next |

End-of-month retrospectives live in [`docs/retrospectives/`](docs/retrospectives/).
Not a working end-to-end system yet — DMA result path and host integration land in M08–M10.

## Architecture

```text
nanobook_top (hw/top/)
├── xdma_wrapper      — Xilinx XDMA IP + BAR0 register file
├── hbm_wrapper       — Xilinx HBM IP (16× 256-bit AXI @ 450 MHz, 8 GB HBM2)
├── eth10g_wrapper    — verilog-ethernet 10G MAC + Corundum U50 GTY wrapper
├── udp_parser        — strips L2/L3/L4 → AXI-Stream payload
├── itch_decoder      — MoldUDP64 + ITCH 5.0 → book_event_t
├── lob_core          — L3 book (order_pool · order_id_hash · price_ladder · tob_tracker)
└── result_dma        — TOB delta packer → host DMA ring
```

### BAR0 register map (M1 frozen)

| Offset | Register | R/W | Description |
| --- | --- | --- | --- |
| `0x00` | `ID` | R | Magic `0x4E414E4F` ("NANO") |
| `0x04` | `VERSION` | R | `{major[15:0], minor[15:0]}` |
| `0x10` | `CONTROL` | RW | enable / reset / pause |
| `0x14` | `STATUS` | R | HBM ready, 10G ready, stall flags, CDC overflows |
| `0x20` | `GIT_SHA_LO` | R | low 32 bits of synthesized HEAD commit |
| `0x24` | `GIT_SHA_HI` | R | high 32 bits |
| `0x100+` | `STATS_*` | R | per-pipeline counters |
| `0x200+` | `TOB_RING_*` | RW | host DMA ring base / size / head / tail |

Full register map + 32-byte DMA frame format: `docs/design.md` §5.

## Getting Started

### Installing Ubuntu via WSL (Windows only)

All builds require a Linux environment. On Windows, use **WSL (Windows Subsystem for Linux)** to run Ubuntu:

1. Open **PowerShell as Administrator** and run:

   ```powershell
   wsl --install
   ```

   This installs WSL 2 and Ubuntu by default. Restart your PC when prompted.
2. After reboot, Ubuntu will launch automatically to finish setup. Create a Unix username and password when asked.
3. Verify the installation in PowerShell:

   ```powershell
   wsl -l -v
   ```

   You should see Ubuntu listed with VERSION 2.
4. Launch Ubuntu from the Start menu, or type `wsl` in PowerShell/Terminal.
5. Update packages inside Ubuntu:

   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

> **Tip:** To install a specific Ubuntu version, run `wsl --install -d Ubuntu-22.04`.
> Run `wsl --list --online` to see all available distributions.

All build commands below should be run inside the WSL/Ubuntu terminal.

### Prerequisites

- **WSL / Linux** — builds do not run under native Windows. Target: Ubuntu 22.04.4 LTS, HWE kernel (6.5.x).
- **Alveo U50 (XCU50)** — seated in a PCIe Gen3 x16 slot with aux 6-pin power and a blower
  shroud for airflow. See `docs/host-spec.md` (populated during M1 Task 2) for the pinned host
  configuration.
- **[Vivado ML Standard 2025.2+](https://www.xilinx.com/products/design-tools/vivado.html)**
  with Alveo device support. Source in `~/.bashrc`:

  ```bash
  source /opt/Xilinx/2025.2/Vivado/settings64.sh
  ```

- **[Xilinx Runtime (XRT)](https://xilinx.github.io/XRT/master/html/index.html)** matched to
  your Vivado install, for on-hardware testing:

  ```bash
  wget <xrt deb matching your kernel> -O xrt.deb
  sudo apt install -y ./xrt.deb
  sudo systemctl enable --now msd
  xbutil --version
  ```

- **[Verilator](https://www.veripool.org/verilator/)** ≥ 5.040 — for lint and cocotb simulation.
  Cocotb 2.0 requires a recent Verilator; distro packages are stale (Ubuntu 24.04 ships 5.020,
  too old for `cocotb 2.0`). Build from source:

  ```bash
  sudo apt-get install git help2man perl python3 make autoconf g++ flex bison ccache
  sudo apt-get install libgoogle-perftools-dev numactl perl-doc
  sudo apt-get install libfl2 libfl-dev zlib1g zlib1g-dev libelf-dev
  git clone https://github.com/verilator/verilator.git
  cd verilator && git checkout v5.046 && autoconf && ./configure
  make -j $(nproc) && sudo make install
  ```

- **Python 3.11+** with:

  ```bash
  pip3 install 'cocotb>=2.0' cocotbext-axi cocotbext-eth pybind11 scapy numpy
  ```

- **tcpreplay** — for the 10G loopback BER test (`sudo apt install tcpreplay`).
- **GTKWave** (optional, waveform viewing) — `sudo apt install gtkwave`. Requires WSLg
  (WSL2 on Windows 10 21H2+) or an X server for GUI.

### Clone and initialize

```bash
git clone https://github.com/vladdum/nanobook.git
cd nanobook
git submodule update --init --recursive
```

Submodules (`third_party/`) are pinned to tagged releases:

- `verilog-ethernet` — Alex Forencich, MIT. 10G MAC + PCS.
- `corundum` — Berkeley, BSD-2-Clause. Source of the U50 GTY transceiver wrapper.

## Build Commands

Run `make help` to list all targets:

```bash
make shell            # Build shell bitstream (XDMA + HBM + 10G)
make hbm-smoke        # On-hardware HBM 16 MB smoke test (needs U50)
make 10g-loopback     # On-hardware 10G BER loopback (needs U50 + host NIC)
make lint             # Verilator lint on all RTL
make fetch-pcaps      # Download pinned NASDAQ ITCH pcaps
make verify-pcaps     # Verify pcap SHA-256 checksums
make gen-ber-pcap     # Generate synthetic frames for the BER test
make clean            # Remove build artifacts
```

### Market data

The reference captures used by `make fetch-pcaps` are public NASDAQ TotalView-ITCH 5.0
sample files (e.g., `emi.nasdaq.com/ITCH/`). They are **not redistributed** in this
repository — `data/pcaps/` is gitignored and the files are downloaded directly from
NASDAQ's mirror at fetch time. Users are responsible for complying with NASDAQ's terms
for use of the data. See `data/pcaps/fetch.sh` for the exact source URLs and the pinned
trading days.

## Module-Level Testbenches

Per-module unit TBs live in `dv/unit/<module>/` and use cocotb + Verilator. The M03 ITCH
decoder shipped 14 TBs:

```bash
make -C dv/unit/itch_decoder -f Makefile.e2e          # 10K-event byte-exact vs refbook
make -C dv/unit/itch_decoder -f Makefile.throughput   # input acceptance ratio
make itch-decoder-test                                # smoke
make itch-decoder-lint                                # Verilator lint, 0 warnings
```

M01–M02 module TBs live in `dv/unit/`:

```bash
cd dv/unit
ls Makefile.*                           # list available TBs
make -f Makefile.xdma_regs              # build and run
make -f Makefile.hbm_traffic_gen
make -f Makefile.eth10g_loopback
```

On-hardware integration tests live in `dv/integration/` and require the U50 seated in the host:

```bash
python3 dv/integration/xdma_enum.py     # BAR0 round-trip
python3 dv/integration/git_sha_check.py # FPGA SHA == HEAD
python3 dv/integration/hbm_smoke.py     # HBM 16 MB scatter R/W
sudo python3 dv/integration/eth10g_ber.py
```

Each month closes on a `dv/integration/mNN_exit.sh` script that runs all exit criteria back-to-back.

## Waveform Viewing

```bash
cd dv/unit
make -f Makefile.xdma_regs              # generates sim_build/dump.fst
gtkwave sim_build/dump.fst
```

Saved waveform views (`.gtkw` files) are stored alongside each TB.

## Repository Structure

```text
hw/top/                Top-level RTL
hw/ip/                 Module IPs (xdma_wrapper, hbm_wrapper, eth10g_wrapper, itch_decoder, lob_core, ...)
hw/synth/              Vivado scripts (synth.tcl, u50.xdc, Makefile, auto-generated build_sha.vh)
hw/lint/               Verilator waiver files
dv/unit/               Per-module unit testbenches (cocotb + SV)
dv/integration/        On-hardware integration tests + monthly exit-gate scripts
sw/driver/nanobook/    Python XDMA wrapper + BAR0 register constants
sw/refbook/            C++17 reference book + pybind11 (M2+)
sw/analyzer/           Latency analyzer + correctness diff (M10+)
sw/replay/             pcap replay + ITCH pre-filter
data/pcaps/            Pinned NASDAQ ITCH 5.0 captures (fetched, not committed)
third_party/           Pinned submodules: verilog-ethernet, corundum
docs/design.md         Canonical design spec
docs/retrospectives/   End-of-month retrospectives
```

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
