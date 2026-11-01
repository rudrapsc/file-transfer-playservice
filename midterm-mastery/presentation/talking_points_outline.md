# Midterm Mastery Part 2 — Presentation Outline (4-5 minutes)

**THIS IS THE EXPERIMENT PRESENTATION ITSELF**, per the assignment's
requirement to clearly label it as such.

All numbers below are real results from the actual AWS deployment (see
`../README.md`'s Findings section and `../screenshots/` for full raw
evidence).

---

## 0. Service overview (30 seconds)

"This is a file-sharing service with two parts: a gateway that accepts
HTTP requests behind an Application Load Balancer, and a backend that
speaks a custom UDP protocol behind a Network Load Balancer, chunking
files into 64-byte pieces with client-side retry for lost chunks."

## 1. Experiment 1 — Packet loss vs. retry/success behavior (~80 seconds)

- **A discovery before the real experiment even started:** the originally
  planned 500KB test file failed 100% of the time (4/4 attempts, HTTP 504)
  at **0% configured loss**. Root cause, from CloudWatch: the backend's
  fixed 8-worker / 32-deep job queue (`transfer-server/protocol/server.go`)
  drops incoming datagrams non-blockingly when full — a large file's own
  RETY traffic can self-saturate that queue with zero injected loss
  involved. Confirmed probabilistic (not a hard size cutoff) via a
  20/30/50/70KB follow-up where 30KB and 70KB succeeded but 50KB failed.
  Switched to a 10KB file (confirmed reliable) to isolate the loss
  variable cleanly.
- **Methodology:** swept `backend_send_loss`/`backend_recv_loss` from 0%
  to 70%, fetching the 10KB file 10 times per level through the gateway.
- **Finding:** 100% success at 0% and 10% loss, falling to 20% success at
  30% loss, and 0% success at 50% and 70% loss — a sharp cliff between
  10% and 30%, not a gradual decline.
- **The deeper evidence:** CloudWatch logs show 11,500+ `RETY`-tagged
  lines across the 30/50/70% levels — the retry mechanism itself works
  exactly as designed; failures at 30%+ are a correctly-functioning but
  budget-exhausted retry loop, not a broken one.
- **Takeaway:** the fixed 5-OPEN/5-RETY retry budget fully absorbs ~10%
  loss (at ~3x the latency) but collapses by 30% — and this is compounded
  by a second, independent source of effective loss (the queue-overload
  discovery above), which the retry budget wasn't tuned to cover.

## 2. Experiment 2 — File size vs. transfer time, across the 4MB cap (~80 seconds)

- **Methodology:** fetched files from 10KB up to exactly 4MB (the
  protocol's hardcoded cap, `maxChunks = 65536` x 64 bytes) and one chunk
  over that cap, 5 times each, at 0% loss.
- **Finding:** success rate was **not** a flat 100% despite 0% configured
  loss — it degraded with size (100% at 10KB/100KB, 60% at 1MB, 20% at
  2MB, 80% at 4MB-at-cap) due to the same queue-overload mechanism as
  Experiment 1: more chunks means more self-inflicted RETY traffic. The
  over-cap file (4MB + 1 chunk) failed 100% of the time — a hard,
  deliberate protocol limit (`maxChunks` bounds check), not a performance
  cliff.
- **The code change:** raised `maxChunks` from 65536 to 131072 (4MB ->
  8MB) in `transfer-client/udp/udp-client.go`, rebuilt, redeployed. The
  patch works — the gateway accepts the larger response — but the 8MB
  fetch still **failed 100% of the time** (5/5, 504s) at 0% loss: all 5
  attempts hit `ErrIncomplete` after exhausting the full RETY budget,
  while the backend logged 73,154 overload-drop lines in that window
  (vs. 11,500+ for Experiment 1's *entire* loss sweep).
- **Takeaway:** the cap is a real, enforced safety limit, and raising it
  is a one-line, low-risk client-side change — but it's a *necessary, not
  sufficient* fix: the advertised limit and the service's actual
  reliability ceiling (set by the fixed worker-pool/retry-budget design)
  are two separate problems, and this experiment demonstrates both.

## 3. Experiment 3 — ALB vs. NLB-forced scaling trigger (~90 seconds)

- **Methodology:** lowered both scaling targets (gateway 100->20 req/min/
  task, backend 60%->30% CPU) so a 10-minute Locust run (200 users,
  ramping at 20/s) would cross both within the window, while polling
  both services' ECS task counts every 10 seconds.
- **The asymmetry being tested:** the gateway scales on
  `ALBRequestCountPerTarget` — a real per-target request-rate metric
  only an Application Load Balancer provides. The backend sits behind
  a Network Load Balancer, which has no equivalent, so it's forced onto
  `ECSServiceAverageCPUUtilization` instead.
- **Finding:** load overwhelmed the 2-task baseline almost instantly —
  98.56% request failure rate (20,750/21,359). Both metrics breached
  their targets within ~60 seconds of load starting (backend CPU hit
  52%, nearly double its 30% target; gateway's request rate hit
  ~1,040-1,109/min/target, ~50x its target of 20) — but neither service
  actually scaled out (2->4 tasks, both hit their configured max) until
  **5.5-6 minutes later**, just 16 seconds apart from each other.
- **Takeaway:** contrary to the expectation that a direct per-target
  request-rate metric should react meaningfully faster than a CPU proxy,
  **both metrics breached almost instantly and by huge margins — the
  actual ~5-6 minute delay came from AWS Application Auto Scaling's own
  target-tracking alarm mechanics (built to avoid flapping), which
  applied almost identically to both services.** The ALB-vs-NLB metric
  asymmetry mattered far less in practice than the scaler's own built-in
  reaction lag.

## 4. Closing (10 seconds)

"Across all three experiments, the service's documented design and its
actual behavior under real load diverged in interesting ways: a
worker-queue overload that silently compounds configured packet loss, a
protocol cap that's real but not the actual reliability ceiling, and an
auto-scaling metric asymmetry that turned out to matter far less than the
scaler's own multi-minute reaction delay — in each case, the thing worth
measuring wasn't the one the documentation pointed at."

---

## Backup slide / Q&A prep

- **If asked "why these three experiments specifically":** they cover
  three genuinely different axes — protocol resilience (loss), protocol
  limits (size/cap), and infrastructure behavior (scaling) — rather
  than three variations on the same theme.
- **If asked about a parameter you didn't test** (retry counts,
  in-flight limits, worker counts): name it honestly as out of scope
  for time, and state which of the three experiments' methodology you'd
  reuse to test it.
