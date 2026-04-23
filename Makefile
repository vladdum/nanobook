# Nanobook top-level Makefile
SHELL := /bin/bash
VIVADO ?= vivado

.PHONY: help shell hbm-smoke 10g-loopback lint fetch-pcaps verify-pcaps gen-ber-pcap clean

help:
	@echo "Nanobook — available targets:"
	@echo "  shell          Build shell bitstream (XDMA + HBM + 10G)"
	@echo "  hbm-smoke      On-hardware HBM 16 MB smoke test"
	@echo "  10g-loopback   On-hardware 10G BER loopback test"
	@echo "  lint           Verilator lint on all RTL"
	@echo "  fetch-pcaps    Download pinned NASDAQ ITCH pcaps"
	@echo "  verify-pcaps   Verify pcap SHA-256 checksums"
	@echo "  gen-ber-pcap   Generate synthetic frame stream for the BER test"
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
	rm -rf build .Xil *.jou *.log *.str
