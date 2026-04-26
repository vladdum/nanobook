# Nanobook top-level Makefile
SHELL := /bin/bash
VIVADO ?= vivado

.PHONY: help shell hbm-smoke 10g-loopback lint fetch-pcaps verify-pcaps gen-ber-pcap \
        clean clean-all refbook refbook-test refbook-bench \
        itch-decoder-codegen-check itch-decoder-test itch-decoder-lint

help:
	@echo "Nanobook — available targets:"
	@echo "  shell          Build shell bitstream (XDMA + HBM + 10G)"
	@echo "  hbm-smoke      On-hardware HBM 16 MB smoke test"
	@echo "  10g-loopback   On-hardware 10G BER loopback test"
	@echo "  lint           Verilator lint on all RTL"
	@echo "  fetch-pcaps    Download pinned NASDAQ ITCH pcaps"
	@echo "  verify-pcaps   Verify pcap SHA-256 checksums"
	@echo "  gen-ber-pcap   Generate synthetic frame stream for the BER test"
	@echo "  refbook        Build C++ refbook (static lib + Python module)"
	@echo "  refbook-test   Build + test refbook (with coverage)"
	@echo "  refbook-bench  Run refbook Google Benchmark"
	@echo "  itch-decoder-codegen-check  Re-run codegen, assert no diff vs committed package"
	@echo "  itch-decoder-test  Run cocotb suite for itch_decoder under Verilator"
	@echo "  itch-decoder-lint  Verilator lint of itch_decoder RTL"
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

verify-pcaps:
	cd data/pcaps && sha256sum --check checksums.sha256

gen-ber-pcap:
	python3 -c "\
from scapy.all import Ether, wrpcap; \
frames = [Ether(src='02:00:00:00:01:01', dst='02:00:00:00:01:02') / bytes(range(256))*5 \
          for _ in range(100000)]; \
wrpcap('dv/integration/data/ber_frames.pcap', frames)"

clean:
	$(MAKE) -C hw/synth clean
	rm -rf build .Xil *.jou *.log *.str
	rm -rf sw/refbook/build sw/refbook/bench-build sw/refbook/_skbuild sw/refbook/dist
	rm -rf dv/unit/itch_decoder/sim_build dv/unit/itch_decoder/sim_build_*
	rm -f  dv/unit/itch_decoder/results.xml dv/unit/itch_decoder/*.fst dv/unit/itch_decoder/*.vcd
	rm -rf sim_build sim_build_*
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
