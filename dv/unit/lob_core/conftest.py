"""Shared pytest-cocotb config for lob_core unit TBs.

Mirrors dv/unit/itch_decoder/conftest.py — sets up the import path so each
tb_*.py can `import _book` without packaging gymnastics."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
