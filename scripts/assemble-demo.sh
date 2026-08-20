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

# ---- concat list ----------------------------------------------------------
# Each scene is ONE frame held for as long as its caption takes to read, rather than
# the same screenshot repeated at a fixed frame rate. That is what makes the captions
# legible; it also drops ~90% of the frames, since they were duplicates.
LIST="$OUT/concat.txt"
python3 - "$OUT/manifest.json" "$FRAMES" "$LIST" <<'PY'
import json, sys
manifest_path, frames, list_path = sys.argv[1:4]
m = json.load(open(manifest_path))
lines = []
for entry in m:
    lines.append(f"file '{frames}/{entry['file']}'")
    lines.append(f"duration {entry['hold']}")
# concat gives the FINAL entry no duration unless the file is repeated — without this
# the last scene flashes past in a single frame time.
lines.append(f"file '{frames}/{m[-1]['file']}'")
open(list_path, "w").write("\n".join(lines) + "\n")
total = sum(e["hold"] for e in m)
print(f"{len(m)} frames, {total:.1f}s: " + " · ".join(f"{e['hold']}s" for e in m))
PY

# ---- assemble -------------------------------------------------------------
mkdir -p "$DEST"
# NOTE: no `fps=` filter anywhere below. An fps filter resamples to a constant rate,
# which would re-expand every held frame back into duplicates and undo the pacing.
# palettegen/paletteuse: a generic 256-colour quantiser smears small UI text.
ffmpeg -y -loglevel error -f concat -safe 0 -i "$LIST" \
  -vf "scale=1000:-1:flags=lanczos,palettegen=stats_mode=diff" "$OUT/palette.png"
ffmpeg -y -loglevel error -f concat -safe 0 -i "$LIST" -i "$OUT/palette.png" \
  -lavfi "scale=1000:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 "$OUT/demo.gif"

# MP4 too: GitHub/LinkedIn prefer video and it's a fraction of the size. Here a constant
# rate IS wanted (players dislike wildly variable timestamps) — h264 encodes the held
# frames as near-empty P-frames, so it costs almost nothing.
ffmpeg -y -loglevel error -f concat -safe 0 -i "$LIST" \
  -vf "fps=15,scale=1280:-2:flags=lanczos,format=yuv420p" \
  -c:v libx264 -preset slow -crf 23 -movflags +faststart "$OUT/demo.mp4"

# ---- verify the ARTIFACT, not the intent ----------------------------------
# Read the delays back out of the finished GIF. Re-introducing an `fps=` filter above
# would silently flatten every hold to a uniform frame time and put the captions back
# out of reach — the exact regression this pacing work exists to fix.
python3 - "$OUT/demo.gif" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
delays, i = [], 13
if d[10] & 0x80: i += 3 * (2 ** ((d[10] & 7) + 1))
while i < len(d):
    b = d[i]
    if b == 0x21 and d[i+1] == 0xF9:
        delays.append(int.from_bytes(d[i+4:i+6], "little") / 100); i += 8
    elif b == 0x21:
        i += 2
        while d[i]: i += d[i] + 1
        i += 1
    elif b == 0x2C:
        i += 10
        if d[i-1] & 0x80: i += 3 * (2 ** ((d[i-1] & 7) + 1))
        i += 1
        while d[i]: i += d[i] + 1
        i += 1
    else:
        break
# The concat demuxer emits one extra ~0.04s frame (the repeated final entry); drop it.
# The cutoff must sit BELOW a flattened 0.1s frame, or a uniform 10fps GIF filters down
# to an empty list and the failure has nothing to report.
real = [x for x in delays if x > 0.05]
if len(real) < 2 or len(set(real)) == 1:
    print(f"PACING CHECK FAILED: {len(real)} frames, delays {sorted(set(real))} — an fps "
          "filter flattened the holds, so the captions are unreadable again."); sys.exit(1)
if min(real) < 1.4:
    print(f"PACING CHECK FAILED: a frame is held only {min(real)}s"); sys.exit(1)
print(f"pacing ok: {len(real)} scenes held {min(real)}–{max(real)}s")
PY

# Only now are they fit to publish.
mv "$OUT/demo.gif" "$DEST/demo.gif"
mv "$OUT/demo.mp4" "$DEST/demo.mp4"

printf 'GIF  %s  (%s, %ss)\n' "$DEST/demo.gif" "$(du -h "$DEST/demo.gif" | cut -f1)" \
  "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$DEST/demo.gif" | cut -d. -f1)"
printf 'MP4  %s  (%s)\n' "$DEST/demo.mp4" "$(du -h "$DEST/demo.mp4" | cut -f1)"
