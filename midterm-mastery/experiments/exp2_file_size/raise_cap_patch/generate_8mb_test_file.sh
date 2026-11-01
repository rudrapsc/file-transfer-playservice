#!/usr/bin/env bash
# Run this AFTER apply_raise_cap.sh. Generates and uploads an 8MB file --
# exactly at the new 131072-chunk cap -- to confirm the raised limit
# actually works end-to-end, not just that the constant changed.

set -euo pipefail

BUCKET="${1:?Usage: ./generate_8mb_test_file.sh <your-s3-bucket-name>}"
NAME="size-8mb-at-new-cap.bin"
BYTES=8388608   # 131072 chunks x 64 bytes

head -c "$BYTES" /dev/zero | tr '\0' 'C' > "$NAME"
aws s3 cp "$NAME" "s3://$BUCKET/tmp/$NAME"
echo "Uploaded $NAME ($BYTES bytes). Now fetch it:"
echo '  curl -o out.bin "$GATEWAY_URL/files?name='"$NAME"'"'
