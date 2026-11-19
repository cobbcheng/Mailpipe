#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MAILPIPE_GUARD_DIR="$(mktemp -d)"
trap 'rm -rf "$MAILPIPE_GUARD_DIR"' EXIT
export MAILPIPE_UNEXPECTED_CALLS="$MAILPIPE_GUARD_DIR/unexpected-calls"
mkdir "$MAILPIPE_GUARD_DIR/bin"
for tool in claude codex dsh opencode; do
  cat > "$MAILPIPE_GUARD_DIR/bin/$tool" <<'GUARD'
#!/bin/sh
printf '%s\n' "$0" >> "$MAILPIPE_UNEXPECTED_CALLS"
exit 97
GUARD
  chmod +x "$MAILPIPE_GUARD_DIR/bin/$tool"
done
export PATH="$MAILPIPE_GUARD_DIR/bin:$PATH"
./scripts/swift.sh test "$@"
if [ -s "$MAILPIPE_UNEXPECTED_CALLS" ]; then
  echo 'FAIL: test attempted a real Harness command' >&2
  exit 1
fi
echo 'PASS: real Harness invocation log is empty'
