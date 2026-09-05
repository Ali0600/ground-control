#!/usr/bin/env bash
# Dev launcher: create the venv on first run, then serve the dashboard on localhost.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d .venv ]; then
  echo "Creating venv + installing deps…"
  python3 -m venv .venv
  ./.venv/bin/pip install -q --upgrade pip
  ./.venv/bin/pip install -q -r requirements.txt
fi

PORT="${PORT:-8787}"
echo "Ground Control → http://127.0.0.1:${PORT}"
# "$@" comes BEFORE the bind: uvicorn takes the last --host wins, so with the
# passthrough last, `./run.sh --host 0.0.0.0` would silently expose a dashboard whose
# whole security model is "loopback only". Extra args still work for everything else.
exec ./.venv/bin/uvicorn app.main:app "$@" --host 127.0.0.1 --port "${PORT}"
