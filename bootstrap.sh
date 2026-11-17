#!/bin/bash
set -euo pipefail

app_root="$(cd "$(dirname "$0")" && pwd)"
runtime="$app_root/.runtime"
macos_major="$(/usr/bin/sw_vers -productVersion | cut -d. -f1)"

if [[ "$(uname -m)" != arm64 || "$macos_major" -lt 15 ]]; then
    printf '%s\n' 'PaperReader requires Apple silicon and macOS 15 or newer.' >&2
    exit 1
fi

if command -v uv >/dev/null 2>&1; then
    uv_bin="$(command -v uv)"
elif [[ -x "$app_root/../.bootstrap/bin/uv" ]]; then
    uv_bin="$app_root/../.bootstrap/bin/uv"
else
    printf '%s\n' 'Install uv from https://docs.astral.sh/uv/getting-started/installation/ and rerun ./bootstrap.sh.' >&2
    exit 1
fi

export UV_CACHE_DIR="${UV_CACHE_DIR:-$runtime/cache}"
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$runtime/python}"
"$uv_bin" --no-config venv --managed-python --python 3.12.16 "$runtime/venv"
"$uv_bin" --no-config pip sync --python "$runtime/venv/bin/python" --only-binary :all: \
    "$app_root/requirements-macos-arm64.txt"
