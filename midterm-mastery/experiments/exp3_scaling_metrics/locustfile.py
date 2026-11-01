import random
from locust import task, between
from locust import FastHttpUser

# A mix of file sizes so backend CPU load varies realistically (bigger
# files = more chunks = more UDP round trips per request), while gateway
# request COUNT (what the ALB metric tracks) is driven purely by request
# rate, independent of which file size was requested. This independence
# is exactly what makes this a fair test of "which trigger reacts to
# load faster" -- the two services' bottlenecks are genuinely different
# shapes (gateway: request rate; backend: per-request CPU work), matching
# the real ALB-vs-NLB metric asymmetry this experiment investigates.
TEST_FILES = [
    "size-10kb.bin",
    "size-100kb.bin",
    "size-1mb.bin",
]


class GatewayUser(FastHttpUser):
    wait_time = between(0.05, 0.2)

    @task
    def fetch_file(self):
        name = random.choice(TEST_FILES)
        self.client.get(f"/files?name={name}", name="/files")


# ------------------------------------------------------------------
# Run against the gateway's public ALB DNS name (never the backend --
# it's internal-only behind the NLB and not reachable from your laptop
# at all, by design):
#
#   locust -f locustfile.py --headless -u 200 -r 20 -t 10m \
#     --host http://<gateway-alb-dns> --csv=scaling-test
#
# Tune -u (user count) upward if the defaults (gateway_requests_per_target
# = 100 req/min/task, backend_cpu_target = 60%) don't get crossed within
# a reasonable test window -- see watch_scaling.sh for how to confirm
# whether either trigger actually fired during your run.
# ------------------------------------------------------------------
