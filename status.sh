#!/usr/bin/env bash
# Local-only, structured client for Ollama's documented HTTP API.
set -u

MAX_RESPONSE_BYTES=65536
operation="${1:-status}"
invalid_operation=false
case "$operation" in
  status|version|unload) ;;
  *) operation="status"; invalid_operation=true ;;
esac
host="${OLLAMA_HOST:-http://127.0.0.1:11434}"

case "$host" in
  http://*|https://*) ;;
  *) host="http://$host" ;;
esac
host="${host%/}"

result_error() {
  local kind="$1" message="$2"
  printf '{"ok":false,"operation":"%s","kind":"%s","error":"%s"}\n' "$operation" "$kind" "$message"
}

have_literal_loopback_host() {
  [[ "$host" =~ ^https?://127(\.[0-9]{1,3}){3}(:[0-9]{1,5})?$ ]] \
    || [[ "$host" =~ ^https?://\[::1\](:[0-9]{1,5})?$ ]]
}

command -v curl >/dev/null 2>&1 || {
  result_error "missing_dependency" "Missing dependency: curl is required to contact the Ollama API."
  exit 0
}

if ! have_literal_loopback_host; then
  result_error "unsafe_endpoint" "For safety, Ollama Status only permits a literal loopback endpoint (127.0.0.1 or [::1])."
  exit 0
fi

command -v python3 >/dev/null 2>&1 || {
  result_error "missing_dependency" "Missing dependency: python3 is required to validate Ollama API responses."
  exit 0
}

tmpdir=$(mktemp -d) || {
  result_error "internal_error" "Ollama Status could not prepare a local request."
  exit 0
}
trap 'rm -rf "$tmpdir"' EXIT
body="$tmpdir/body.json"

request() {
  # -q must be first so curl ignores user and system curl configuration. Do not
  # allow proxy environment configuration to redirect even loopback traffic.
  curl -q --noproxy '*' --fail --silent --show-error --connect-timeout 1 --max-time 3 \
    --max-filesize "$MAX_RESPONSE_BYTES" "$@" >"$body" 2>/dev/null
}

bounded_body() {
  local size
  size=$(wc -c <"$body") || return 1
  [[ "$size" -le "$MAX_RESPONSE_BYTES" ]]
}

if [[ "$operation" == "unload" ]]; then
  model="${2:-}"
  [[ -n "$model" ]] || { result_error "invalid_request" "No model was selected to unload."; exit 0; }
  payload=$(MODEL="$model" python3 -c 'import json, os; print(json.dumps({"model": os.environ["MODEL"], "messages": [], "keep_alive": 0, "stream": False}, separators=(",", ":")))') || {
    result_error "internal_error" "Could not prepare the unload request."
    exit 0
  }
  request --request POST --header "Content-Type: application/json" --data "$payload" "$host/api/chat"
  request_status=$?
  if [[ "$request_status" -ne 0 ]]; then
    if [[ "$request_status" -eq 63 ]]; then
      result_error "response_too_large" "Ollama returned an oversized unload response."
    else
      result_error "transport_error" "Ollama did not accept the unload request."
    fi
    exit 0
  fi
  if ! bounded_body; then
    result_error "response_too_large" "Ollama returned an oversized unload response."
    exit 0
  fi
  python3 - "$body" <<'PY' 2>/dev/null || { result_error "invalid_data" "Ollama returned an invalid unload response."; exit 0; }
import json, sys
with open(sys.argv[1], "rb") as handle:
    response = json.load(handle)
if not isinstance(response, dict):
    raise ValueError("not an object")
if response.get("error"):
    print('{"ok":false,"operation":"unload","kind":"api_error","error":"Ollama rejected the unload request."}')
elif response.get("done") is True:
    print('{"ok":true,"operation":"unload","data":{"done":true}}')
else:
    raise ValueError("missing done")
PY
  exit 0
fi

if [[ "$invalid_operation" == true ]]; then
  result_error "invalid_request" "Unknown Ollama Status operation."
  exit 0
fi

path="/api/ps"
[[ "$operation" == "version" ]] && path="/api/version"
request "$host$path"
request_status=$?
if [[ "$request_status" -ne 0 ]]; then
  if [[ "$request_status" -eq 63 ]]; then
    result_error "response_too_large" "Ollama returned an oversized response."
  else
    result_error "transport_error" "Cannot reach the configured Ollama endpoint. Start Ollama using your preferred setup."
  fi
  exit 0
fi
if ! bounded_body; then
  result_error "response_too_large" "Ollama returned an oversized response."
  exit 0
fi

python3 - "$operation" "$body" <<'PY' 2>/dev/null || { result_error "invalid_data" "Ollama returned an invalid API response."; exit 0; }
import json, math, sys

operation, path = sys.argv[1:]
with open(path, "rb") as handle:
    response = json.load(handle)
if not isinstance(response, dict) or response.get("error"):
    raise ValueError("invalid API object")

if operation == "version":
    version = response.get("version")
    if not isinstance(version, str) or not version or len(version) > 80:
        raise ValueError("invalid version")
    print(json.dumps({"ok": True, "operation": "version", "data": {"version": version}}, separators=(",", ":")))
else:
    values = response.get("models")
    if not isinstance(values, list):
        raise ValueError("missing models")
    models = []
    aggregate_vram = 0.0
    records = []
    for item in values:
        if not isinstance(item, dict):
            continue
        source_name = item.get("name") if isinstance(item.get("name"), str) else item.get("model")
        if not isinstance(source_name, str) or not source_name:
            continue
        records.append((item, source_name))
        value = item.get("size_vram")
        if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value > 0:
            candidate = aggregate_vram + value
            if math.isfinite(candidate):
                aggregate_vram = candidate
    for item, source_name in records[:12]:
        clean = {}
        for key in ("name", "model", "expires_at"):
            if isinstance(item.get(key), str):
                clean[key] = item[key][:512]
        # action_id is never derived from the display-safe, potentially sliced
        # name above. Its value is the original API identifier or absent.
        if len(source_name) <= 256:
            clean["action_id"] = source_name
        for key in ("size", "size_vram", "context_length"):
            value = item.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0:
                clean[key] = value
        models.append(clean)
    print(json.dumps({"ok": True, "operation": "status", "data": {"models": models, "loadedModelCount": len(records), "aggregateVramBytes": aggregate_vram}}, separators=(",", ":")))
PY
