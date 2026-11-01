# Midterm Mastery, Part 2 — Experimental Evaluation

Three experiments evaluating `file-transfer-playservice`, using the same
tools/approach from HW4-HW6 (bounded-parameter sweeps, Locust, Auto
Scaling comparison).

## What this service is, in one paragraph

A **gateway** (HTTP, Gin, behind an ALB) accepts `GET /files?name=X`,
and internally speaks a custom UDP protocol (FTP_6650) to a **backend**
(behind an internal NLB) that chunks files into 64-byte pieces and
streams them over UDP, with the client retrying missing chunks. The
backend reads files from S3. Both services independently Auto Scale —
but on **different metric types**, which is the subject of Experiment 3.

## Setup (do this once, before any experiment)

1. Fork `dnunez02/file-transfer-playservice` on GitHub — **keep it
   separate from your `CS6650-Rudra` repo**, per the assignment.
2. Create your own S3 bucket by hand (LabRole can't create one) —
   `AUTO_SETUP.md` Step 1 in the repo root has exact instructions.
3. Add `terraform/terraform.tfvars` with your bucket name — `AUTO_SETUP.md` Step 2.
4. `aws sts get-caller-identity` to confirm fresh Learner Lab credentials.
5. Baseline deploy, to confirm everything works before any experiment:
   ```bash
   scripts/deploy.sh --yes
   ```
   Note the printed gateway address — export it for every experiment below:
   ```bash
   export GATEWAY_URL=http://<printed-gateway-address>
   ```

**Cost/time reminder, straight from the repo's own docs:** first deploy
~15 minutes, bills continuously while up (2 load balancers + 4 Fargate
tasks). Run `scripts/destroy.sh --yes` between sessions.

## The three experiments

| # | Folder | Varies | Holds fixed | Measures |
|---|---|---|---|---|
| 1 | `experiments/exp1_packet_loss/` | `backend_send_loss`, `backend_recv_loss` (0→70%) | File size (500KB) | Success rate, latency, RETY rounds used (via CloudWatch logs) |
| 2 | `experiments/exp2_file_size/` | File size (10KB -> 4MB cap -> over-cap -> 8MB after raising the cap) | 0% loss | Transfer time, cap-rejection behavior, before/after a real code change |
| 3 | `experiments/exp3_scaling_metrics/` | Concurrent load (Locust) | — | Which Auto Scaling trigger (ALB request-rate vs. NLB-forced CPU) reacts faster/more reliably |

Run them **in this order** — each one redeploys with different
Terraform variables, so running them out of order means an earlier
experiment's settings (e.g. injected loss) could leak into a later one.
Re-run a plain `scripts/deploy.sh --yes` (no `--var` overrides) between
experiments to reset to a clean baseline.

### Experiment 1
```bash
cd midterm-mastery/experiments/exp1_packet_loss
./generate_test_file.sh <your-bucket-name>
export GATEWAY_URL=http://<gateway-address>
./run_loss_sweep.sh
```
Then, for each loss level, pull the retry evidence:
```bash
aws logs tail /ecs/file-transfer-backend --since 10m --filter-pattern "Missing chunks"
```

### Experiment 2
```bash
cd midterm-mastery/experiments/exp2_file_size
scripts/deploy.sh --yes   # reset to 0% loss baseline first (run from repo root)
./generate_test_files.sh <your-bucket-name>
export GATEWAY_URL=http://<gateway-address>
./run_size_sweep.sh
```
Then, to demonstrate the cap change itself (a real, documented code edit):
```bash
cd raise_cap_patch
./apply_raise_cap.sh
./generate_8mb_test_file.sh <your-bucket-name>
curl -o out.bin "$GATEWAY_URL/files?name=size-8mb-at-new-cap.bin"
```

### Experiment 3
```bash
cd midterm-mastery/experiments/exp3_scaling_metrics
# Use default thresholds first; if they're hard to cross, use the
# lowered-threshold variant instead:
#   ./deploy_with_lower_thresholds.sh
./watch_scaling.sh &
locust -f locustfile.py --headless -u 200 -r 20 -t 10m \
  --host "$GATEWAY_URL" --csv=scaling-test
# let watch_scaling.sh run ~2 more minutes, then: kill %1
```
Plot `scaling_timeline.csv`'s `desired_count`/`running_count` for
`gateway` vs. `backend` over time, alongside Locust's own
`scaling-test_stats_history.csv` — this comparison plot is the core
evidence for this experiment.

## Screenshots and plots (in `screenshots/`)

- `exp1_loss_vs_success_latency.png` — loss % vs. success rate and latency, plus `exp1-rety-log-sample.txt` and `overload-finding-raw-evidence.txt` for the CloudWatch evidence
- `exp2_size_vs_success_latency.png` — size vs. success rate and latency (including the over-cap failure), plus `raise-cap-8mb-evidence.txt` for the after-patch 8MB result
- `exp3_scaling_timeline.png` — ECS task count over time for both services vs. Locust's own throughput for the same window, plus `exp3-scaling-raw-evidence.txt` for the exact scale-out timestamps and raw CloudWatch metric values

## Findings

### Experiment 1 — Packet loss vs. retry/success behavior

**A real discovery that reshaped this experiment, found before the loss
sweep even started:** fetching the originally-planned 500KB test file
failed 100% of the time (4/4 attempts, HTTP 504 after ~16s) even at
**0% configured loss**. CloudWatch backend logs showed why:
`DEBUG: Overloaded: dropped incoming datagram` — the backend has a fixed
worker pool (`transfer-server/protocol/server.go`'s `Serve()`, default 8
workers, a 32-deep job queue) that non-blockingly drops incoming
datagrams when the queue is full, by design ("just as a real network
drops datagrams when overloaded; the client's timeout and RETY logic
cover it" — the function's own doc comment). For a 500KB file (~7800
chunks), a single client's own RETY traffic can saturate that 32-slot
queue enough to exhaust the client's fixed 5-retry-round budget, with
**zero injected loss involved**. Follow-up testing (20KB/30KB/50KB/70KB)
showed this is **probabilistic, not a hard size cutoff** — 30KB and 70KB
succeeded while 50KB failed in between — consistent with a queue that's
only momentarily full, not a fixed ceiling. 10KB was confirmed reliable
(5/5, then 10/10 in the actual experiment) and used as this experiment's
controlled file size instead, isolating the loss variable cleanly. Full
raw evidence: `screenshots/overload-finding-raw-evidence.txt`.

**The loss sweep itself** (10KB file, 10 fetches per level,
`loss_sweep_results.csv`):

| Configured loss | Success rate | Avg latency |
|---|---|---|
| 0% | 10/10 (100%) | 2.55s |
| 10% | 10/10 (100%) | 8.15s |
| 30% | 2/10 (20%) | 13.91s |
| 50% | 0/10 (0%) | 15.83s |
| 70% | 0/10 (0%) | 13.64s |

**Takeaway:** there's a sharp reliability cliff between 10% and 30%
configured loss, not a gradual decline — the fixed 5-OPEN-attempt /
5-RETY-round retry budget fully absorbs 10% loss (just ~3x the latency),
but collapses almost completely by 30%. CloudWatch logs confirm the
mechanism: 11,500+ `RETY`-tagged log lines across the 30/50/70% levels
show individual per-chunk retries working exactly as designed (sample in
`screenshots/exp1-rety-log-sample.txt`) — the failures at 30%+ aren't a
broken retry mechanism, they're a correctly-functioning but
budget-exhausted one. Combined with the overload discovery above: **this
service has two independent, additive sources of effective packet loss**
(server-side queue overload under volume, and configured network loss),
and the documented "5 tries" retry budget is tuned for one of them (real,
low-rate network loss) but not really the other (a burst of RETY traffic
from one large transfer can self-inflict queue drops no loss setting
controls).

### Experiment 2 — File size vs. transfer time, and the 4MB cap

**The size sweep** (0% configured loss, 5 fetches per size, `size_sweep_results.csv`):

| File size | Success rate | Notes |
|---|---|---|
| 10KB | 5/5 (100%) | ~2.3s each |
| 100KB | 5/5 (100%) | 2.5s-9.2s |
| 1MB | 3/5 (60%) | one 504, one incomplete-looking long tail (18.4s) alongside two fast 200s |
| 2MB | 1/5 (20%) | mostly 504 |
| 4MB (at the protocol's 4MB cap, ~65,536 chunks) | 4/5 (80%) | 200 three times back-to-back, one 504 |
| 4MB + 1 chunk (over the cap) | 0/5 (0%) | every attempt 504 |

**This reinforces Experiment 1's queue-overload finding rather than showing a clean, independent size effect.** At 0% configured loss, success rate should in principle stay at 100% regardless of size — the protocol has no size-dependent loss model. Instead it degrades sharply between 100KB and 2MB (100% -> 60% -> 20%) for the same reason the 500KB file failed in Experiment 1's setup: larger files mean more chunks, which means more client-side RETY traffic hammering the backend's fixed 32-slot job queue, which means more non-blocking datagram drops that the client's fixed 5-round retry budget can't always absorb. The apparent **improvement** at 4MB-at-cap (80%) versus 2MB (20%) is consistent with this being probabilistic/queue-state-dependent rather than a monotonic function of size — exactly the same non-monotonic pattern already observed in Experiment 1's 20/30/50/70KB follow-up test, just at a larger scale.

The **over-cap file (4MB + 1 chunk) failed 100% of the time**, but not for a size-related performance reason — the unmodified client enforces `maxChunks = 65536` (`transfer-client/udp/udp-client.go`) as a hard bounds check and rejects/can't parse a datagram describing more chunks than that, so it just retries and times out rather than erroring immediately (no distinct error status is surfaced to the HTTP caller; it manifests as the same 504 as any other timeout). This is a protocol-level cap, not a performance cliff.

**The raise-cap patch:** `raise_cap_patch/apply_raise_cap.sh` changes `maxChunks` from `65536` to `131072` (4MB -> 8MB) in `transfer-client/udp/udp-client.go`, requiring an actual rebuild and redeploy (`scripts/deploy.sh --yes`) since Fargate runs whatever image was last pushed. This was applied, rebuilt, and redeployed successfully (new image tag `20261101145417`).

**Result of the patch, and a second real finding:** fetching the 8MB test file through the patched gateway **still failed 100% of the time** (5/5 attempts, 504s, 44-56s latency) at 0% configured loss. The cap change itself works correctly — the gateway no longer rejects the larger file outright — but CloudWatch confirms the transfer still can't complete: the gateway's own client-side logs (note: this logging lives in `/ecs/file-transfer-gateway`, not `/ecs/file-transfer-backend` — the gateway plays the UDP *client* role against the backend) show all 5 attempts hit `ErrIncomplete` ("gave up with chunks still missing") after exhausting the full 5-round RETY budget, while the backend logged **73,154** "Overloaded: dropped incoming datagram" lines in that same window — more than 6x the 11,500+ RETY-related lines from Experiment 1's *entire* loss sweep, from a single 8MB (131,072-chunk) fetch attempt alone. Full evidence: `screenshots/raise-cap-8mb-evidence.txt`.

**Takeaway:** raising `maxChunks` is a real, working, one-line change — it does what it claims, letting the client accept a larger response — but it doesn't raise the service's actual reliability ceiling, which is governed by the same fixed worker-pool/retry-budget mechanism documented above and sits well below the 4MB cap for a single-client transfer already, let alone 8MB. **The advertised limit (`maxChunks`) and the actual reliable limit (bounded by worker-queue capacity vs. retry budget) are two different, independently-fixable things**, and this experiment demonstrates both halves of that distinction with reproducible data.

### Experiment 3 — ALB request-rate vs. NLB-forced-CPU scaling trigger

**Setup:** lowered both scaling targets (`gateway_requests_per_target` 100->20,
`backend_cpu_target` 60%->30%) so a 10-minute Locust run (200 users, ramp
rate 20/s, hitting `GET /files` for a mix of 10KB/100KB/1MB files) would
cross both thresholds comfortably within the test window — applied via
`aws application-autoscaling put-scaling-policy` directly (these are pure
Application Auto Scaling policy settings, not container config, so no
Docker rebuild was needed; useful since Docker Desktop was down at the
time). Also fixed a real bug in `deploy_with_lower_thresholds.sh`: its
`REPO_ROOT` calculation used one `../` too many for this script's actual
directory depth, causing `scripts/deploy.sh: No such file or directory`.
Both services confirmed at a clean 2/2 baseline before starting.

**Load result:** the service was overwhelmed almost immediately — 21,359
requests over 10 minutes, **98.56% failures** (20,750 `503`s, 302 `504`s),
median latency 5.1s. This isn't a bug in the experiment; 200 concurrent
users against a 2-task baseline sized for a classroom demo is exactly the
kind of load meant to force a scale-out decision.

**The scaling timeline** (from `scaling_timeline.csv`, cross-referenced
with raw CloudWatch metrics):

| Metric | Breached its target by | Actual scale-out (`desiredCount` 2->4) |
|---|---|---|
| Backend CPU (target 30%) | ~60s after load start (52% average, then 52-74% sustained for 5+ min) | **T+5:52** |
| Gateway `RequestCountPerTarget` (target 20/min) | ~60s after load start (~1,040-1,109/min/target, ~50x over target) | **T+6:08** (16s after backend) |

Both services reached their configured ceiling (`max_capacity = 4`) and
held there for the rest of the test — neither was given room to scale
further in this configuration.

**This is a real, counter-to-the-naive-expectation finding.** The
assignment's own framing (and this experiment's premise) is that a direct,
per-target ALB request-rate metric should react meaningfully faster than
an aggregate CPU percentage used as a CPU-forced NLB substitute. The raw
CloudWatch data shows **both metrics breached their targets within about a
minute of load starting, by a huge margin (CPU at ~1.7-2.5x target, request
count at ~50x target)** — so the metrics themselves were not the
bottleneck. The actual scale-out action didn't happen until **~5.5-6
minutes** after that breach for *both* services, and they ended up only 16
seconds apart. This points to the delay being dominated by AWS Application
Auto Scaling's own target-tracking alarm mechanics (which require a
sustained breach across multiple evaluation periods before acting, by
design, to avoid flapping) rather than by any inherent difference between
"ALB request rate" and "CPU percentage" as metric types. **The
ALB-vs-NLB metric asymmetry this experiment set out to test turned out to
matter far less in practice than the auto scaler's own built-in reaction
delay, which applies almost identically to both.**

**Takeaway:** auto scaling worked — both services correctly detected
overload and scaled to their configured max — but "the gateway's metric is
more direct" did not translate into "the gateway scales out meaningfully
faster" at these settings. A fairer characterization of the service's
actual behavior: expect roughly a 5-6 minute lag between a real traffic
spike and any scaling response, regardless of which load balancer type is
in front of a given service.

## If you add logging (explicitly permitted by the assignment)

If you add any `fmt.Println`/structured logging to the Go services for
clearer experiment evidence, note it here:
- **What you changed:**
- **Why:**
(Remember: `scripts/build.sh` then redeploy to actually pick up any
service-code change — Fargate runs whatever image was last pushed, not
your local source.)

## Cleanup

```bash
scripts/destroy.sh --yes
```
Then manually delete your S3 bucket's contents and the bucket itself
(the one manual step the automated teardown can't do).
