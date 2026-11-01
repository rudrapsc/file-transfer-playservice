#!/usr/bin/env bash
# Generates test files spanning small to exactly-at-the-protocol-cap to
# past-the-cap, and uploads them to S3.
#
# The cap: maxChunks = 65536 chunks x 64 bytes/chunk = exactly 4,194,304
# bytes (4 MiB), hardcoded in transfer-client/udp/udp-client.go. A file
# at or under that size works; strictly over it, the client's own
# parseDatagram validation (id > num_chunks, or num_chunks > maxChunks)
# will reject it -- see that function's error path for the exact message.

set -euo pipefail

BUCKET="${1:?Usage: ./generate_test_files.sh <your-s3-bucket-name>}"
DIR="test_files"
mkdir -p "$DIR"

# name:bytes pairs. 4194304 is EXACTLY at the cap (65536 x 64).
# 4194368 is one chunk (64 bytes) over it.
declare -A SIZES=(
  ["size-10kb.bin"]=10240
  ["size-100kb.bin"]=102400
  ["size-1mb.bin"]=1048576
  ["size-2mb.bin"]=2097152
  ["size-4mb-at-cap.bin"]=4194304
  ["size-4mb-plus-1chunk-OVER-cap.bin"]=4194368
)

for NAME in "${!SIZES[@]}"; do
  BYTES="${SIZES[$NAME]}"
  head -c "$BYTES" /dev/zero | tr '\0' 'B' > "$DIR/$NAME"
  aws s3 cp "$DIR/$NAME" "s3://$BUCKET/tmp/$NAME"
  echo "Uploaded $NAME ($BYTES bytes)"
done

echo
echo "All test files uploaded. The 4mb-plus-1chunk-OVER-cap file is"
echo "EXPECTED to fail against the unmodified service -- that failure"
echo "IS the result for that row, not a bug in this script."
