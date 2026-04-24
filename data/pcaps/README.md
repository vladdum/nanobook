# Pinned NASDAQ ITCH 5.0 pcaps

Three trading days used for all regression testing.
**Do not change without updating the spec and roadmap.**

| Label | Date | File | Rationale |
| - | - | - | - |
| normal | 2024-10-16 | `10162024.NASDAQ_ITCH50.gz` | Midweek steady-state; baseline throughput |
| fomc | 2024-09-18 | `09182024.NASDAQ_ITCH50.gz` | FOMC rate decision; burst throughput |
| quake | 2024-08-05 | `08052024.NASDAQ_ITCH50.gz` | Nikkei-driven global volatility; stress test |

## Usage

```bash
make fetch-pcaps     # download (requires NASDAQ EMI access)
make verify-pcaps    # verify SHA-256 checksums
```

Files are not committed (see `.gitignore`). Run `fetch.sh` from a clean clone.
After first successful download, update `checksums.sha256` with:

```bash
cd data/pcaps && sha256sum *.gz > checksums.sha256
```
