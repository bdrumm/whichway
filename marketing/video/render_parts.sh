#!/usr/bin/env bash
# Render a film in N parallel frame ranges and join them: ./render_parts.sh minutes.html out_silent.mp4 [N]
set -euo pipefail
film=$1 out=$2 n=${3:-4}
here=$(cd "$(dirname "$0")" && pwd)
dur=$(grep -oP 'const DURATION = \K[0-9.]+' "$here/$film")
frames=$(python3 -c "print(round($dur * 30))")
work=$(mktemp -d)
for k in $(seq 0 $((n - 1))); do
  FILM=$film node "$here/render.mjs" "$work/p$k.mp4" 30 $((frames * k / n)) $((frames * (k + 1) / n)) > /dev/null &
done
wait
for k in $(seq 0 $((n - 1))); do echo "file '$work/p$k.mp4'"; done > "$work/list.txt"
ffmpeg -loglevel error -y -f concat -safe 0 -i "$work/list.txt" -c copy "$out"
rm -rf "$work"
