# Security Policy

Nanobook is a research prototype, not a supported product. There is no SLA, no
versioned release stream, and no commitment to backport fixes.

## Reporting a vulnerability

If you discover a security issue (e.g., a vulnerability in build tooling,
generated host driver code, or a supply-chain concern in a pinned submodule),
please report it privately to:

<popescu.vlad27@gmail.com>

Do not open a public GitHub issue for suspected security problems. Include
enough detail to reproduce: affected commit SHA, environment, and a minimal
repro if possible. Expect a best-effort response within ~7 days.

## Scope

In scope:

- Code in this repository (`hw/`, `sw/`, `dv/`, `data/`, build scripts).
- The fetch/verification flow for NASDAQ ITCH captures (`data/pcaps/fetch.sh`).

Out of scope:

- Vulnerabilities in upstream dependencies (Vivado, XRT, Verilator, cocotb,
  pinned submodules) — please report those to the respective projects.
- Performance or correctness bugs in the RTL — open a normal GitHub issue.
