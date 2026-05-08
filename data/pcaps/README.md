# Pinned NASDAQ ITCH 5.0 pcaps

Three trading days used for all regression testing.
**Do not change without updating the spec and roadmap.**

| Label | Date | File | Rationale |
| - | - | - | - |
| normal | 2019-03-27 | `03272019.NASDAQ_ITCH50.gz` | Clean Wednesday, no macro events; baseline throughput |
| fomc | 2019-10-30 | `10302019.NASDAQ_ITCH50.gz` | FOMC announcement, 25 bp cut at 14:00 ET; burst throughput |
| stress | 2019-08-30 | `08302019.NASDAQ_ITCH50.gz` | Month-end carrying elevated vol from Aug Yuan-devaluation week |

> **Why 2019, not 2024?** The M04 spec was originally written against 2024 days
> (10-16 normal, 09-18 FOMC, 08-05 yen-unwind quake), but NASDAQ's free
> `emi.nasdaq.com` mirror no longer hosts any 2024 `.NASDAQ_ITCH50.gz` files,
> the legacy `ftp.nasdaqtrader.com` FTP server is offline, and the
> historical-data trader page route has been removed. The triad above preserves
> the original three-event-class coverage using the most recent days the free
> mirror still hosts. Spec amended 2026-05-08.

## Usage

```bash
make fetch-pcaps     # download (~12.5 GB, one-time)
make verify-pcaps    # verify SHA-256 checksums
```

Files are not committed (see `.gitignore`). Run `fetch.sh` from a clean clone.
After first successful download, update `checksums.sha256` with:

```bash
cd data/pcaps && sha256sum *.gz | sort > checksums.sha256
```
