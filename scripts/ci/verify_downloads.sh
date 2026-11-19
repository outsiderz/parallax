#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
: "SDK_FILE" "IMAGE_FILE" "DOWNLOAD_DIR"
cd "$DOWNLOAD_DIR"
for file in "$SDK_FILE" "$IMAGE_FILE"; do
  # OpenWrt sha256sums uses the valid GNU binary marker '*filename'.
  # Rewrite the exact matching line to a two-space sha256sum input.
  awk -v filename="$file" '
    $2 == "*" filename || $2 == filename { print $1 "  " filename; count++ }
    END { if (count != 1) exit 1 }
  ' sha256sums > "$file.checksum"
  echo "Verifying $file"
  sha256sum -c "$file.checksum"
done
