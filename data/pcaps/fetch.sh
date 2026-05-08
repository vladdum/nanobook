#!/usr/bin/env bash
# Fetch three pinned NASDAQ ITCH 5.0 trading days.
# Days: 2019-03-27 (normal), 2019-10-30 (FOMC), 2019-08-30 (stress).
#
# Data source: NASDAQ TotalView-ITCH Historical Data
#   https://www.nasdaqtrader.com/content/products/specs/ITCH_5.0_Data_Specs.pdf
#
# Files are mirrored at https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/ (note: literal
# space in the path, URL-encoded as %20). The legacy ftp.nasdaqtrader.com FTP
# server is offline. NASDAQ stopped publishing 2021+ files on the free mirror;
# the M04 spec was re-pinned from 2024 to 2019 days for this reason.
#
# After placing files, update checksums:
#   cd data/pcaps && sha256sum *.gz | sort > checksums.sha256
set -euo pipefail
cd "$(dirname "$0")"

DAYS=(
  "03272019.NASDAQ_ITCH50"
  "10302019.NASDAQ_ITCH50"
  "08302019.NASDAQ_ITCH50"
)
BASE_URLS=(
  "https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH"
)

for day in "${DAYS[@]}"; do
  echo "Fetching ${day}.gz (resuming if a partial file exists) ..."
  fetched=false
  for base in "${BASE_URLS[@]}"; do
    # -C - = auto-resume from existing file's EOF; harmless no-op if complete.
    # Curl exits 0 with "all already downloaded" when the size matches.
    if curl -L -f -C - --retry 3 --retry-delay 5 \
         -o "${day}.gz" "${base}/${day}.gz"; then
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

if grep -q "^0000000000000000000000000000000000000000000000000000000000000000" checksums.sha256; then
  echo ""
  echo "ERROR: checksums.sha256 contains placeholder zeros."
  echo "  After fetching, run:"
  echo "    cd data/pcaps && sha256sum *.gz | sort > checksums.sha256"
  echo "  Then commit and re-run this script."
  exit 1
else
  echo "Verifying checksums ..."
  sha256sum --check checksums.sha256
  echo "All pcaps present and verified."
fi
