# hw/synth/Makefile — Vivado synthesis and lint targets for nanobook U50 shell

TOP ?= nanobook_shell_top

# Vivado batch build (in-process flow)
.PHONY: shell
shell:
	vivado -mode batch -source synth.tcl -tclargs $(TOP)

# Verilator lint — check all RTL without generating simulator output
.PHONY: lint
lint:
	verilator --lint-only -Wall \
		-I../ip/xdma_wrapper \
		-I../ip/hbm_wrapper \
		-I../ip/eth10g_wrapper \
		-I../lint \
		../lint/xilinx_primitives.sv \
		../top/$(TOP).sv

# Remove all build artifacts (including Vivado-generated IP dirs and report files)
.PHONY: clean
clean:
	rm -rf build/
	rm -f  build_sha.vh
	rm -f  vivado.log vivado.jou
	rm -rf .Xil/
	rm -rf ../ip/xdma_wrapper/ip/xdma_pcie/
	rm -rf ../ip/hbm_wrapper/ip/hbm/
	rm -rf ../ip/eth10g_wrapper/ip/eth_xcvr_gty_channel/
	rm -rf ../ip/eth10g_wrapper/ip/eth_xcvr_gty_full/
	rm -f  clockInfo.txt tight_setup_hold_pins.txt
	rm -rf cong/
