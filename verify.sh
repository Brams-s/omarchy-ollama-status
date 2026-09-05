#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
python3 -m json.tool manifest.json >/dev/null
python3 - <<'PY'
import json
import re
from pathlib import Path
manifest = json.load(open("manifest.json"))
version = manifest["version"]
assert re.fullmatch(r"\d+\.\d+\.\d+", version)
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
readme = Path("README.md").read_text()
changelog = Path("CHANGELOG.md").read_text()
release_header = re.compile(rf"^## \[{re.escape(version)}\] — \d{{4}}-\d{{2}}-\d{{2}}$", re.MULTILINE)
assert release_header.search(changelog)
preview_match = re.search(r"!\[[^]]*\]\(([^)]+)\)", readme)
assert preview_match
preview = Path(preview_match.group(1))
assert not preview.is_absolute() and preview.parent == Path(".")
assert preview.is_file() and preview.stat().st_size > 0
helper = Path("ci/qml-validate.sh")
workflow = Path(".github/workflows/verify.yml")
assert helper.is_file()
assert workflow.is_file()
helper_text = helper.read_text()
assert "command -v quickshell" in helper_text
assert "OMARCHY_SHELL_ROOT" in helper_text
assert '"$qmllint"' in helper_text and '-I "$import_root"' in helper_text
assert "--import error" in helper_text
assert "--missing-type error" in helper_text
assert "--unresolved-type error" in helper_text
assert "--max-warnings -1" in helper_text
workflow_text = workflow.read_text()
assert "ci/qml-validate.sh" in workflow_text
assert "OMARCHY_SHELL_ROOT=/opt/omarchy/shell" in workflow_text
assert "quickshell qt6-declarative" in workflow_text
assert "qmllint is unavailable; no QML dependencies are installed by CI" not in workflow_text
assert "ARCH_IMAGE: docker.io/library/archlinux@sha256:694da1fce635e3a14d90751941b08f02c500e8724682f7a00768e7152251ec34" in workflow_text
assert "archlinux:base-devel@sha256:" not in workflow_text
assert "ARCH_IMAGE_DATE: 2026-09-02" in workflow_text
assert "ARCHIVE_DATE: 2026/09/02" in workflow_text
assert "archive.archlinux.org/repos/${ARCHIVE_DATE}" in workflow_text
assert "fetch-depth: 0" in workflow_text
assert "./ci/check-whitespace.sh" in workflow_text
whitespace_helper = Path("ci/check-whitespace.sh")
assert whitespace_helper.is_file()
whitespace_text = whitespace_helper.read_text()
assert '"$base...$head"' in whitespace_text
assert '"$before" "$head"' in whitespace_text
assert "empty_tree" in whitespace_text
PY

if command -v node >/dev/null 2>&1; then
  node ./test-model.js
else
  printf '%s\n' 'ollama-status: node unavailable; skipped helper tests'
fi

/usr/bin/python3 -m unittest -v tests.test_runtime_boundaries

printf '%s\n' 'ollama-status: static checks passed'
