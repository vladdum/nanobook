# OOC clock constraint for lob_core — 222 MHz (4.5 ns period).
#
# Spec §7.4 originally targeted 250 MHz (4.0 ns). The 2026-05-11
# amendment relaxes the OOC target to 222 MHz as a documented
# carry-forward to M07/M08:
#
#   - Pre-amendment (combinational URAM read): WNS = -0.705 ns @ 4.0 ns
#     (the cross-module hash chain that motivated the amendment).
#   - Post-amendment (registered first_idx_q, combinational table_ram
#     read): WNS = -0.460 ns @ 4.0 ns. Worst path is no longer the
#     URAM — it is hash_inflight_q -> orch comb -> ladder
#     level_now_empty_reg (19 logic levels, 72% routing). Closing
#     this requires another round of pipeline registers across the
#     orch/ladder boundary, which adds +1 cycle to DELETE. Deferred
#     to M07 alongside HBM integration and the proper "registered
#     URAM read" pattern (NBA row_q <= table_ram[idx]) that would
#     also help by collapsing some of the orchestrator's hash-busy
#     gating into the hash module itself.
#
# At 4.5 ns OOC period, WNS is positive and the M05 exit gate
# (WNS >= 0, 0 critical warnings) closes. The 250 MHz Phase B
# production target is recovered in M07/M08 via the carry-forward
# work above.
#
# Top-level latency impact: p99.99 <= 500 ns budget (design.md §1)
# has comfortable headroom at 4.5 ns/cycle (~50-cycle end-to-end
# path stays well under 250 ns).
create_clock -name clk -period 4.500 [get_ports clk]
