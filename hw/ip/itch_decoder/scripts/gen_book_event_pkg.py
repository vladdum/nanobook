"""Codegen: sw/refbook/include/refbook/{book_event,tob_delta}.h
            -> book_event_pkg.sv.

Single source of truth for both layouts is the C++ headers. This script
parses them (regex-based; structs use only primitive types) and emits
a SystemVerilog package that mirrors them field-for-field:

  * book_event_t (§M03 frozen) — from book_event.h
  * tob_delta_t  (§M05 added)  — from tob_delta.h
  * event_type_e               — from book_event.h's EventType enum
  * tob_reason_e               — from tob_delta.h's TobReason enum

Usage:
  python3 hw/ip/itch_decoder/scripts/gen_book_event_pkg.py \
    --output hw/ip/itch_decoder/book_event_pkg.sv

CI invokes this and asserts `git diff --exit-code` against the committed
package file. If either C++ header changes, CI fails the next PR until
the SV package is regenerated.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import TypedDict


# Fixed type widths — the BookEvent struct uses only these.
_TYPE_BITS = {
    "uint8_t":  8,
    "uint16_t": 16,
    "uint32_t": 32,
    "uint64_t": 64,
}
_TYPE_BYTES = {k: v // 8 for k, v in _TYPE_BITS.items()}

# `type` is a SystemVerilog reserved word; the SV emit quotes it.
_SV_KEYWORDS = {"type"}


class Parsed(TypedDict):
    event_type: list[tuple[str, int]]
    fields: list[tuple[str, str, int]]  # name, ctype, byte width


def _parse_enum(text: str, enum_name: str) -> list[tuple[str, int]]:
    """Parse an `enum class <name> : uint8_t { ... }` block into name,value pairs."""
    enum_match = re.search(
        rf"enum\s+class\s+{enum_name}\s*:\s*uint8_t\s*\{{([^}}]*)\}}",
        text, re.MULTILINE,
    )
    if not enum_match:
        raise RuntimeError(f"{enum_name} enum not found in header")
    items: list[tuple[str, int]] = []
    for line in enum_match.group(1).splitlines():
        m = re.match(r"\s*(\w+)\s*=\s*(\d+)\s*,?", line.strip())
        if m:
            items.append((m.group(1), int(m.group(2))))
    return items


def _parse_struct(text: str, struct_name: str) -> list[tuple[str, str, int]]:
    """Parse a `struct <name> { ... }` block. Returns (name, ctype, byte_width).
    Tolerates trailing C-style comments on each field line."""
    struct_match = re.search(
        rf"struct\s+{struct_name}\s*\{{([^}}]*)\}}",
        text, re.MULTILINE,
    )
    if not struct_match:
        raise RuntimeError(f"{struct_name} struct not found in header")
    fields: list[tuple[str, str, int]] = []
    for line in struct_match.group(1).splitlines():
        m = re.match(r"\s*(uint\d+_t)\s+(\w+)\s*;", line.strip())
        if m:
            ctype = m.group(1)
            name = m.group(2)
            fields.append((name, ctype, _TYPE_BYTES[ctype]))
    return fields


def parse_header(text: str) -> Parsed:
    """Parse book_event.h (M03 frozen) and return enum + field list."""
    return Parsed(
        event_type=_parse_enum(text, "EventType"),
        fields=_parse_struct(text, "BookEvent"),
    )


def parse_tob_header(text: str) -> Parsed:
    """Parse tob_delta.h (M05 added) and return enum + field list."""
    return Parsed(
        event_type=_parse_enum(text, "TobReason"),
        fields=_parse_struct(text, "TobDelta"),
    )


def _sv_enum_name(name: str) -> str:
    """Map a C++ EventType name to its SV enum identifier."""
    return "EV_" + ("EXEC_PX" if name == "ExecPx" else name.upper())


# SV reserved keywords that conflict with C++ field names. These are
# rewritten on the SV side only — byte layout (the freeze-list
# invariant) is unchanged. The C++ struct keeps the original name.
_SV_FIELD_RENAMES = {"type": "ev_type"}

# 12 == len("logic [63:0]"); shorter decls (e.g., "logic [7:0]") get
# 1 char of padding so the field-name column is consistent.
_FIELD_WIDTH_COL = 12


def _render_enum_block(enum_items: list[tuple[str, int]],
                       sv_namer) -> str:
    """Render an enum-name → uint8 hex mapping into one SV enum body."""
    enum_name_width = max(len(sv_namer(name)) for name, _ in enum_items)
    lines: list[str] = []
    for i, (name, value) in enumerate(enum_items):
        sv_name = sv_namer(name)
        suffix = "," if i < len(enum_items) - 1 else ""
        lines.append(f"    {sv_name:<{enum_name_width}} = 8'h{value:02X}{suffix}")
    return chr(10).join(lines)


def _render_struct_fields(fields: list[tuple[str, str, int]]) -> str:
    """Render struct fields as `logic [W-1:0] name;` lines."""
    out: list[str] = []
    for name, ctype, _bytes in fields:
        bits = _TYPE_BITS[ctype]
        decl = f"logic [{bits-1}:0]"
        sv_name = _SV_FIELD_RENAMES.get(name, name)
        out.append(f"    {decl:<{_FIELD_WIDTH_COL}} {sv_name};")
    return chr(10).join(out)


def _sv_tob_reason_name(name: str) -> str:
    """Map a C++ TobReason name to its SV enum identifier."""
    # ExecPx → EXEC_PX; everything else is upper-snake.
    return "TOB_REASON_" + ("EXEC_PX" if name == "ExecPx" else name.upper())


def render_package(parsed: Parsed, tob_parsed: Parsed | None = None) -> str:
    """Render the SystemVerilog package.

    `parsed`   : BookEvent + EventType (always emitted; M03 frozen).
    `tob_parsed`: TobDelta + TobReason (M05; appended when present).
    """
    book_enum   = _render_enum_block(parsed["event_type"], _sv_enum_name)
    book_fields = _render_struct_fields(parsed["fields"])

    tob_section = ""
    if tob_parsed is not None:
        tob_enum   = _render_enum_block(tob_parsed["event_type"], _sv_tob_reason_name)
        tob_fields = _render_struct_fields(tob_parsed["fields"])
        tob_section = f"""
  // tob_reason_e — mirrors enum class TobReason : uint8_t
  typedef enum logic [7:0] {{
{tob_enum}
  }} tob_reason_e;

  // tob_delta_t — mirrors struct TobDelta
  // total 32 bytes (256 bits) — mirrors C++ layout
  typedef struct packed {{
{tob_fields}
  }} tob_delta_t;
"""

    out = f"""// AUTO-GENERATED FROM sw/refbook/include/refbook/book_event.h{
        " + tob_delta.h" if tob_parsed is not None else ""
    }
// DO NOT EDIT BY HAND. Run hw/ip/itch_decoder/scripts/gen_book_event_pkg.py
// to regenerate. CI asserts `git diff --exit-code` against this file.

`ifndef BOOK_EVENT_PKG_SV
`define BOOK_EVENT_PKG_SV

package book_event_pkg;

  // event_type_e — mirrors enum class EventType : uint8_t
  typedef enum logic [7:0] {{
{book_enum}
  }} event_type_e;

  // book_event_t — mirrors struct BookEvent
  // total 32 bytes (256 bits) — mirrors C++ layout
  typedef struct packed {{
{book_fields}
  }} book_event_t;
{tob_section}
endpackage : book_event_pkg

`endif // BOOK_EVENT_PKG_SV
"""
    return out


def generate(repo_root: Path | None = None) -> str:
    """Top-level entry point: read both headers and render the combined package.
    Returns the rendered SV text. Convenience wrapper used by the M05 codegen
    test."""
    root = repo_root or Path(__file__).resolve().parents[4]
    book_header = root / "sw" / "refbook" / "include" / "refbook" / "book_event.h"
    tob_header  = root / "sw" / "refbook" / "include" / "refbook" / "tob_delta.h"
    book = parse_header(book_header.read_text())
    tob  = parse_tob_header(tob_header.read_text()) if tob_header.exists() else None
    return render_package(book, tob)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--header",
        default="sw/refbook/include/refbook/book_event.h",
        help="Path to the BookEvent C++ header (relative to repo root).",
    )
    parser.add_argument(
        "--tob-header",
        default="sw/refbook/include/refbook/tob_delta.h",
        help="Path to the TobDelta C++ header (M05 added).",
    )
    parser.add_argument(
        "--output",
        default="hw/ip/itch_decoder/book_event_pkg.sv",
        help="Path to write the SV package (relative to repo root).",
    )
    args = parser.parse_args()

    header_path = Path(args.header)
    tob_header_path = Path(args.tob_header)
    output_path = Path(args.output)
    parsed = parse_header(header_path.read_text())
    tob_parsed = parse_tob_header(tob_header_path.read_text()) \
        if tob_header_path.exists() else None
    output_path.write_text(render_package(parsed, tob_parsed))
    msg = (
        f"wrote {output_path}: "
        f"book ({len(parsed['fields'])} fields, "
        f"{len(parsed['event_type'])} enum values)"
    )
    if tob_parsed is not None:
        msg += (
            f"; tob ({len(tob_parsed['fields'])} fields, "
            f"{len(tob_parsed['event_type'])} enum values)"
        )
    print(msg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
