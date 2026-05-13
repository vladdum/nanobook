# Canonical source list for the lob_core submodule.
#
# One file per line, paths relative to this directory. Lines starting with
# `#` and blank lines are skipped. Order matters: packages → leaf modules
# → orchestrator top.
#
# Consumed by:
#   - hw/synth/lob_core/synth.tcl                  (Vivado OOC synth)
#   - Makefile lob-core-lint target                (Verilator lint)
#   - dv/unit/lob_core/Makefile.{smoke,cycles,...} (cocotb unit TBs that
#                                                   instantiate the full
#                                                   lob_core top)
#   - dv/integration/{m05_cosim,m06_cosim,m06_bookquake}/Makefile.*
#                                                  (integration TBs)
#
# Single-module unit TBs (Makefile.price_ladder, Makefile.order_id_hash,
# Makefile.order_pool, etc.) keep their own minimal lists because they
# DUT only one module + its direct dependencies.

lob_core_params_pkg.sv
lob_core_sym_pkg.sv
sym_idx_lut.sv
per_sym_state.sv
uram_sdp.sv
order_pool.sv
order_id_hash.sv
price_ladder.sv
tob_tracker.sv
lob_core.sv
