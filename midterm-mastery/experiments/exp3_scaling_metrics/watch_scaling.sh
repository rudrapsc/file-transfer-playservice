#!/usr/bin/env bash
# Experiment 3: Auto Scaling trigger comparison -- ALB (gateway) vs.
# NLB-forced CPU (backend).
#
# WHAT THIS MEASURES: polls BOTH services' running/desired task counts
# every 10 seconds, so you can plot task count over time for each
# service side by side against the SAME Locust run, and see which one
# (if either) actually scales, and how quickly.
#
# WHY THIS COMPARISON IS INTERESTING (see terraform/autoscaling.tf's own
# comment): the gateway scales on ALBRequestCountPerTarget, a REAL,
# direct per-target request-rate metric only an Application Load
# Balancer provides. The backend sits behind a Network Load Balancer,
# which has no equivalent per-target request metric at all -- so it's
# forced onto ECSServiceAverageCPUUtilization instead, a laggier,
# indirect proxy for the same underlying "is this service overloaded"
# question. This script's job is to produce the timeline evidence for
# whichever of those two actually turns out to react faster/more
# reliably under the SAME Locust-generated load.
#
# USAGE: run this in parallel with your Locust test (e.g., in a second
# terminal, or backgrounded), for at least as long as the Locust run
# plus a couple extra minutes to catch a scale-out that completes late.
#
#   ./watch_scaling.sh &
#   locust -f locustfile.py --headless -u 200 -r 20 -t 10m \
#     --host http://<gateway-alb-dns> --csv=scaling-test
#   # let watch_scaling.sh run ~2 more minutes after locust finishes, then:
#   kill %1

set -euo pipefail

CLUSTER="${1:-file-transfer}"   # confirmed against terraform/ecs.tf: aws_ecs_cluster.main's name = "file-transfer"
OUT_CSV="scaling_timeline.csv"
POLL_SECONDS=10

echo "timestamp,service,desired_count,running_count" > "$OUT_CSV"

echo "Watching cluster '$CLUSTER' every ${POLL_SECONDS}s. Ctrl-C to stop."
echo "(Service names 'gateway' and 'backend' are confirmed from"
echo " terraform/ecs.tf's aws_ecs_service.gateway/.backend 'name' attributes.)"

while true; do
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  for SERVICE in gateway backend; do
    READ=$(aws ecs describe-services \
      --cluster "$CLUSTER" \
      --services "$SERVICE" \
      --query 'services[0].[desiredCount,runningCount]' \
      --output text 2>/dev/null || echo "ERR ERR")
    DESIRED=$(echo "$READ" | awk '{print $1}')
    RUNNING=$(echo "$READ" | awk '{print $2}')
    echo "$TS,$SERVICE,$DESIRED,$RUNNING" >> "$OUT_CSV"
  done
  sleep "$POLL_SECONDS"
done
