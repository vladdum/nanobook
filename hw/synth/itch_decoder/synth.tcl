# OOC synthesis of itch_decoder for Alveo U50.
# Usage: vivado -mode batch -source synth.tcl
#
# Run from `hw/synth/itch_decoder/` so build/ lands here.

set REPO_ROOT [exec git rev-parse --show-toplevel]
set RTL_DIR   "$REPO_ROOT/hw/ip/itch_decoder"
set BUILD_DIR "$REPO_ROOT/hw/synth/itch_decoder/build"
file mkdir $BUILD_DIR

create_project -in_memory -part xcu50-fsvh2104-2-e
foreach src [glob -nocomplain "$RTL_DIR/*.sv"] {
    read_verilog -sv $src
}
read_xdc "$REPO_ROOT/hw/synth/itch_decoder/timing.xdc"

synth_design -top itch_decoder -mode out_of_context -flatten_hierarchy rebuilt
report_timing_summary -file "$BUILD_DIR/timing_summary.rpt"
report_utilization    -file "$BUILD_DIR/utilization.rpt"
write_checkpoint      -force "$BUILD_DIR/post_synth.dcp"
