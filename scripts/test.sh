#!/usr/bin/env bash
# Runs the unit tests, plus the integration tests against a local test server.
#   scripts/test.sh          unit + integration tests
#   scripts/test.sh --unit   unit tests only
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

EXTRA=()
if [[ -n "${TESTING_PLUGINS:-}" ]]; then
  EXTRA=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS")
fi

if [[ "${1:-}" == "--unit" ]]; then
  swift test "${EXTRA[@]}"
  exit
fi

FILES="$(mktemp -d)"
trap 'kill "${SERVER:-0}" 2>/dev/null || true; rm -rf "$FILES"' EXIT
head -c 41943040 /dev/urandom > "$FILES/big.bin"
head -c 5000000 /dev/urandom > "$FILES/disposition.bin"
PORT=8799
python3 scripts/test-server.py "$PORT" "$FILES" &
SERVER=$!
sleep 1
NIDESTREAM_TEST_SERVER="http://127.0.0.1:$PORT" swift test "${EXTRA[@]}"
