#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Resolve from the selected Xcode, not a stale inherited SDKROOT.
MAILPIPE_SDK_PATH="$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)"
exec env SDKROOT="$MAILPIPE_SDK_PATH" xcrun swift "$@"
