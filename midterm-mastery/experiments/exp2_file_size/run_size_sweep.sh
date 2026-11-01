#!/usr/bin/env bash
# Experiment 2: File size vs. transfer time, up to and past the 4MB cap.
#
# WHAT THIS VARIES: file size (10KB -> 4MB-at-cap -> 4MB+1chunk-over-cap).
# WHAT IT HOLDS FIXED: 0% configured loss (so size's own effect isn't
# confounded with loss -- that interaction is a separate, optional
# follow-on noted in README.md, not this core sweep).
# WHAT IT MEASURES: wall-clock transfer time per size, and confirms the
# over-cap file is rejected by the UNMODIFIED service (run this BEFORE
# applying raise_cap_patch/).
#
# USAGE:
#   export GATEWAY_URL=http://<your-gateway-alb-dns>
#   ./run_size_sweep.sh

set -euo pipefail

if [ -z "${GATEWAY_URL:-}" ]; then
  echo "Set GATEWAY_URL first."
  exit 1
fi

OUT_CSV="size_sweep_results.csv"
echo "filename,bytes,attempt,http_status,latency_seconds" > "$OUT_CSV"

FILES=(
  "size-10kb.bin:10240"
  "size-100kb.bin:102400"
  "size-1mb.bin:1048576"
  "size-2mb.bin:2097152"
  "size-4mb-at-cap.bin:4194304"
  "size-4mb-plus-1chunk-OVER-cap.bin:4194368"
)
ATTEMPTS_PER_SIZE=5

for ENTRY in "${FILES[@]}"; do
  NAME="${ENTRY%%:*}"
  BYTES="${ENTRY##*:}"
  echo "=== $NAME ($BYTES bytes) ==="
  for i in $(seq 1 "$ATTEMPTS_PER_SIZE"); do
    START=$(date +%s.%N)
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      "$GATEWAY_URL/files?name=$NAME")
    END=$(date +%s.%N)
    LATENCY=$(awk -v a="$END" -v b="$START" 'BEGIN{printf "%.3f", a-b}')
    echo "$NAME,$BYTES,$i,$STATUS,$LATENCY" >> "$OUT_CSV"
    echo "  attempt $i: status=$STATUS latency=${LATENCY}s"
  done
done

echo
echo "Done. Results in $OUT_CSV"
echo "Expect the OVER-cap file to show a non-200 status (504 most likely,"
echo "since the client silently drops the malformed/oversized datagram and"
echo "times out rather than erroring immediately -- see parseDatagram's"
echo "error path in transfer-client/udp/udp-client.go for why)."
