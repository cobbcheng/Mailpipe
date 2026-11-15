#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec env -u SDKROOT xcodebuild -project Mailpipe.xcodeproj -scheme Mailpipe \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build "$@"
