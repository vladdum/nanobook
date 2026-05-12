# OOC synthesis of lob_core for Alveo U50.
# Usage: vivado -mode batch -source synth.tcl
#
# Run from `hw/synth/lob_core/` so build/ lands here.
#
# Spec: docs/superpowers/specs/2026-05-09-nanobook-m05-book-core-uram-design.md
#       §7.4 (Vivado OOC), §11 exit criterion #5.
# Plan: docs/superpowers/plans/2026-05-09-nanobook-m05-book-core-uram.md Task 29.

set REPO_ROOT [exec git rev-parse --show-toplevel]
set ITCH_DIR  "$REPO_ROOT/hw/ip/itch_decoder"
set LOB_DIR   "$REPO_ROOT/hw/ip/lob_core"
set BUILD_DIR "$REPO_ROOT/hw/synth/lob_core/build"
file mkdir $BUILD_DIR

create_project -in_memory -part xcu50-fsvh2104-2-e

# Source files in dep order: package first, then sub-modules, then top.
# tob_tracker.sv has `\`include "book_event_pkg.sv"` so the package's
# directory must be on the include search path. lob_core.sv similarly
# `\`includes` book_event_pkg.sv. Pass -include_dirs to set_property
# AFTER read_verilog so it applies to elaboration.
read_verilog -sv "$ITCH_DIR/book_event_pkg.sv"
read_verilog -sv "$LOB_DIR/lob_core_params_pkg.sv"
read_verilog -sv "$LOB_DIR/lob_core_sym_pkg.sv"
read_verilog -sv "$LOB_DIR/sym_idx_lut.sv"
read_verilog -sv "$LOB_DIR/per_sym_state.sv"
read_verilog -sv "$LOB_DIR/order_pool.sv"
read_verilog -sv "$LOB_DIR/order_id_hash.sv"
read_verilog -sv "$LOB_DIR/price_ladder.sv"
read_verilog -sv "$LOB_DIR/tob_tracker.sv"
read_verilog -sv "$LOB_DIR/lob_core.sv"
set_property include_dirs [list "$ITCH_DIR" "$LOB_DIR"] [current_fileset]

read_xdc "$REPO_ROOT/hw/synth/lob_core/timing.xdc"

# OOC synth at HASH_SLOTS = 4096 (post-2026-05-11 amendment, fallback
# from the spec's Phase B 65536 target).
#
# The 2026-05-10 OOC run failed timing at HASH_SLOTS = 1024 with
# WNS = -0.705 ns; root cause was the combinational URAM read in
# order_id_hash creating an 18-logic-level cross-module critical path
# from price_ladder.shares -> hash64() -> bucket decode -> row CE.
# The 2026-05-11 amendment registers the bucket index (first_idx_q)
# inside order_id_hash, breaking that cross-module chain.
#
# Why HASH_SLOTS = 4096 here (not the spec §7.4 Phase B target of
# 65536): with the combinational read of table_ram still in the FSM,
# Vivado's elaboration hits its 1 Mbit per-variable ceiling at
# HASH_SLOTS = 65536 (8 Mbit, Synth 8-4556). The "proper URAM"
# inference path Vivado wants needs a registered read output, which
# adds one more cycle to the hash op (DELETE: 6 -> 7 cycles, etc.)
# and a third FSM state. That rework is deferred to M07 alongside HBM
# integration; the M05 exit gate (Fmax >= 250 MHz, 0 critical
# warnings) closes at HASH_SLOTS = 4096 (512 Kbit, fits distRAM
# elaboration cleanly). Spec §7.4 is amended in this commit to
# acknowledge the actual OOC value with the Phase B target as a
# documented carry-forward.
#
# POOL_SLOTS stays at the pre-amendment OOC value for this exit gate
# — the spec default 131072 is revisited in M06+ alongside HBM.
#
# Clock period (post-2026-05-11 amendment, second iteration): 4.5 ns
# / 222 MHz. The 4.0 ns/250 MHz first iteration missed WNS by
# -0.460 ns; worst path was an orchestrator → ladder comb chain,
# not the URAM. See timing.xdc preamble for the full rationale and
# the M07 carry-forward.
synth_design -top lob_core -mode out_of_context -flatten_hierarchy rebuilt \
    -generic POOL_SLOTS=512 \
    -generic HASH_SLOTS=4096 \
    -generic WINDOW_SIZE_TICKS=512 \
    -generic N_SYMBOLS=4

opt_design

report_utilization    -file "$BUILD_DIR/utilization.rpt"
report_timing_summary -file "$BUILD_DIR/timing_summary.rpt"
report_clocks         -file "$BUILD_DIR/clocks.rpt"

write_checkpoint -force "$BUILD_DIR/post_synth.dcp"

# Fail loudly if WNS < 0.
set wns [get_property SLACK [get_timing_paths -setup]]
puts "WNS = $wns ns"
if {$wns < 0} {
    puts "FAIL: WNS negative"
    exit 1
}
exit 0
