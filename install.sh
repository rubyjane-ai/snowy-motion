#!/bin/zsh
# Builds Snowy Motion from this source and installs it as /Applications/Snowy Motion.app.
# Usage: zsh install.sh
#
# The Swift code is compiled with Apple's Command Line Tools (no full Xcode needed).
# Sparkle, the Metal shader library and the icon are taken from the official
# Snowy 0.11.4 release, which this fork is based on (checksum-verified download).
set -euo pipefail
src="${0:A:h}"
cd "$src"

APP_NAME="Snowy Motion"
BUNDLE_ID="app.snowymotion.desktop"
BASE_VERSION="0.11.4"
BASE_URL="https://github.com/soloiaros/snowy-mac/releases/download/v${BASE_VERSION}/Snowy-macOS-arm64.zip"
BASE_SHA256="a33574390121ddcd6b69400243aa6ac12b830c337390ca87e3fe514b66f00c60"
DEST="/Applications/${APP_NAME}.app"

say() { print -P "%F{cyan}==>%f $1"; }
fail() { print -P "%F{red}Error:%f $1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS only."
[[ "$(uname -m)" == "arm64" ]] || fail "Apple Silicon Mac required."

if ! xcode-select -p >/dev/null 2>&1; then
  say "Apple Command Line Tools are needed. An installer window will open."
  xcode-select --install || true
  fail "run this script again after the Command Line Tools finish installing."
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

say "Downloading the official Snowy ${BASE_VERSION} bundle (Sparkle, shaders, icon)…"
curl -fsSL "$BASE_URL" -o "$work/base.zip" || fail "download failed: $BASE_URL"
actual="$(shasum -a 256 "$work/base.zip" | awk '{print $1}')"
[[ "$actual" == "$BASE_SHA256" ]] || fail "checksum mismatch for the downloaded Snowy ${BASE_VERSION} bundle."
ditto -x -k "$work/base.zip" "$work"
app="$work/Snowy.app"
[[ -f "$app/Contents/Resources/Snow.metallib" ]] || fail "unexpected bundle layout."

say "Building Snowy Motion (the first build downloads Sparkle and takes a few minutes)…"
swift build -c release --product Snowy
binary="$(swift build -c release --show-bin-path)/Snowy"
[[ -x "$binary" ]] || fail "the build did not produce an executable."

cp "$binary" "$app/Contents/MacOS/Snowy"
runtime_paths="$(otool -l "$app/Contents/MacOS/Snowy" | awk '/cmd LC_RPATH$/ { getline; getline; sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print }')"
while IFS= read -r runtime_path; do
  case "$runtime_path" in
    ''|/usr/lib/swift|@executable_path/../Frameworks) ;;
    *) install_name_tool -delete_rpath "$runtime_path" "$app/Contents/MacOS/Snowy" ;;
  esac
done <<< "$runtime_paths"

# Own name and identifier, so it never replaces or updates over the official Snowy.
# The high build number keeps the bundled updater from offering official releases.
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleName ${APP_NAME}" \
  -c "Set :CFBundleDisplayName ${APP_NAME}" \
  -c "Set :CFBundleIdentifier ${BUNDLE_ID}" \
  -c "Set :CFBundleVersion 9019" \
  -c "Set :CFBundleShortVersionString ${BASE_VERSION}-motion" \
  "$app/Contents/Info.plist"
xattr -cr "$app"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

say "Installing to ${DEST}…"
pkill -x Snowy >/dev/null 2>&1 || true   # also quits the official Snowy, so snow isn't drawn twice
sleep 1
if [[ -d "$DEST" ]]; then
  mv "$DEST" "$HOME/.Trash/${APP_NAME}-old-$(date +%Y%m%d-%H%M%S).app" 2>/dev/null \
    || rm -rf "$DEST" 2>/dev/null \
    || fail "macOS did not let Terminal replace ${DEST}. Move it to the Trash in Finder and run this again."
fi
ditto "$app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
open "$DEST"
say "Done: ${APP_NAME} is running. If you also have the official Snowy, keep only one of them open."
