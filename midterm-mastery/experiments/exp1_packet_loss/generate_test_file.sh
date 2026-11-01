#!/usr/bin/env bash
# Generates the fixed 500KB test file this experiment uses, and uploads
# it to your S3 bucket's tmp/ prefix (adjust BUCKET below, or pass it
# as $1). The backend reads files from S3, not local disk, once deployed
# on AWS -- see README.md's "Local Setup" vs "AWS Architecture" sections.

set -euo pipefail

BUCKET="${1:?Usage: ./generate_test_file.sh <your-s3-bucket-name>}"
FILE="loss-test-500kb.bin"

# Deterministic, reproducible content (not /dev/urandom) so repeated runs
# are comparable and you can sanity-check the downloaded file matches.
head -c 512000 /dev/zero | tr '\0' 'A' > "$FILE"

aws s3 cp "$FILE" "s3://$BUCKET/tmp/$FILE"
echo "Uploaded $FILE (512000 bytes) to s3://$BUCKET/tmp/$FILE"
