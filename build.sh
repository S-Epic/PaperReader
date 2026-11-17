#!/bin/bash
set -euo pipefail

app_root="$(cd "$(dirname "$0")" && pwd)"
installed_python="$app_root/.runtime/venv/bin/python"
if [[ ! -x "$installed_python" ]]; then
    installed_python="$app_root/../.tools/pdf2zh-next/bin/python"
fi
build_dir="$app_root/.build"
dist_dir="$app_root/dist"
product="$dist_dir/PaperReader.app"

macos_major="$(/usr/bin/sw_vers -productVersion | cut -d. -f1)"
if [[ "$(uname -m)" != arm64 || "$macos_major" -lt 15 ]]; then
    printf '%s\n' 'PaperReader requires Apple silicon and macOS 15 or newer.' >&2
    exit 1
fi
if [[ ! -x "$installed_python" ]]; then
    printf '%s\n' 'Run ./bootstrap.sh to install the PaperReader engine before building.' >&2
    exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
    printf '%s\n' 'Install the Xcode Command Line Tools with xcode-select --install.' >&2
    exit 1
fi

"$installed_python" - <<'PY'
from importlib.metadata import version
import sys

if sys.version_info[:2] != (3, 12) or (
    version("pdf2zh-next"), version("BabelDOC")
) != ("2.10.2", "0.7.1"):
    raise SystemExit("Engine versions do not match this build. Run ./bootstrap.sh.")
PY

mkdir -p "$build_dir/module-cache" "$dist_dir"
stage="$(mktemp -d "$build_dir/package.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
app="$stage/PaperReader.app"
engine="$app/Contents/Resources/Engine"
mkdir -p "$app/Contents/MacOS" "$engine"

xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx15.0 \
    -module-cache-path "$build_dir/module-cache" \
    "$app_root"/Sources/*.swift -o "$app/Contents/MacOS/PaperReader"
cp "$app_root/Info.plist" "$app/Contents/Info.plist"
cp "$app_root/engine_bridge.py" "$engine/engine_bridge.py"

python_home="$("$installed_python" -c 'import sys; print(sys.base_prefix)')"
site_packages="$("$installed_python" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
cp -cR "$python_home" "$engine/python"
cp -cR "$site_packages" "$engine/site-packages"

"$installed_python" "$app_root/patches/enable_deepseek_flash.py" "$engine/site-packages"
PYTHONPATH="$engine/site-packages" PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 \
    "$engine/python/bin/python3.12" - <<'PY'
import babeldoc
import pymupdf
from pdf2zh_next.config.translate_engine_model import DeepSeekSettings

settings = DeepSeekSettings(deepseek_model="deepseek-flash", deepseek_thinking_mode="disabled")
assert settings.transform()._openai_extra_body == {"thinking": {"type": "disabled"}}
PY
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"

if [[ -e "$product" ]]; then
    mv "$product" "$stage/previous.app"
fi
if ! mv "$app" "$product"; then
    if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$product"; fi
    exit 1
fi
printf '%s\n' "$product"
