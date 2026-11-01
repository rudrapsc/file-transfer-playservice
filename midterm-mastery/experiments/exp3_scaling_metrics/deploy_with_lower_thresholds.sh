#!/usr/bin/env bash
# OPTIONAL: run this instead of a plain `scripts/deploy.sh --yes` if the
# default scaling targets (gateway_requests_per_target=100 req/min/task,
# backend_cpu_target=60%) prove hard to cross within a reasonable Locust
# test window. Lowering both makes scale-out trigger sooner/more
# reliably, which is useful for GETTING a clean before/after timeline
# in your presentation -- the comparison being tested (which trigger
# type reacts faster) still holds at any threshold level.
#
# USAGE:
#   cd ../../..   # repo root
#   midterm-mastery/experiments/exp3_scaling_metrics/deploy_with_lower_thresholds.sh

# BUGFIX: REPO_ROOT originally used one "../" too many (this script sits
# 3 levels under the repo root: midterm-mastery/experiments/exp3_scaling_metrics/,
# same depth as exp1_packet_loss/run_loss_sweep.sh, which correctly uses
# "../../.." -- this file used "../../../..", landing one directory above
# the actual repo root and failing with "scripts/deploy.sh: No such file
# or directory".

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

(cd "$REPO_ROOT" && scripts/deploy.sh --yes \
  --var gateway_requests_per_target=20 \
  --var backend_cpu_target=30)

echo "Deployed with lowered thresholds: gateway=20 req/min/task, backend_cpu=30%."
echo "Re-run locustfile.py + watch_scaling.sh against this deployment."
