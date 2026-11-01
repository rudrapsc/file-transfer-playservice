#!/usr/bin/env bash
# Raises the client's maxChunks from 65536 (4 MiB) to 131072 (8 MiB),
# rebuilds, and redeploys, so you can demonstrate the over-cap file from
# Experiment 2 succeeding once the limit is actually changed, directly
# answering the assignment's own "built in max of 4MB which can be
# changed" hint.
#
# WHAT CHANGES, EXACTLY (for your writeup -- "no need to include all the
# Go files", just describe this):
#   File: transfer-client/udp/udp-client.go
#   Before: const maxChunks = 65536   // 4 MiB
#   After:  const maxChunks = 131072  // 8 MiB
#
# WHY: maxChunks is the client's own safety ceiling on how many chunks a
# single datagram's NUM_CHUNKS field is allowed to claim (parseDatagram
# rejects anything larger) -- it exists specifically to stop a malformed
# or hostile datagram from making the client allocate/request millions
# of chunks. Doubling it doubles the largest file the protocol can
# transfer, at the cost of a (still bounded, still safe) higher ceiling.
#
# USAGE: run from this directory. Reverts automatically are NOT done for
# you -- restore from udp-client.go.ORIGINAL if you want the original
# 4MB limit back afterward.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TARGET="$REPO_ROOT/transfer-client/udp/udp-client.go"

echo "=== Before ==="
grep -n "maxChunks" "$TARGET"

sed -i 's/maxChunks[[:space:]]*= 65536/maxChunks       = 131072/' "$TARGET"

echo "=== After ==="
grep -n "maxChunks" "$TARGET"

echo
echo "=== Rebuilding and redeploying with the new client ==="
(cd "$REPO_ROOT" && scripts/deploy.sh --yes)

echo
echo "Now re-upload an 8MB test file (see generate_8mb_test_file.sh) and"
echo "re-run the over-cap case from run_size_sweep.sh against it -- it"
echo "should now succeed where the original 4MB-capped client failed."
