#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
python3 -m json.tool manifest.json >/dev/null
python3 - <<'PY'
import json
manifest = json.load(open("manifest.json"))
assert manifest["keepLoaded"] is True
assert {"service", "bar-widget"}.issubset(manifest["kinds"])
assert manifest["entryPoints"]["service"] == "Service.qml"
assert "settingsSchema" not in manifest
widget = manifest["barWidget"]
assert widget["defaults"] == {"refreshIntervalSec": 15, "maxDisplayedModels": 12, "compactMode": False}
schema = {item["key"]: item for item in widget["schema"]}
assert schema["refreshIntervalSec"]["type"] == "integer" and schema["refreshIntervalSec"]["min"] == 5 and schema["refreshIntervalSec"]["max"] == 300
assert schema["maxDisplayedModels"]["type"] == "integer" and schema["maxDisplayedModels"]["min"] == 1 and schema["maxDisplayedModels"]["max"] == 12
assert schema["compactMode"]["type"] == "boolean"
bar_source = open("BarWidget.qml").read()
assert "String(root)" not in bar_source
assert "moduleSlots" in bar_source and "slotWindow(slot)" in bar_source
assert "configuredServiceSource" in bar_source and "unconfigure(configuredServiceSource)" in bar_source
service_source = open("Service.qml").read()
assert "lastRefreshCompletedMs" in service_source and "lastRefreshSucceeded" in service_source
assert "versionErrorKind" in service_source and "models = models.slice(0, maxDisplayedModels)" in service_source
PY
bash -n status.sh

if command -v node >/dev/null 2>&1; then
  node ./test-model.js
else
  printf '%s\n' 'ollama-status: node unavailable; skipped helper tests'
fi

# A PATH without curl must still produce one valid structured error and exit cleanly.
result=$(PATH="/nonexistent" /usr/bin/bash ./status.sh)
python3 -c 'import json, sys; value=json.load(sys.stdin); assert value["ok"] is False and value["kind"] == "missing_dependency"' <<< "$result"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir "$tmpdir/bin"
cat > "$tmpdir/bin/curl" <<'EOF'
#!/usr/bin/bash
set -eu
printf '%s\n' "$@" > "$MOCK_CURL_ARGS"
case "${MOCK_MODE:-status-ok}" in
  status-ok) printf '%s\n' '{"models":[{"name":"safe-model","size":10,"size_vram":5,"context_length":4096}]}' ;;
  version-ok) printf '%s\n' '{"version":"0.12.0"}' ;;
  malformed) printf '%s\n' '{not json' ;;
  oversized) python3 -c 'print("x" * 65537)' ;;
  unload-ok) printf '%s\n' '{"done":true}' ;;
  unload-api-error) printf '%s\n' '{"error":"untrusted raw API body must not be displayed"}' ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$tmpdir/bin/curl"

run_mock() {
  MOCK_CURL_ARGS="$tmpdir/curl-args" MOCK_MODE="$1" PATH="$tmpdir/bin:$PATH" /usr/bin/bash ./status.sh "${@:2}"
}

# Non-loopback hosts are rejected before curl can be invoked.
result=$(MOCK_CURL_ARGS="$tmpdir/curl-args" MOCK_MODE=status-ok PATH="$tmpdir/bin:$PATH" OLLAMA_HOST="https://example.com" /usr/bin/bash ./status.sh)
python3 -c 'import json, sys; value=json.load(sys.stdin); assert value["kind"] == "unsafe_endpoint"' <<< "$result"
test ! -e "$tmpdir/curl-args"

# curl starts with -q and explicitly disables proxy use before contacting a
# literal loopback endpoint, isolating user curl config and proxy variables.
result=$(run_mock status-ok status)
python3 -c 'import json, sys; value=json.load(sys.stdin); assert value["ok"] is True and value["data"]["models"][0]["name"] == "safe-model"' <<< "$result"
python3 - "$tmpdir/curl-args" <<'PY'
import sys
args = open(sys.argv[1]).read().splitlines()
assert args[:3] == ["-q", "--noproxy", "*"]
assert args[-1].endswith("/api/ps")
PY

result=$(run_mock version-ok version)
python3 -c 'import json, sys; value=json.load(sys.stdin); assert value == {"ok": True, "operation": "version", "data": {"version": "0.12.0"}}' <<< "$result"

# Bad and oversized bodies are classified without reflecting their contents.
result=$(run_mock malformed status)
python3 -c 'import json, sys; value=json.load(sys.stdin); assert value["kind"] == "invalid_data"' <<< "$result"
result=$(run_mock oversized status)
python3 -c 'import json, sys; value=json.load(sys.stdin); assert value["kind"] == "response_too_large"' <<< "$result"

# Unload uses non-streaming /api/chat with the documented keep_alive release.
result=$(run_mock unload-ok unload "safe-model")
python3 -c 'import json, sys; value=json.load(sys.stdin); assert value == {"ok": True, "operation": "unload", "data": {"done": True}}' <<< "$result"
python3 - "$tmpdir/curl-args" <<'PY'
import json, sys
args = open(sys.argv[1]).read().splitlines()
assert args[:3] == ["-q", "--noproxy", "*"]
assert args[-1].endswith("/api/chat")
payload = json.loads(args[args.index("--data") + 1])
assert payload == {"model": "safe-model", "messages": [], "keep_alive": 0, "stream": False}
PY
result=$(run_mock unload-api-error unload "safe-model")
python3 -c 'import json, sys; value=json.load(sys.stdin); assert value["kind"] == "api_error" and "untrusted" not in value["error"]' <<< "$result"

printf '%s\n' 'ollama-status: static checks passed'
