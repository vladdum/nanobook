# Cocotb + Verilator harness for hw/ip/lob_core/.
# Each per-module TB extends this; override TOPLEVEL and MODULE.

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))../../../)
ITCH_DIR  := $(REPO_ROOT)/hw/ip/itch_decoder
LOB_DIR   := $(REPO_ROOT)/hw/ip/lob_core

SIM         ?= verilator
TOPLEVEL_LANG ?= verilog
EXTRA_ARGS  += --trace --trace-structs --trace-fst -Wall -Wno-DECLFILENAME \
               -I$(ITCH_DIR) -I$(LOB_DIR)
COCOTB_RESOLVE_X ?= ZEROS
PYTHONPATH  := $(REPO_ROOT)/dv/unit/lob_core:$(PYTHONPATH)

# Per-target Makefiles override VERILOG_SOURCES (and TOPLEVEL / MODULE) so
# we don't list lob_core_params_pkg here — Verilator errors UNUSEDPARAM if
# the toplevel module hasn't yet imported it (Phase C stub vs Phase H final).

# Per-toplevel sim build dir so different TBs don't collide.
SIM_BUILD ?= sim_build_$(TOPLEVEL)

include $(shell cocotb-config --makefiles)/Makefile.sim
