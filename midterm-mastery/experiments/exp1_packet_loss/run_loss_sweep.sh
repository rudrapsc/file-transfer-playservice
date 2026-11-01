#!/usr/bin/env bash
# Experiment 1: Packet loss vs. retry/success behavior
#
# WHAT THIS VARIES: backend_send_loss and backend_recv_loss (both already
# exposed as Terraform variables -- no service code changes needed).
#
# WHAT IT HOLDS FIXED: file size -- 10KB (160 chunks), NOT the originally
# planned 500KB. REVISED AFTER REAL TESTING: the backend has a fixed
# worker pool (default 8 workers, 32-deep queue -- transfer-server/protocol/
# server.go's Serve()) that non-blockingly drops incoming datagrams when
# the queue is full, logged as "Overloaded: dropped incoming datagram".
# Empirically, even at 0% CONFIGURED loss, a 500KB file (~7800 chunks)
# failed 100% of the time (4/4 attempts, 504 after ~16s), and even files
# as small as 50KB sometimes failed -- this is a REAL, probabilistic,
# size-driven failure mode independent of the loss knob this experiment
# is supposed to isolate. 10KB was confirmed reliable across 5/5 trials
# at 0% configured loss, making it a clean, uncorrelated baseline so this
# experiment measures ONLY the effect of injected loss, not a confound
# with worker-queue overload (see midterm-mastery/README.md's "Findings"
# section for the full writeup on the overload discovery itself, which
# is its own significant result).
#
# WHAT IT MEASURES: for each loss level, N repeated fetches through the
# gateway's public HTTP endpoint, logging: HTTP status (200/404/503/504),
# wall-clock latency, and success/fail. Separately, you pull the backend's
# CloudWatch logs for "Missing chunks" lines to see how many RETY rounds
# each loss level actually needed before success or ErrIncomplete --
# that retry-round count is the real story this experiment tells, the
# HTTP latency alone only hints at it.
#
# USAGE:
#   export GATEWAY_URL=http://<your-gateway-alb-dns>
#   ./run_loss_sweep.sh
#
# Each loss level below triggers its own `scripts/deploy.sh --var ...`
# run from the repo root, so this script must be run from
# midterm-mastery/experiments/exp1_packet_loss/, with the repo root two
# levels up.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_FILE="size-10kb.bin"
FETCHES_PER_LEVEL=10
OUT_CSV="loss_sweep_results.csv"

if [ -z "${GATEWAY_URL:-}" ]; then
  echo "Set GATEWAY_URL first, e.g.:"
  echo "  export GATEWAY_URL=http://file-transfer-gateway-xxxxx.us-west-2.elb.amazonaws.com"
  exit 1
fi

echo "loss_send,loss_recv,attempt,http_status,latency_seconds" > "$OUT_CSV"

# Loss levels to sweep. 0% is your baseline/control. Push past where you
# expect the fixed 5-round retry budget to start failing -- the repo's
# own client caps at 5 OPEN attempts + 5 RETY rounds (~20s worst case),
# so somewhere in the 40-60% range is a reasonable place to expect real
# failures to start appearing, but confirm this empirically, don't assume it.
LOSS_LEVELS=(0 10 30 50 70)

for LOSS in "${LOSS_LEVELS[@]}"; do
  echo "=== Deploying with backend_send_loss=$LOSS backend_recv_loss=$LOSS ==="
  (cd "$REPO_ROOT" && scripts/deploy.sh --yes \
    --var backend_send_loss="$LOSS" \
    --var backend_recv_loss="$LOSS")

  echo "=== Fetching '$TEST_FILE' $FETCHES_PER_LEVEL times at loss=$LOSS% ==="
  for i in $(seq 1 "$FETCHES_PER_LEVEL"); do
    START=$(date +%s.%N)
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      "$GATEWAY_URL/files?name=$TEST_FILE")
    END=$(date +%s.%N)
    LATENCY=$(awk -v a="$END" -v b="$START" 'BEGIN{printf "%.3f", a-b}')
    echo "$LOSS,$LOSS,$i,$STATUS,$LATENCY" >> "$OUT_CSV"
    echo "  attempt $i: status=$STATUS latency=${LATENCY}s"
  done
done

echo
echo "Done. Results in $OUT_CSV"
echo
echo "IMPORTANT MANUAL STEP: for each loss level above, also pull the"
echo "backend's CloudWatch logs and grep for 'Missing chunks' to count"
echo "actual RETY rounds used -- this is the deeper evidence behind the"
echo "latency/success numbers above:"
echo "  aws logs tail /ecs/file-transfer-backend --since 10m --filter-pattern 'Missing chunks'"
echo
echo "Remember to upload '$TEST_FILE' into your S3 bucket's tmp/ prefix"
echo "BEFORE running this script -- see generate_test_file.sh in this folder."
