#!/usr/bin/env bash
# Fetch three pinned NASDAQ ITCH 5.0 trading days.
# Days: 2024-10-16 (normal), 2024-09-18 (FOMC), 2024-08-05 (book-quake).
set -euo pipefail
cd "$(dirname "$0")"

DAYS=(
  "10162024.NASDAQ_ITCH50"
  "09182024.NASDAQ_ITCH50"
  "08052024.NASDAQ_ITCH50"
)
BASE_URL="https://emi.nasdaq.com/ITCH/Nasdaq_ITCH"

for day in "${DAYS[@]}"; do
  if [[ -f "${day}.gz" ]]; then
    echo "Have ${day}.gz, skipping"
    continue
  fi
  echo "Fetching ${day}.gz ..."
  curl -L -f -o "${day}.gz" "${BASE_URL}/${day}.gz"
done

echo "Verifying checksums ..."
sha256sum --check checksums.sha256
echo "All pcaps present and verified."
