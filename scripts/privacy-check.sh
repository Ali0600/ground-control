#!/usr/bin/env bash
# The half of the privacy gate that only THIS machine can run.
#
# tests/test_privacy.py runs in CI, where nothing is known about the author, so it can
# only check structure: an unrecognised /Users/<name>, a .local device name, a private
# address outside a closed fixture allowlist. That misses anything shaped like ordinary
# text — a person's name, an employer, a hostname that does not end in .local.
#
# This script derives the needles at RUN TIME from the machine itself and never writes
# them anywhere. Committing them so CI could check them would be the leak.
#
# Same idea as assemble-demo.sh's gate, pointed at the source instead of the GIF frames:
# that one has guarded published frames since the demo shipped, while the repo's own
# tests carried a phone named after the author, their subnet and their router's model.
#
#   ./scripts/privacy-check.sh          # scan tracked files, exit 1 on a hit
set -euo pipefail
cd "$(dirname "$0")/.."

needles=()
# Always returns 0. Under `set -e` a bare `add ""` (en1 has no address on most Macs)
# would otherwise abort the script — and it exited 1 with NO output, which reads exactly
# like a clean failure. A check whose "failure" is indistinguishable from a silent crash
# is worse than no check.
add() {
  if [ -n "${1:-}" ] && [ ${#1} -ge 3 ]; then
    needles+=("$1")
  fi
  return 0
}

add "$HOME"
add "$(basename "$HOME")"
add "$(ipconfig getifaddr en0 2>/dev/null || true)"
add "$(ipconfig getifaddr en1 2>/dev/null || true)"
add "$(scutil --get LocalHostName 2>/dev/null || true)"
add "$(scutil --get ComputerName 2>/dev/null || true)"
# The author's own name, as git already knows it.
add "$(git config user.name 2>/dev/null || true)"
add "$(git config user.email 2>/dev/null || true)"
# The LAN prefix, so a sibling address on the same subnet is caught too.
lan="$(ipconfig getifaddr en0 2>/dev/null || true)"
[ -n "$lan" ] && add "${lan%.*}."

if [ "${#needles[@]:-0}" -eq 0 ]; then
  echo "privacy-check: could not derive a single needle — refusing to report a pass"
  exit 1
fi

echo "privacy-check: scanning tracked files for ${#needles[@]} machine-derived values"
echo "privacy-check: (values are derived at run time and never printed)"

hits=0
while IFS= read -r -d '' file; do
  # Skip binaries: the demo GIF/MP4 are the assemble-demo gate's job.
  grep -Iq . "$file" 2>/dev/null || continue
  for needle in "${needles[@]}"; do
    # -F: the needles are literals (an email has a dot, a name may have punctuation).
    if grep -nF -- "$needle" "$file" >/dev/null 2>&1; then
      echo "  LEAK  $file contains a machine-derived value"
      grep -nF -- "$needle" "$file" | head -3 | sed 's/^/        /'
      hits=$((hits + 1))
    fi
  done
done < <(git ls-files -z)

if [ "$hits" -gt 0 ]; then
  echo
  echo "privacy-check FAILED: $hits file/needle hits above."
  echo "This repo is public. Replace the value with a fixture placeholder"
  echo "(see ALLOWED_USERS / ALLOWED_PRIVATE_IPS in tests/test_privacy.py)."
  exit 1
fi

echo "privacy-check passed — no machine-derived value appears in a tracked file"
