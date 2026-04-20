#!/usr/bin/env bash
# refresh-api-spec.sh — regenerate embedded OpenAPI specs from the live Altitude backend
#
# Starts altitude-BE locally (dev profile), polls /v3/api-docs until ready, writes the
# spec to both onboarding and API plugins, then stops the server.
#
# Usage:
#   ./tools/refresh-api-spec.sh [--altitude-be-path /path/to/altitude-BE]
#
# Requires: the altitude-BE repo checked out locally, Docker running (Postgres),
# Java 21, Gradle (via wrapper). Same stack the dev normally uses.

set -euo pipefail

ALTITUDE_BE="${ALTITUDE_BE:-$HOME/Development/altitude-BE}"
MARKETPLACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-8080}"
BOOT_TIMEOUT_SECS=300
LOG_FILE="/tmp/altcore-bootrun-$$.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --altitude-be-path) ALTITUDE_BE="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 2;;
  esac
done

if [[ ! -d "$ALTITUDE_BE" ]]; then
  echo "altitude-BE not found at: $ALTITUDE_BE" >&2
  echo "Pass --altitude-be-path or set ALTITUDE_BE env var." >&2
  exit 1
fi

cleanup() {
  if [[ -n "${GRADLE_PID:-}" ]] && kill -0 "$GRADLE_PID" 2>/dev/null; then
    echo "Stopping bootRun (PID $GRADLE_PID)..."
    kill "$GRADLE_PID" 2>/dev/null || true
    sleep 2
    kill -9 "$GRADLE_PID" 2>/dev/null || true
  fi
  pkill -f "AltcoreApp" 2>/dev/null || true
  rm -f "$LOG_FILE"
}
trap cleanup EXIT INT TERM

echo ">> Starting altitude-BE at $ALTITUDE_BE ..."
(cd "$ALTITUDE_BE" && nohup ./gradlew :local-dev:bootRun > "$LOG_FILE" 2>&1 &)
GRADLE_PID=$!

echo ">> Waiting for http://localhost:$PORT/v3/api-docs (timeout ${BOOT_TIMEOUT_SECS}s)..."
elapsed=0
while (( elapsed < BOOT_TIMEOUT_SECS )); do
  code=$(curl -s --connect-timeout 2 -o /dev/null -w "%{http_code}" "http://localhost:$PORT/v3/api-docs" || echo 000)
  if [[ "$code" == "200" ]]; then
    echo ">> Server up after ${elapsed}s"
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

if [[ "$code" != "200" ]]; then
  echo "Server failed to start within ${BOOT_TIMEOUT_SECS}s. Last 40 log lines:" >&2
  tail -40 "$LOG_FILE" >&2
  exit 1
fi

TMP_SPEC=$(mktemp -t altcore-api.XXXXXX.json)
trap 'rm -f "$TMP_SPEC"; cleanup' EXIT
curl -s --max-time 60 "http://localhost:$PORT/v3/api-docs" -o "$TMP_SPEC"

python3 - "$TMP_SPEC" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  openapi={d.get('openapi')} version={d.get('info',{}).get('version')} "
      f"title={d.get('info',{}).get('title')} paths={len(d.get('paths',{}))} "
      f"schemas={len(d.get('components',{}).get('schemas',{}))}")
PY

for target in \
    "plugins/m62-altitude-onboarding/skills/m62-altitude-onboarding/api-docs/api.json" \
    "plugins/m62-altitude-api/skills/m62-altitude-api/api-docs/api.json"; do
  dest="$MARKETPLACE_ROOT/$target"
  mkdir -p "$(dirname "$dest")"
  cp "$TMP_SPEC" "$dest"
  echo ">> Wrote $dest"
done

echo ">> Done. Remember to bump the 'Updated:' date in references/altitude_api_endpoints.md"
echo "   and references/altitude_api_schema.md."
