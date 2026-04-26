"""Codegen: sw/refbook/include/refbook/book_event.h -> book_event_pkg.sv.

Single source of truth for the BookEvent layout is the C++ header. This
script parses it (regex-based; the struct uses only primitive types) and
emits a SystemVerilog package that mirrors it field-for-field.

Usage:
  python3 hw/ip/itch_decoder/scripts/gen_book_event_pkg.py \
    --output hw/ip/itch_decoder/book_event_pkg.sv

CI invokes this and asserts `git diff --exit-code` against the committed
package file. If the C++ header changes, CI fails the next PR until the
SV package is regenerated.
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


def parse_header(text: str) -> Parsed:
    """Parse book_event.h and return enum + field list."""
    # EventType enum
    enum_match = re.search(
        r"enum\s+class\s+EventType\s*:\s*uint8_t\s*\{([^}]*)\}",
        text, re.MULTILINE,
    )
    if not enum_match:
        raise RuntimeError("EventType enum not found in header")
    event_type: list[tuple[str, int]] = []
    for line in enum_match.group(1).splitlines():
        m = re.match(r"\s*(\w+)\s*=\s*(\d+)\s*,?", line.strip())
        if m:
            event_type.append((m.group(1), int(m.group(2))))

    # Struct fields
    struct_match = re.search(
        r"struct\s+BookEvent\s*\{([^}]*)\}",
        text, re.MULTILINE,
    )
    if not struct_match:
        raise RuntimeError("BookEvent struct not found in header")
    fields: list[tuple[str, str, int]] = []
    for line in struct_match.group(1).splitlines():
        m = re.match(r"\s*(uint\d+_t)\s+(\w+)\s*;", line.strip())
        if m:
            ctype = m.group(1)
            name = m.group(2)
            fields.append((name, ctype, _TYPE_BYTES[ctype]))

    return Parsed(event_type=event_type, fields=fields)


def _sv_enum_name(name: str) -> str:
    """Map a C++ EventType name to its SV enum identifier."""
    return "EV_" + ("EXEC_PX" if name == "ExecPx" else name.upper())


def render_package(parsed: Parsed) -> str:
    """Render the parsed structure as a SystemVerilog package."""
    enum_lines: list[str] = []
    # Compute width from the actual rendered SV names so EV_EXEC_PX (10 chars)
    # is reflected, not the C++ original EV_EXECPX (9 chars).
    enum_name_width = max(len(_sv_enum_name(name)) for name, _ in parsed["event_type"])
    for i, (name, value) in enumerate(parsed["event_type"]):
        sv_name = _sv_enum_name(name)
        suffix = "," if i < len(parsed["event_type"]) - 1 else ""
        enum_lines.append(f"    {sv_name:<{enum_name_width}} = 8'h{value:02X}{suffix}")

    field_lines: list[str] = []
    # 12 == len("logic [63:0]"); shorter decls (e.g., "logic [7:0]") get
    # 1 char of padding so the field-name column is consistent.
    width_col = 12
    for name, ctype, _bytes in parsed["fields"]:
        bits = _TYPE_BITS[ctype]
        decl = f"logic [{bits-1}:0]"
        sv_name = name
        # SV keyword conflict: emit as-is — the user can `book_event_t.type`
        # because struct member access doesn't conflict with the keyword.
        field_lines.append(f"    {decl:<{width_col}} {sv_name};")

    out = f"""// AUTO-GENERATED FROM sw/refbook/include/refbook/book_event.h
// DO NOT EDIT BY HAND. Run hw/ip/itch_decoder/scripts/gen_book_event_pkg.py
// to regenerate. CI asserts `git diff --exit-code` against this file.

`ifndef BOOK_EVENT_PKG_SV
`define BOOK_EVENT_PKG_SV

package book_event_pkg;

  // event_type_e — mirrors enum class EventType : uint8_t
  typedef enum logic [7:0] {{
{chr(10).join(enum_lines)}
  }} event_type_e;

  // book_event_t — mirrors struct BookEvent
  // total 32 bytes (256 bits) — mirrors C++ layout
  typedef struct packed {{
{chr(10).join(field_lines)}
  }} book_event_t;

endpackage : book_event_pkg

`endif // BOOK_EVENT_PKG_SV
"""
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--header",
        default="sw/refbook/include/refbook/book_event.h",
        help="Path to the C++ header (relative to repo root).",
    )
    parser.add_argument(
        "--output",
        default="hw/ip/itch_decoder/book_event_pkg.sv",
        help="Path to write the SV package (relative to repo root).",
    )
    args = parser.parse_args()

    header_path = Path(args.header)
    output_path = Path(args.output)
    parsed = parse_header(header_path.read_text())
    output_path.write_text(render_package(parsed))
    print(f"wrote {output_path} ({len(parsed['fields'])} fields, "
          f"{len(parsed['event_type'])} enum values)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
