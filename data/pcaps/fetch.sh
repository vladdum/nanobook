#!/usr/bin/env bash
# Fetch three pinned NASDAQ ITCH 5.0 trading days.
# Days: 2024-10-16 (normal), 2024-09-18 (FOMC), 2024-08-05 (book-quake).
#
# Data source: NASDAQ TotalView-ITCH Historical Data
#   https://www.nasdaqtrader.com/content/products/specs/ITCH_5.0_Data_Specs.pdf
#
# Files are available via NASDAQ's public FTP mirror.
# Try: ftp://ftp.nasdaqtrader.com/itch/Nasdaq_ITCH/<MMDDYYYY>.NASDAQ_ITCH50.gz
# Or download manually from the NASDAQ Trading Portal and place .gz files here.
#
# After placing files, update checksums:
#   cd data/pcaps && sha256sum *.gz > checksums.sha256
set -euo pipefail
cd "$(dirname "$0")"

DAYS=(
  "10162024.NASDAQ_ITCH50"
  "09182024.NASDAQ_ITCH50"
  "08052024.NASDAQ_ITCH50"
)
BASE_URLS=(
  "ftp://ftp.nasdaqtrader.com/itch/Nasdaq_ITCH"
  "https://emi.nasdaq.com/ITCH/Nasdaq_ITCH"
)

for day in "${DAYS[@]}"; do
  if [[ -f "${day}.gz" ]]; then
    echo "Have ${day}.gz, skipping"
    continue
  fi
  echo "Fetching ${day}.gz ..."
  fetched=false
  for base in "${BASE_URLS[@]}"; do
    if curl -L -f -o "${day}.gz" "${base}/${day}.gz" 2>/dev/null; then
      fetched=true
      break
    fi
    echo "  (tried ${base}, failed — trying next)"
  done
  if [[ "$fetched" == false ]]; then
    echo "ERROR: Could not fetch ${day}.gz from any mirror."
    echo "  Download manually from https://www.nasdaqtrader.com and place here."
    exit 1
  fi
done

# Skip verification if checksums are still placeholder zeros.
if grep -q "^0000000000000000000000000000000000000000000000000000000000000000" checksums.sha256; then
  echo ""
  echo "WARNING: checksums.sha256 contains placeholder zeros."
  echo "  Update with: cd data/pcaps && sha256sum *.gz > checksums.sha256"
  echo "  Then commit the updated checksums.sha256."
else
  echo "Verifying checksums ..."
  sha256sum --check checksums.sha256
  echo "All pcaps present and verified."
fi
