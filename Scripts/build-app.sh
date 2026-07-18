#!/bin/bash
# Build CodexAura and assemble a self-contained CodexAura.app (ad-hoc signed,
# no Apple developer account needed).
set -euo pipefail

cd "$(dirname "$0")/.."
APP_DIR="${1:-build/CodexAura.app}"

echo "==> swift build (release, arm64 + x86_64)"
swift build -c release --arch arm64
swift build -c release --arch x86_64

ARM_BIN=".build/arm64-apple-macosx/release/CodexAura"
X86_BIN=".build/x86_64-apple-macosx/release/CodexAura"
[ -x "$ARM_BIN" ] || { echo "build failed: $ARM_BIN missing" >&2; exit 1; }
[ -x "$X86_BIN" ] || { echo "build failed: $X86_BIN missing" >&2; exit 1; }

echo "==> assembling $APP_DIR (universal)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP_DIR/Contents/MacOS/CodexAura"
cp Scripts/Info.plist "$APP_DIR/Contents/Info.plist"

# SwiftPM resource bundle (payload.js / skin.css) — arch-independent.
BUNDLE=".build/arm64-apple-macosx/release/CodexAura_CodexAura.bundle"
if [ -d "$BUNDLE" ]; then
  cp -R "$BUNDLE" "$APP_DIR/Contents/Resources/"
fi

echo "==> ad-hoc codesign"
codesign --force --sign - --timestamp=none "$APP_DIR"

echo "==> done: $APP_DIR"
echo "首次运行如被 Gatekeeper 拦截：右键 App → 打开"
