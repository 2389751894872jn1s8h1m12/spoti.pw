#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
KIT_URL="${KIT_URL:-https://github.com/skopevoj/spoti.pw/releases/download/v0.50.0/spoti.pw-0.50.0-kit.zip}"

IN="" OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -h|--help)
      echo "usage: $0 <decrypted Spotify IPA> [-o output.ipa]"
      exit 0
      ;;
    *) IN="$1"; shift ;;
  esac
done

[ -n "$IN" ] || { echo "missing input IPA" >&2; exit 1; }
[ -f "$IN" ] || { echo "no such IPA: $IN" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
for c in gmake cyan curl unzip zip python3 plutil ldid; do need "$c"; done

mkdir -p "$ROOT/out"
APP_DIR="$(unzip -Z1 "$IN" | grep -oE '^Payload/[^/]+\.app/' | sort -u | head -1)"
[ -n "$APP_DIR" ] || { echo "no Payload/*.app in $IN" >&2; exit 1; }

INFO="$ROOT/out/.spotify-info.plist"
unzip -p "$IN" "${APP_DIR}Info.plist" > "$INFO"
SPOTIFY_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO")"
HOST_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO")"
HOST_SHORT_VERSION="$SPOTIFY_VERSION"
HOST_VERSION="$(plutil -extract CFBundleVersion raw -o - "$INFO")"
OUT="${OUT:-$ROOT/out/spoti.pw-0.50.0-distrofind-Spotify-$SPOTIFY_VERSION.ipa}"

echo "==> Spotify $SPOTIFY_VERSION"
echo "==> official spoti.pw 0.50.0 kit + DistroFind"

KIT_ZIP="$ROOT/out/spoti.pw-0.50.0-kit.zip"
KIT_DIR="$ROOT/out/spoti.pw-0.50.0-kit"
if [ ! -f "$KIT_ZIP" ]; then
  echo "==> downloading official 0.50.0 kit"
  curl -fL "$KIT_URL" -o "$KIT_ZIP"
fi
rm -rf "$KIT_DIR"
mkdir -p "$KIT_DIR"
unzip -q "$KIT_ZIP" -d "$KIT_DIR"

python3 - "$KIT_DIR" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
kit = json.loads((root / "kit.json").read_text())
if kit.get("version") != "0.50.0":
    raise SystemExit(f"wrong kit version: {kit.get('version')}")
for rel, wanted in kit.get("integrity", {}).items():
    p = root / rel
    got = hashlib.sha256(p.read_bytes()).hexdigest()
    if got != wanted:
        raise SystemExit(f"kit integrity failed for {rel}")
print("    kit integrity OK")
PY

echo "==> preparing official 0.50 Info.plist merge"
MERGE_PLIST="$ROOT/out/.v050-merge.plist"
python3 - "$INFO" "$KIT_DIR/kit.json" "$MERGE_PLIST" <<'PY'
import json, plistlib, sys
info_path, kit_path, out_path = sys.argv[1:4]
with open(info_path, "rb") as f:
    host = plistlib.load(f)
with open(kit_path, "r", encoding="utf-8") as f:
    rules = json.load(f).get("infoPlist", {})
patch = dict(rules.get("set", {}))
for key, values in rules.get("union", {}).items():
    merged = list(host.get(key, [])) if isinstance(host.get(key), list) else []
    for value in values:
        if value not in merged:
            merged.append(value)
    patch[key] = merged
for key, value in rules.get("default", {}).items():
    patch[key] = host.get(key, value)
with open(out_path, "wb") as f:
    plistlib.dump(patch, f, fmt=plistlib.FMT_XML, sort_keys=True)
PY

echo "==> preparing Live Activity extension"
EXT_DIR="$ROOT/out/v050-extension"
rm -rf "$EXT_DIR"
mkdir -p "$EXT_DIR"
cp -R "$KIT_DIR/files/PlugIns/SpotifyGlassLiveActivity.appex" "$EXT_DIR/"
rm -rf "$EXT_DIR/SpotifyGlassLiveActivity.appex/_CodeSignature"
python3 - "$EXT_DIR/SpotifyGlassLiveActivity.appex/Info.plist" "$HOST_BUNDLE_ID" "$HOST_SHORT_VERSION" "$HOST_VERSION" <<'PY'
import plistlib, sys
path, bundle, short, build = sys.argv[1:5]
with open(path, "rb") as f:
    p = plistlib.load(f)
p["CFBundleIdentifier"] = f"{bundle}.liveactivity"
p["CFBundleShortVersionString"] = short
p["CFBundleVersion"] = build
with open(path, "wb") as f:
    plistlib.dump(p, f, fmt=plistlib.FMT_XML)
PY

echo "==> building DistroFind companion"
export THEOS
env -u MAKELEVEL gmake -C "$ROOT/distrofind" clean package
DF_DEB="$(ls -t "$ROOT"/distrofind/packages/*.deb | head -1)"
echo "    $DF_DEB"

SPOTIGLASS="$KIT_DIR/files/Frameworks/spotifyglass.dylib"
APPGROUPS="$KIT_DIR/files/Frameworks/SpotifyGlassAppGroups.dylib"
LIVE="$EXT_DIR/SpotifyGlassLiveActivity.appex"

echo "==> injecting official 0.50.0 + DistroFind"
cyan -i "$IN" -o "$OUT" \
  -f "$SPOTIGLASS" "$APPGROUPS" "$DF_DEB" "$LIVE" \
  -l "$MERGE_PLIST" \
  -w -s --overwrite

echo "==> loading App Groups shim in Spotify widget"
WIDGET_BIN="${APP_DIR}PlugIns/WidgetExtension.appex/WidgetExtension"
if unzip -Z1 "$OUT" | grep -qx "$WIDGET_BIN"; then
  PATCH="$(mktemp -d)"
  unzip -q "$OUT" "$WIDGET_BIN" -d "$PATCH"
  "$ROOT/scripts/insert-dylib.py" "$PATCH/$WIDGET_BIN" @rpath/SpotifyGlassAppGroups.dylib
  ldid -e "$PATCH/$WIDGET_BIN" > "$PATCH/ents.plist"
  ldid -S"$PATCH/ents.plist" "$PATCH/$WIDGET_BIN"
  OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
  (cd "$PATCH" && zip -q "$OUT_ABS" "$WIDGET_BIN")
  rm -rf "$PATCH"
fi

echo "==> merging official 0.50.0 App Intents"
"$ROOT/scripts/merge-appintents.py" "$OUT" "$APP_DIR" "$KIT_DIR/appintents"

rm -f "$INFO" "$MERGE_PLIST"
echo "==> done: $OUT"
