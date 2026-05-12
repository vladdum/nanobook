# M06 book-quake TB

Phase I of `docs/superpowers/plans/2026-05-12-nanobook-m06-multi-symbol-sliding-window.md`.

## What's here

- `sw/m06_tools/synth_bookquake.py` — emits a 32 B BookEvent binary
  stream. Phase 1 seeds in-window ADDs per symbol; phase 2 emits one
  rebase-trigger ADD per symbol jumping outside the static window.
  Symbols are the first N stock_locates from
  `hw/ip/lob_core/lob_core_sym_init.mem` (so events traverse the rebase
  path instead of being filtered at the sym_idx_lut).
- `tb_bookquake.py` — cycle-stall TB asserting per-rebase stall and
  `rebases_total` correctness post-F.2.
- `Makefile.bookquake` — Verilator + cocotb build.

## To run

```bash
python3 sw/m06_tools/synth_bookquake.py --out /tmp/bookquake.bin \
    --n-syms 10 --per-sym-orders 5
make -C dv/integration/m06_bookquake -f Makefile.bookquake
```

## Status

Scaffold landed alongside Phase H. Stall-bound assertions assume F.2
full's squash-and-retry semantics, which are now in (commit
`feat(m06): per-sym in-window check + squash-and-retry on rebase`).
The 1-cycle stall + 4-cycle ADD pipeline = 5 cycles per rebase, well
inside the ≤ 200-cycle target.
