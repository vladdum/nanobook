# refbook

Reference L3 order book — behavioral golden model for the Nanobook FPGA pipeline.

## Install

```bash
git submodule update --init --recursive
pip install ./sw/refbook
```

## Use

```python
import refbook

book = refbook.Book(n_symbols=100)
event = refbook.BookEvent()
event.type       = int(refbook.EventType.Add)
event.symbol_id  = 0
event.side       = 0
event.price      = 1_000_000
event.shares     = 100
event.order_id   = 1
event.ingress_ts = 1

delta = book.step(event)
if delta is not None:
    print(delta.new_best_price, delta.new_best_size)
```

## Design

See `docs/superpowers/specs/2026-04-25-nanobook-m02-refbook-design.md`.
