# Cocotb + Verilator harness for hw/ip/itch_decoder/.
# Each per-stage TB extends this; override TOPLEVEL and MODULE.

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))../../../)
RTL_DIR   := $(REPO_ROOT)/hw/ip/itch_decoder
SW_REFBOOK := $(REPO_ROOT)/sw/refbook

SIM         ?= verilator
TOPLEVEL_LANG ?= verilog
EXTRA_ARGS  += --trace --trace-structs --trace-fst -Wall -Wno-DECLFILENAME \
               -I$(RTL_DIR)
COCOTB_RESOLVE_X ?= ZEROS
PYTHONPATH  := $(SW_REFBOOK):$(REPO_ROOT)/dv/unit/itch_decoder:$(PYTHONPATH)

VERILOG_SOURCES ?= $(RTL_DIR)/book_event_pkg.sv \
                   $(RTL_DIR)/itch_decoder.sv
TOPLEVEL ?= itch_decoder
MODULE   ?= tb_itch_decoder_smoke

include $(shell cocotb-config --makefiles)/Makefile.sim
