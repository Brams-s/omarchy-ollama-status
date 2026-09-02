#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
python3 -m json.tool manifest.json >/dev/null
bash -n status.sh

# A PATH without curl must still produce one valid JSON error line and exit cleanly.
result=$(PATH="/nonexistent" /usr/bin/bash ./status.sh)
python3 -c 'import json, sys; value=json.loads(sys.stdin.read()); assert "error" in value' <<< "$result"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir "$tmpdir/bin"
cat > "$tmpdir/bin/curl" <<'EOF'
#!/usr/bin/bash
printf '%s\n' '{ "models": [] }'
EOF
chmod +x "$tmpdir/bin/curl"

# Non-loopback hosts must be rejected before curl is invoked.
result=$(PATH="$tmpdir/bin" OLLAMA_HOST="https://example.com" /usr/bin/bash ./status.sh)
python3 -c 'import json, sys; value=json.load(sys.stdin); assert "only permits" in value["error"]' <<< "$result"

# A literal loopback endpoint is accepted. The mock also proves formatted JSON passes through.
result=$(PATH="$tmpdir/bin" OLLAMA_HOST="http://127.0.0.1:11435" /usr/bin/bash ./status.sh)
python3 -c 'import json, sys; assert json.load(sys.stdin) == {"models": []}' <<< "$result"
printf '%s\n' 'ollama-status: static checks passed'
