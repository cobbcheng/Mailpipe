#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-mail-parser.sh --universal
MAILPIPE_SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
if [ -n "${MAILPIPE_DEVELOPMENT_TEAM:-}" ]; then
  MAILPIPE_SIGNING_ARGS=(CODE_SIGNING_ALLOWED=YES "DEVELOPMENT_TEAM=$MAILPIPE_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Apple Development")
fi
exec env -u SDKROOT xcodebuild -project Mailpipe.xcodeproj -scheme Mailpipe \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath "${MAILPIPE_DERIVED_DATA_PATH:-.build/xcode}" "${MAILPIPE_SIGNING_ARGS[@]}" build "$@"
