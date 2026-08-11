#!/usr/bin/env bash
# Turn the frames from record-demo.mjs into a GIF + MP4 — but only after proving no
# frame contains anything private. The artifact is meant to be published, so the check
# is on what was actually FILMED (scenes.json holds each scene's visible text), not on
# the intent to mask.
set -euo pipefail

OUT="${DEMO_OUT:-/tmp/launchddash-demo}"
FRAMES="$OUT/frames"
DEST="${1:-$HOME/launchd-dashboard/docs}"
[ -d "$FRAMES" ] || { echo "no frames at $FRAMES — run record-demo.mjs first"; exit 1; }

# ---- privacy gate ---------------------------------------------------------
# Anything here in the captured text means the GIF would leak it. Fail, don't warn.
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
HOSTNAME_LOCAL="$(scutil --get LocalHostName 2>/dev/null || true)"
python3 - "$OUT/scenes.json" "$HOME" "$LAN_IP" "$HOSTNAME_LOCAL" <<'PY'
import json, re, sys
scenes_path, home, lan_ip, host = sys.argv[1:5]
scenes = json.load(open(scenes_path))
bad = []
# Private-range literals: the masked output uses 192.0.2.x / 2001:db8:: only.
private = re.compile(r"\b(?:192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3}"
                     r"|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b")
needles = [n for n in (home, lan_ip, host) if n]
for i, s in enumerate(scenes):
    text = s["text"]
    for n in needles:
        if n in text:
            bad.append(f"scene {i} ({s['caption'][:40]}…) contains {n!r}")
    for m in set(private.findall(text)):
        bad.append(f"scene {i} ({s['caption'][:40]}…) contains private IP {m}")
if bad:
    print("PRIVACY GATE FAILED — not assembling:", *bad, sep="\n  ")
    sys.exit(1)
print(f"privacy gate passed over {len(scenes)} scenes "
      f"(checked: home path, LAN IP, hostname, RFC1918 literals)")
PY

# ---- assemble -------------------------------------------------------------
mkdir -p "$DEST"
# palettegen/paletteuse: a generic 256-colour quantiser smears small UI text.
ffmpeg -y -loglevel error -framerate 10 -pattern_type glob -i "$FRAMES/f*.png" \
  -vf "fps=10,scale=1000:-1:flags=lanczos,palettegen=stats_mode=diff" "$OUT/palette.png"
ffmpeg -y -loglevel error -framerate 10 -pattern_type glob -i "$FRAMES/f*.png" -i "$OUT/palette.png" \
  -lavfi "fps=10,scale=1000:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 "$DEST/demo.gif"

# MP4 too: GitHub/LinkedIn prefer video and it's a fraction of the size.
ffmpeg -y -loglevel error -framerate 10 -pattern_type glob -i "$FRAMES/f*.png" \
  -vf "fps=15,scale=1280:-2:flags=lanczos,format=yuv420p" \
  -c:v libx264 -preset slow -crf 23 -movflags +faststart "$DEST/demo.mp4"

printf 'GIF  %s  (%s)\n' "$DEST/demo.gif" "$(du -h "$DEST/demo.gif" | cut -f1)"
printf 'MP4  %s  (%s)\n' "$DEST/demo.mp4" "$(du -h "$DEST/demo.mp4" | cut -f1)"
