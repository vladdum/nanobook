# M06 multi-symbol cosim

Phase H of `docs/superpowers/plans/2026-05-12-nanobook-m06-multi-symbol-sliding-window.md`.

## What's here

- `decoder_lob_top.sv` — `itch_decoder` → `lob_core` cosim wrapper with the
  full M06 stat-counter set surfaced.
- `tb_cosim.py` — cocotb TB that drives the slice, captures RTL TOB deltas,
  and bit-compares against `sw/refbook` filtered to the picked-100
  stock_locates (read from `hw/ip/lob_core/lob_core_sym_init.mem`).
  Both delta streams are sorted by `(ingress_ts, symbol_id, side)` before
  comparison so first-divergence diagnostics are readable.
- `Makefile.cosim` — Verilator + cocotb build with all M06 sources
  (`lob_core_sym_pkg`, `sym_idx_lut`, `per_sym_state`, ...).
- `run_slice.sh` — runs the cosim against a slice in
  `data/pcaps/slices/m06_2019-03-27_picked100.itch.zst` (or whatever
  path is in `M06_SLICE_ITCH`).
- `run_full_day.sh` — skeleton for the 3-day cosim sweep. Gated on the
  M06 multi-day slice generator landing alongside Phase H polish work.

## To run

```bash
export M06_SLICE_ITCH=/path/to/slice.itch.zst   # multi-symbol slice
bash dv/integration/m06_cosim/run_slice.sh
```

## Status

Scaffold landed; bit-exact comparison vs refbook is the remaining polish
(refbook side may need ordering tweaks for the rebase + drop-on-rebase
boundary, plus the missing M06 slice generator). The TB will run today
end-to-end once `M06_SLICE_ITCH` points at a valid multi-symbol slice.
