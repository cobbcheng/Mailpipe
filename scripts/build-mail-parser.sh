#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

UNIVERSAL=0
if [ "${1:-}" = "--universal" ]; then
  UNIVERSAL=1
fi

CRATE_DIR="Packages/MailpipeMailParser"
XCFRAMEWORK="$CRATE_DIR/MailpipeMailParserFFI.xcframework"
STAMP_FILE="$XCFRAMEWORK/.build-stamp"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found; install Rust toolchain (rustup) to build MailpipeMailParser" >&2
  exit 1
fi

HOST_ARCH="$(uname -m)"
if [ "$UNIVERSAL" -eq 1 ]; then
  TARGETS=("aarch64-apple-darwin" "x86_64-apple-darwin")
  MODE="universal"
else
  if [ "$HOST_ARCH" = "arm64" ]; then
    TARGETS=("aarch64-apple-darwin")
  else
    TARGETS=("x86_64-apple-darwin")
  fi
  MODE="host-$HOST_ARCH"
fi

SOURCE_HASH="$(
  {
    printf '%s\n' "$MACOSX_DEPLOYMENT_TARGET"
    shasum -a 256 \
      "$CRATE_DIR/Cargo.toml" \
      "$CRATE_DIR/Cargo.lock" \
      "$CRATE_DIR/include/mailpipe_mail_parser.h" \
      "$CRATE_DIR/include/module.modulemap" \
      "$CRATE_DIR/src/"*.rs 2>/dev/null
  } | shasum -a 256 | awk '{print $1}'
)"
INPUT_HASH="${MODE}:${SOURCE_HASH}"

if [ -f "$STAMP_FILE" ] && [ -f "$XCFRAMEWORK/Info.plist" ]; then
  EXISTING_STAMP="$(cat "$STAMP_FILE")"
  if [ "$EXISTING_STAMP" = "$INPUT_HASH" ] || { [ "$UNIVERSAL" -eq 0 ] && [ "$EXISTING_STAMP" = "universal:${SOURCE_HASH}" ]; }; then
    exit 0
  fi
fi

for target in "${TARGETS[@]}"; do
  if command -v rustup >/dev/null 2>&1; then
    if ! rustup target list --installed | grep -qx "$target"; then
      rustup target add "$target"
    fi
  fi
  cargo build --manifest-path "$CRATE_DIR/Cargo.toml" --release --locked --target "$target"
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [ "$UNIVERSAL" -eq 1 ]; then
  lipo -create \
    "$CRATE_DIR/target/aarch64-apple-darwin/release/libmailpipe_mail_parser.a" \
    "$CRATE_DIR/target/x86_64-apple-darwin/release/libmailpipe_mail_parser.a" \
    -output "$WORK_DIR/libmailpipe_mail_parser.a"
else
  cp "$CRATE_DIR/target/${TARGETS[0]}/release/libmailpipe_mail_parser.a" "$WORK_DIR/libmailpipe_mail_parser.a"
fi

rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
  -library "$WORK_DIR/libmailpipe_mail_parser.a" \
  -headers "$CRATE_DIR/include" \
  -output "$XCFRAMEWORK" >/dev/null

printf '%s\n' "$INPUT_HASH" > "$STAMP_FILE"
