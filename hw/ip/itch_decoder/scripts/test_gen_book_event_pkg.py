"""Tests for gen_book_event_pkg.py — codegen from C++ header to SV package.

Run: pytest hw/ip/itch_decoder/scripts/test_gen_book_event_pkg.py -v
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO_ROOT / "hw" / "ip" / "itch_decoder" / "scripts"))

from gen_book_event_pkg import (
    generate,
    parse_header,
    parse_tob_header,
    render_package,
)


def test_parse_header_extracts_event_type_enum():
    src = REPO_ROOT / "sw" / "refbook" / "include" / "refbook" / "book_event.h"
    parsed = parse_header(src.read_text())
    assert parsed["event_type"] == [
        ("Add",    0),
        ("Cancel", 1),
        ("Delete", 2),
        ("Exec",   3),
        ("ExecPx", 4),
    ]


def test_parse_header_extracts_struct_fields():
    src = REPO_ROOT / "sw" / "refbook" / "include" / "refbook" / "book_event.h"
    parsed = parse_header(src.read_text())
    # Order matters — must match C++ layout.
    assert parsed["fields"] == [
        ("type",       "uint8_t",  1),
        ("side",       "uint8_t",  1),
        ("symbol_id",  "uint16_t", 2),
        ("price",      "uint32_t", 4),
        ("shares",     "uint32_t", 4),
        ("_pad",       "uint32_t", 4),
        ("order_id",   "uint64_t", 8),
        ("ingress_ts", "uint64_t", 8),
    ]


def test_render_package_produces_valid_sv():
    parsed = {
        "event_type": [("Add", 0), ("Cancel", 1), ("Delete", 2),
                       ("Exec", 3), ("ExecPx", 4)],
        "fields": [
            ("type",       "uint8_t",  1),
            ("side",       "uint8_t",  1),
            ("symbol_id",  "uint16_t", 2),
            ("price",      "uint32_t", 4),
            ("shares",     "uint32_t", 4),
            ("_pad",       "uint32_t", 4),
            ("order_id",   "uint64_t", 8),
            ("ingress_ts", "uint64_t", 8),
        ],
    }
    out = render_package(parsed)
    # Header marker
    assert "// AUTO-GENERATED FROM sw/refbook/include/refbook/book_event.h" in out
    assert "// DO NOT EDIT BY HAND. Run hw/ip/itch_decoder/scripts/gen_book_event_pkg.py" in out
    # Package + typedef + enum
    assert "package book_event_pkg;" in out
    assert "typedef enum logic [7:0]" in out
    assert "EV_ADD     = 8'h00" in out
    assert "EV_CANCEL  = 8'h01" in out
    assert "EV_DELETE  = 8'h02" in out
    assert "EV_EXEC    = 8'h03" in out
    assert "EV_EXEC_PX = 8'h04" in out
    assert "} event_type_e;" in out
    # Struct
    assert "typedef struct packed {" in out
    # Fields are big-endian-on-wire but the SV typedef is in spec layout order;
    # verify each field appears with correct width.
    assert "logic [63:0] ingress_ts;" in out
    assert "logic [63:0] order_id;"   in out
    assert "logic [31:0] _pad;"       in out
    assert "logic [31:0] shares;"     in out
    assert "logic [31:0] price;"      in out
    assert "logic [15:0] symbol_id;"  in out
    assert "logic [7:0]  side;"       in out
    assert "logic [7:0]  ev_type;"    in out  # `type` is a SV keyword; emitted as ev_type
    assert "} book_event_t;"          in out
    assert "endpackage" in out
    # Layout assertion comment so a future reader can grep it
    assert "// total 32 bytes (256 bits) — mirrors C++ layout" in out


def test_render_package_field_order_matches_cpp():
    """The SV struct lists fields in the same order as the C++ struct,
    which is offset-ascending. SV `packed` structs have MSB-first field
    declaration but offset-ascending order matches what the codegen
    produces and the assertion test above covers field presence."""
    parsed = {
        "event_type": [("Add", 0)],
        "fields": [
            ("a", "uint8_t",  1),
            ("b", "uint16_t", 2),
        ],
    }
    out = render_package(parsed)
    assert out.index("logic [7:0]  a;") < out.index("logic [15:0] b;")


# ───────── M05: tob_delta_t / tob_reason_e codegen ─────────


def test_parse_tob_header_extracts_reason_enum():
    src = REPO_ROOT / "sw" / "refbook" / "include" / "refbook" / "tob_delta.h"
    parsed = parse_tob_header(src.read_text())
    assert parsed["event_type"] == [
        ("Add",    0),
        ("Cancel", 1),
        ("Delete", 2),
        ("Exec",   3),
        ("ExecPx", 4),
    ]


def test_parse_tob_header_extracts_struct_fields():
    src = REPO_ROOT / "sw" / "refbook" / "include" / "refbook" / "tob_delta.h"
    parsed = parse_tob_header(src.read_text())
    # Must match TobDelta C++ layout exactly (frozen at M02).
    assert parsed["fields"] == [
        ("ingress_ts",     "uint64_t", 8),
        ("emit_ts",        "uint64_t", 8),
        ("symbol_id",      "uint16_t", 2),
        ("side",           "uint8_t",  1),
        ("reason",         "uint8_t",  1),
        ("new_best_price", "uint32_t", 4),
        ("new_best_size",  "uint32_t", 4),
        ("flags",          "uint32_t", 4),
    ]


def test_emits_tob_delta_struct() -> None:
    """The generated package must contain a packed tob_delta_t struct that
    mirrors sw/refbook/include/refbook/tob_delta.h field-for-field."""
    sv = generate()
    assert "typedef struct packed" in sv
    assert "tob_delta_t" in sv
    for field in ("ingress_ts", "emit_ts", "symbol_id", "side",
                  "reason", "new_best_price", "new_best_size", "flags"):
        assert field in sv, f"missing field {field} in generated package"


def test_tob_delta_reason_enum_present() -> None:
    sv = generate()
    assert "tob_reason_e" in sv
    assert "TOB_REASON_ADD" in sv
    assert "TOB_REASON_EXEC_PX" in sv


def test_book_event_unchanged_when_tob_added():
    """Frozen-invariant guard: adding tob_delta_t must NOT alter the
    existing book_event_t / event_type_e emission."""
    sv = generate()
    # M03 frozen invariants:
    assert "package book_event_pkg;" in sv
    assert "} book_event_t;" in sv
    assert "} event_type_e;" in sv
    assert "EV_EXEC_PX = 8'h04" in sv
    assert "logic [7:0]  ev_type;" in sv  # SV-keyword rename preserved
