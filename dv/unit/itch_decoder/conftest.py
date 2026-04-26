"""Make sw/refbook (synthetic_gen, _itch_wire) importable from cocotb TBs."""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "sw" / "refbook"))
sys.path.insert(0, str(REPO_ROOT / "dv" / "unit" / "itch_decoder"))
