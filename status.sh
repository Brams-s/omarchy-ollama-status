#!/usr/bin/env bash
# A deliberately small client for Ollama's documented local HTTP API.
set -u

host="${OLLAMA_HOST:-http://127.0.0.1:11434}"
case "$host" in
  http://*|https://*) ;;
  *) host="http://$host" ;;
esac
host="${host%/}"

error() {
  # Keep errors machine-readable so the widget can display them safely.
  printf '%s\n' "{\"error\":\"$1\"}"
}

command -v curl >/dev/null 2>&1 || {
  error "Missing dependency: curl is required to contact the Ollama API."
  exit 0
}

# This widget is deliberately a local status surface, never a client for a
# remote Ollama server. Literal loopback addresses also avoid trusting DNS.
if [[ ! "$host" =~ ^https?://127(\.[0-9]{1,3}){3}(:[0-9]{1,5})?$ && ! "$host" =~ ^https?://\[::1\](:[0-9]{1,5})?$ ]]; then
  error "For safety, Ollama Status only permits a literal loopback endpoint (127.0.0.1 or [::1])."
  exit 0
fi

if [[ "${1:-status}" == "unload" ]]; then
  model="${2:-}"
  [[ -n "$model" ]] || { error "No model was selected to unload."; exit 0; }
  command -v python3 >/dev/null 2>&1 || {
    error "Missing dependency: python3 is required to unload a model safely."
    exit 0
  }
  payload=$(MODEL="$model" python3 -c 'import json, os; print(json.dumps({"model": os.environ["MODEL"], "keep_alive": 0}))') || {
    error "Could not prepare the unload request."
    exit 0
  }
  curl --fail --silent --show-error --connect-timeout 1 --max-time 3 \
    --request POST --header "Content-Type: application/json" \
    --data "$payload" "$host/api/generate" >/dev/null || {
      error "Ollama did not accept the unload request."
      exit 0
    }
  printf '%s\n' '{"ok":true}'
  exit 0
fi

curl --fail --silent --show-error --connect-timeout 1 --max-time 2 --max-filesize 1048576 "$host/api/ps" 2>/dev/null || {
  error "Cannot reach the configured Ollama endpoint. Start Ollama using your preferred setup."
  exit 0
}
