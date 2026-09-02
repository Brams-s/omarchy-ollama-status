#!/usr/bin/env bash
# Resolve the real Quickshell and Omarchy Quattro QML modules before linting.
# This deliberately fails when either environment is absent; callers must not
# silently downgrade the release check to a bare qmllint invocation.
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
shell_root=${OMARCHY_SHELL_ROOT:-}
quickshell_import_root=${QUICKSHELL_QML_IMPORT_ROOT:-/usr/lib/qt6/qml}

if [[ -n "${QMLLINT:-}" ]]; then
  qmllint=$QMLLINT
elif command -v qmllint >/dev/null 2>&1; then
  qmllint=$(command -v qmllint)
elif [[ -x /usr/lib/qt6/bin/qmllint ]]; then
  qmllint=/usr/lib/qt6/bin/qmllint
else
  printf '%s\n' 'QML validation requires Qt qmllint.' >&2
  exit 1
fi

command -v quickshell >/dev/null 2>&1 || {
  printf '%s\n' 'QML validation requires the Quickshell executable and QML module.' >&2
  exit 1
}
[[ -d "$quickshell_import_root/Quickshell" ]] || {
  printf '%s\n' "QML validation cannot find Quickshell imports in $quickshell_import_root." >&2
  exit 1
}
[[ -n "$shell_root" && -f "$shell_root/Commons/qmldir" && -f "$shell_root/Ui/qmldir" ]] || {
  printf '%s\n' 'QML validation requires OMARCHY_SHELL_ROOT with the Quattro Commons and Ui import modules.' >&2
  exit 1
}

import_root=$(mktemp -d)
trap 'rm -rf "$import_root"' EXIT
mkdir -p "$import_root/qs"
ln -s "$shell_root/Commons" "$import_root/qs/Commons"
ln -s "$shell_root/Ui" "$import_root/qs/Ui"

cd "$root_dir"
printf '%s\n' 'qmllint policy: import, missing-type, and unresolved-type diagnostics are errors; other diagnostics remain visible and nonfatal.'
"$qmllint" \
  --import error \
  --missing-type error \
  --unresolved-type error \
  --max-warnings -1 \
  -I "$import_root" \
  -I "$quickshell_import_root" \
  BarWidget.qml Panel.qml Service.qml
