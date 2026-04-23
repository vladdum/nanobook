# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Worktrees

Agent worktrees under `.claude/worktrees/` must be removed once the task is complete. Do not leave stale worktrees behind.

Before removing a worktree:

1. Check for uncommitted changes: `git -C .claude/worktrees/<name> status`
2. Check for unpushed commits: `git -C .claude/worktrees/<name> log --oneline origin/main..HEAD`
3. If there are changes worth keeping, commit or cherry-pick them to the appropriate branch first.
4. Then remove the worktree:

```bash
git worktree remove .claude/worktrees/<name>
```

If the worktree has changes that should be discarded, use `--force`.

## Task Parallelism

When executing implementation plans with subagent-driven development, independent tasks may
be dispatched in parallel. General rule:

> If two tasks edit different files and neither depends on the other's output, they can run in
> parallel. Dispatch them as a single multi-agent call using `superpowers:dispatching-parallel-agents`.

Sequential dependencies to respect:

- Submodule pin / Vivado IP regeneration → any RTL that reads the generated IPs.
- Lint must precede bitstream builds (a lint failure means the RTL is wrong; no point running a 2-hour synth).
- On-hardware tests are serialized by physical access to the Alveo U50 (only one bitstream loaded at a time).
- Retrospective and exit gate for month N must finish before month N+1 planning begins.

## Git Commits

Do not include `Co-Authored-By` trailers in commit messages.

## Pull Requests

Do not include any reference to Claude or AI tools in PR titles, bodies, or descriptions
(no `🤖 Generated with Claude Code`, no `Co-Authored-By`, no similar footers).

Before creating any PR:

1. Squash all commits on the branch into a single commit.
2. Rebase on main:

```bash
git pull --rebase --autostash origin main
```

When merging, delete the branch:

```bash
gh pr merge --delete-branch
```

## Markdown Linting

Run `markdownlint-cli2` on any changed `.md` files before committing and fix all issues.
Config at `.markdownlint.json` — MD013 at 120 chars (tables and code blocks exempt); MD033 off.

```bash
markdownlint-cli2 "**/*.md"
```

## Project Overview

Nanobook is a research-prototype hardware L3 limit-order book targeting the AMD/Xilinx Alveo
U50 (XCU50, HBM2). It decodes NASDAQ TotalView-ITCH 5.0 off 10 GbE and emits top-of-book
deltas over PCIe via the Xilinx XDMA IP.

**Headline target:** frame-to-top-of-book-update latency p99.99 ≤ 500 ns, bit-exact against a
C++17 reference book on three pinned NASDAQ trading days.

Full design and non-goals: [`docs/design.md`](docs/design.md). 12-month roadmap and per-month
implementation plans live at `docs/superpowers/plans/` (gitignored, local-only).

## Build Commands

All builds run under WSL/Linux (not native Windows). Vivado 2025.2+ must be on PATH (add to `~/.bashrc`):

```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh
```

Top-level Make targets:

```bash
make help             # list targets
make shell            # build shell bitstream (XDMA + HBM + 10G)
make hbm-smoke        # on-hardware HBM 16 MB smoke test
make 10g-loopback     # on-hardware 10G BER loopback test
make lint             # Verilator lint on all RTL
make fetch-pcaps      # download pinned NASDAQ ITCH pcaps
make verify-pcaps     # verify pcap SHA-256 checksums
make gen-ber-pcap     # synthesize frames for the BER test
make clean            # remove build artifacts
```

Per-module unit testbenches (cocotb + Verilator) live in `dv/unit/` and run independently of the top-level flow.

## Architecture

```text
nanobook_top (hw/top/)
├── xdma_wrapper      — Xilinx XDMA IP + BAR0 register file (ID, VERSION, STATUS, GPIO, GIT_SHA)
├── hbm_wrapper       — Xilinx HBM IP (16× 256-bit AXI @ 450 MHz, 8 GB HBM2)
├── eth10g_wrapper    — verilog-ethernet 10G MAC + Corundum U50 GTY wrapper (QSFP28 lane 0)
├── udp_parser        — strips L2/L3/L4 → AXI-Stream payload (M9)
├── itch_decoder      — MoldUDP64 + ITCH 5.0 → book_event_t (M3–M4)
├── lob_core          — L3 book: order_pool, order_id_hash, price_ladder, tob_tracker (M5–M8)
└── result_dma        — TOB delta packer → host DMA ring (M10)
```

Clocks: MAC 156.25 MHz (XGMII), user logic 250 MHz, HBM 450 MHz, PCIe/XDMA 250 MHz.
Async FIFOs and AXI clock converters at every boundary.

**BAR0 register map** (frozen at end of M1 per roadmap's Cross-Month Interface Freeze List — changes require a spec PR first):

| Offset | Register | R/W | Description |
| --- | --- | --- | --- |
| `0x00` | `ID` | R | Magic `0x4E414E4F` ("NANO") |
| `0x04` | `VERSION` | R | `{major[15:0], minor[15:0]}` |
| `0x10` | `CONTROL` | RW | enable / reset / pause |
| `0x14` | `STATUS` | R | pipeline health bits (HBM ready, 10G ready, stall flags, CDC overflows) |
| `0x20` | `GIT_SHA_LO` | R | low 32 bits of synthesized HEAD commit |
| `0x24` | `GIT_SHA_HI` | R | high 32 bits |
| `0x100+` | `STATS_*` | R | per-pipeline counters (events in/out, drops, HBM misses, rebases) |
| `0x200+` | `TOB_RING_*` | RW | host DMA ring base / size / head / tail |

Full register map, DMA frame format, and memory architecture: `docs/design.md` §5.

## Repository Structure

- `hw/top/` — top-level RTL (`nanobook_shell_top.sv` during M1, `nanobook_top.sv` from M10)
- `hw/ip/xdma_wrapper/` — XDMA IP regeneration + BAR0 register file
- `hw/ip/hbm_wrapper/` — HBM IP regeneration + traffic generator (M1 smoke test)
- `hw/ip/eth10g_wrapper/` — GTY 10G wrapper + verilog-ethernet MAC glue
- `hw/ip/itch_decoder/` — MoldUDP64 + ITCH 5.0 decoder (M3+)
- `hw/ip/lob_core/` — L3 book sub-modules (M5+)
- `hw/synth/` — Vivado synthesis scripts (`synth.tcl`, `u50.xdc`, `Makefile`, auto-generated `build_sha.vh`)
- `hw/lint/` — Verilator waiver files
- `dv/unit/` — per-module testbenches (cocotb + SV + Verilator)
- `dv/integration/` — on-hardware integration tests and monthly exit-gate scripts (`mNN_exit.sh`)
- `sw/driver/nanobook/` — Python XDMA wrapper + BAR0 register constants
- `sw/refbook/` — C++17 reference book + pybind11 wrapper (M2)
- `sw/analyzer/` — latency analyzer + correctness diff reporter (M10)
- `sw/replay/` — pcap replay + ITCH pre-filter
- `data/pcaps/` — pinned NASDAQ ITCH 5.0 captures (fetched by `data/pcaps/fetch.sh`, not committed)
- `third_party/` — pinned submodules: `verilog-ethernet` (Forencich), `corundum` (U50 GTY reference)
- `docs/design.md` — canonical design spec
- `docs/retrospectives/mNN.md` — end-of-month retrospectives (committed, mandatory per roadmap protocol)

## Submodules

```bash
git submodule update --init --recursive
```

Pinned to specific tagged releases — do not track `main`. Upgrades go through a PR that bumps
the pin, runs lint + unit TBs, and documents the bump in `third_party/README.md`.
