#!/usr/bin/env bash
# Build Spotify with the official spoti.pw 0.50.0 binary kit plus the standalone DistroFind companion.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
KIT_URL="${KIT_URL:-https://github.com/skopevoj/spoti.pw/releases/download/v0.50.0/spoti.pw-0.50.0-kit.zip}"
KIT_SHA="da81a22bbdb4a27a060bead23eb3ff0aa90a06e4f22cd44927f7f9bff161839f"
GLASS_SHA="d7c00c172ef6c56d937128a6059e5f703675b0d051572155e976b67c65f49a81"

IN="${1:-}"
OUT="${2:-$ROOT/out/spoti.pw-0.50.0-DistroFind.ipa}"
[ -f "$IN" ] || { echo "usage: $0 decrypted-spotify.ipa [output.ipa]" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
for tool in curl unzip shasum plutil gmake ldid cyan python3; do need "$tool"; done
mkdir -p "$ROOT/out"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> downloading official spoti.pw 0.50.0 kit"
curl -fsSL "$KIT_URL" -o "$WORK/kit.zip"
[ "$(shasum -a 256 "$WORK/kit.zip" | awk '{print $1}')" = "$KIT_SHA" ] || {
  echo "official 0.50.0 kit SHA-256 did not match" >&2
  exit 1
}
unzip -q "$WORK/kit.zip" -d "$WORK/kit"

GLASS="$WORK/kit/files/Frameworks/spotifyglass.dylib"
GROUPS="$WORK/kit/files/Frameworks/SpotifyGlassAppGroups.dylib"
[ "$(shasum -a 256 "$GLASS" | awk '{print $1}')" = "$GLASS_SHA" ] || {
  echo "spotifyglass.dylib is not the pinned official 0.50.0 build" >&2
  exit 1
}

APP_DIR="$(unzip -Z1 "$IN" | grep -oE '^Payload/[^/]+\.app/' | sort -u | head -1)"
[ -n "$APP_DIR" ] || { echo "no Payload/*.app in IPA" >&2; exit 1; }
unzip -p "$IN" "${APP_DIR}Info.plist" > "$WORK/Spotify.plist"
SPOTIFY_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$WORK/Spotify.plist")"
SPOTIFY_BUILD="$(plutil -extract CFBundleVersion raw -o - "$WORK/Spotify.plist")"
HOST_ID="$(plutil -extract CFBundleIdentifier raw -o - "$WORK/Spotify.plist")"
echo "==> spoti.pw 0.50.0 + DistroFind on Spotify $SPOTIFY_VERSION ($SPOTIFY_BUILD)"
if [ "$SPOTIFY_VERSION" != "9.1.78" ]; then
  echo "    note: official 0.50.0 targets 9.1.78; continuing with $SPOTIFY_VERSION as requested"
fi

echo "==> preparing official 0.50 Live Activity"
cp -R "$WORK/kit/files/PlugIns/SpotifyGlassLiveActivity.appex" "$WORK/SpotifyGlassLiveActivity.appex"
EXT_PLIST="$WORK/SpotifyGlassLiveActivity.appex/Info.plist"
plutil -replace CFBundleIdentifier -string "$HOST_ID.liveactivity" "$EXT_PLIST"
plutil -replace CFBundleShortVersionString -string "$SPOTIFY_VERSION" "$EXT_PLIST"
plutil -replace CFBundleVersion -string "$SPOTIFY_BUILD" "$EXT_PLIST"

echo "==> building DistroFind companion"
export THEOS
env -u MAKELEVEL gmake -C "$ROOT/distrofind" clean package
DISTRO_DEB="$(ls -t "$ROOT"/distrofind/packages/*.deb | head -1)"
[ -f "$DISTRO_DEB" ] || { echo "DistroFind package was not produced" >&2; exit 1; }

echo "==> generating official 0.50 Info.plist overlay"
python3 - "$WORK/overlay.plist" <<'PY'
import plistlib, sys
data = {
    "UIDesignRequiresCompatibility": False,
    "NSSupportsLiveActivities": True,
    "NSSupportsLiveActivitiesFrequentUpdates": True,
    "MusicHapticsSupported": True,
    "NSBonjourServices": [
        "_spotify-ln-check._tcp",
        "_spotify-connect._tcp",
        "_googlecast._tcp",
    ],
    "NSLocalNetworkUsageDescription":
        "Spotify uses your local network to find and connect to nearby devices.",
}
with open(sys.argv[1], "wb") as f:
    plistlib.dump(data, f)
PY

echo "==> injecting official 0.50.0 and DistroFind"
mkdir -p "$(dirname "$OUT")"
cyan -i "$IN" -o "$OUT"   -f "$GROUPS" "$GLASS" "$WORK/SpotifyGlassLiveActivity.appex" "$DISTRO_DEB"   -l "$WORK/overlay.plist" -w -s --overwrite

echo "==> loading App Group bridge into Spotify widget when present"
WIDGET_BIN="${APP_DIR}PlugIns/WidgetExtension.appex/WidgetExtension"
if unzip -l "$OUT" "$WIDGET_BIN" >/dev/null 2>&1; then
  PATCH="$WORK/widget"
  mkdir -p "$PATCH"
  unzip -q "$OUT" "$WIDGET_BIN" -d "$PATCH"
  "$ROOT/scripts/insert-dylib.py" "$PATCH/$WIDGET_BIN" @rpath/SpotifyGlassAppGroups.dylib
  ldid -e "$PATCH/$WIDGET_BIN" > "$PATCH/ents.plist"
  ldid -S"$PATCH/ents.plist" "$PATCH/$WIDGET_BIN"
  OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
  (cd "$PATCH" && zip -q "$OUT_ABS" "$WIDGET_BIN")
fi

echo "==> merging official 0.50 App Intents metadata"
"$ROOT/scripts/merge-appintents.py" "$OUT" "$APP_DIR" "$WORK/kit/appintents"

echo "==> complete: $OUT"
