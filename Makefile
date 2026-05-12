# Nanobook top-level Makefile
SHELL := /bin/bash
VIVADO ?= vivado

.PHONY: help shell hbm-smoke 10g-loopback lint fetch-pcaps verify-pcaps gen-ber-pcap \
        clean clean-all clean-goldens refbook refbook-test refbook-bench \
        itch-decoder-codegen-check itch-decoder-test itch-decoder-lint \
        lob-core-test lob-core-lint lob-core-synth \
        m04-cosim-slice verify-goldens m06-exit \
        m06-pick-symbols m06-estimate-leak m06-hash-sim

help:
	@echo "Nanobook — available targets:"
	@echo "  shell          Build shell bitstream (XDMA + HBM + 10G)"
	@echo "  hbm-smoke      On-hardware HBM 16 MB smoke test"
	@echo "  10g-loopback   On-hardware 10G BER loopback test"
	@echo "  lint           Verilator lint on all RTL"
	@echo "  fetch-pcaps    Download pinned NASDAQ ITCH pcaps"
	@echo "  verify-pcaps   Verify pcap SHA-256 checksums"
	@echo "  verify-goldens Verify M05 frozen-golden SHA-256 checksums"
	@echo "  clean-goldens  Remove regeneratable data/golden/*.events.bin"
	@echo "  gen-ber-pcap   Generate synthetic frame stream for the BER test"
	@echo "  refbook        Build C++ refbook (static lib + Python module)"
	@echo "  refbook-test   Build + test refbook (with coverage)"
	@echo "  refbook-bench  Run refbook Google Benchmark"
	@echo "  itch-decoder-codegen-check  Re-run codegen, assert no diff vs committed package"
	@echo "  itch-decoder-test  Run cocotb suite for itch_decoder under Verilator"
	@echo "  itch-decoder-lint  Verilator lint of itch_decoder RTL"
	@echo "  lob-core-test      Run cocotb smoke TB for lob_core under Verilator (M05)"
	@echo "  lob-core-lint      Verilator lint of lob_core RTL (M05)"
	@echo "  lob-core-synth     Vivado OOC synth for lob_core (Phase K)"
	@echo "  m04-cosim-slice    Run M04 cosim against committed 100 K-msg slices (Phase G+)"
	@echo "  clean          Remove build artifacts"

shell:
	@if [ -f hw/synth/Makefile ]; then $(MAKE) -C hw/synth shell; \
	 else echo "hw/synth/Makefile missing — implement M1 Task 5 first"; exit 1; fi

hbm-smoke:
	python3 dv/integration/hbm_smoke.py

10g-loopback:
	sudo python3 dv/integration/eth10g_ber.py

lint:
	@if [ -f hw/synth/Makefile ]; then $(MAKE) -C hw/synth lint; \
	 else echo "lint: no RTL yet (M1 Tasks 5/6)"; fi

fetch-pcaps:
	bash data/pcaps/fetch.sh

m06-pick-symbols:
	python3 -m sw.m06_tools.pick_symbols \
	    --events data/golden/2019-03-27.events.bin \
	    --peak-max 50 --n-symbols 100 \
	    --sv-out hw/ip/lob_core/lob_core_sym_pkg.sv \
	    --mem-out hw/ip/lob_core/lob_core_sym_init.mem \
	    --md-out docs/m06/symbol_selection.md

m06-estimate-leak:
	python3 -m sw.m06_tools.estimate_leak \
	    --events data/golden/2019-03-27.events.bin \
	    --mem hw/ip/lob_core/lob_core_sym_init.mem

m06-hash-sim:
	python3 -m sw.m06_tools.hash_sim_multisym \
	    --events data/golden/2019-03-27.events.bin \
	    --mem hw/ip/lob_core/lob_core_sym_init.mem \
	    --hash-slots 32768

verify-pcaps:
	cd data/pcaps && sha256sum --check checksums.sha256

verify-goldens:
	@cd data/golden && sha256sum -c checksums.sha256

clean-goldens:
	@rm -rf data/golden/*.events.bin

gen-ber-pcap:
	python3 -c "\
from scapy.all import Ether, wrpcap; \
frames = [Ether(src='02:00:00:00:01:01', dst='02:00:00:00:01:02') / bytes(range(256))*5 \
          for _ in range(100000)]; \
wrpcap('dv/integration/data/ber_frames.pcap', frames)"

clean: clean-goldens
	$(MAKE) -C hw/synth clean
	rm -rf build .Xil *.jou *.log *.str
	rm -rf sw/refbook/build sw/refbook/bench-build sw/refbook/_skbuild sw/refbook/dist
	rm -rf dv/unit/itch_decoder/sim_build dv/unit/itch_decoder/sim_build_*
	rm -f  dv/unit/itch_decoder/results.xml dv/unit/itch_decoder/*.fst dv/unit/itch_decoder/*.vcd
	rm -rf dv/unit/lob_core/sim_build dv/unit/lob_core/sim_build_*
	rm -f  dv/unit/lob_core/results.xml dv/unit/lob_core/*.fst dv/unit/lob_core/*.vcd
	rm -rf dv/integration/m05_cosim/sim_build_m05_cosim dv/integration/m05_cosim/sim_build_m05_fullday
	rm -rf hw/synth/lob_core/build
	rm -f  hw/synth/lob_core/vivado*.{log,jou,backup.log,backup.jou}
	rm -rf hw/synth/lob_core/.Xil/
	rm -rf sim_build sim_build_*
	rm -rf dv/integration/m04_cosim/sim_build_cosim*
	rm -f  dump.fst *.fst *.vcd results.xml

clean-all: clean
	find hw/ip -name "*.xci" -delete
	rm -f data/pcaps/*.gz

refbook:
	cmake -S sw/refbook -B sw/refbook/build -DREFBOOK_BUILD_TESTS=ON -DREFBOOK_BUILD_PYTHON=ON
	cmake --build sw/refbook/build -j

refbook-test:
	cmake -S sw/refbook -B sw/refbook/build -DREFBOOK_BUILD_TESTS=ON -DREFBOOK_COVERAGE=ON -DCMAKE_BUILD_TYPE=Debug
	cmake --build sw/refbook/build -j
	ctest --test-dir sw/refbook/build --output-on-failure
	cmake --build sw/refbook/build --target refbook_coverage

refbook-bench:
	cmake -S sw/refbook -B sw/refbook/bench-build -DREFBOOK_BUILD_BENCH=ON -DCMAKE_BUILD_TYPE=Release
	cmake --build sw/refbook/bench-build --target refbook_bench -j
	sw/refbook/bench-build/refbook_bench

itch-decoder-codegen-check:
	@python3 hw/ip/itch_decoder/scripts/gen_book_event_pkg.py
	@git diff --exit-code hw/ip/itch_decoder/book_event_pkg.sv \
	  || (echo "ERROR: book_event_pkg.sv is stale — re-run gen_book_event_pkg.py" && exit 1)

itch-decoder-test:
	$(MAKE) -C dv/unit/itch_decoder MODULE=tb_itch_decoder_smoke

itch-decoder-lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME \
	  -Ihw/ip/itch_decoder \
	  hw/ip/itch_decoder/itch_decoder.sv

m04-cosim-slice:
	@bash dv/integration/m04_cosim/run_slices.sh

lob-core-test:
	$(MAKE) -C dv/unit/lob_core -f Makefile.smoke

lob-core-synth:
	cd hw/synth/lob_core && vivado -mode batch -source synth.tcl
	python3 hw/synth/lob_core/check_timing.py

m06-exit:
	bash dv/integration/m06_exit.sh

lob-core-lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME \
	  -Ihw/ip/itch_decoder -Ihw/ip/lob_core \
	  hw/ip/itch_decoder/book_event_pkg.sv \
	  hw/ip/lob_core/lob_core_params_pkg.sv \
	  hw/ip/lob_core/lob_core_sym_pkg.sv \
	  hw/ip/lob_core/sym_idx_lut.sv \
	  hw/ip/lob_core/per_sym_state.sv \
	  hw/ip/lob_core/order_pool.sv \
	  hw/ip/lob_core/order_id_hash.sv \
	  hw/ip/lob_core/price_ladder.sv \
	  hw/ip/lob_core/tob_tracker.sv \
	  hw/ip/lob_core/lob_core.sv
