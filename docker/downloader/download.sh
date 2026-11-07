#!/bin/sh
set -eux
DST="${1:?usage: download.sh <dst> <repo> [revision]}"
REPO="${2:?}"; REV="${3:-}"
MARKER="$DST/.download-complete"
WANT=$(printf 'repo=%s\nrevision=%s\n' "$REPO" "$REV")

if [ -f "$MARKER" ] && [ -f "$DST/config.json" ] && [ "$(cat "$MARKER")" = "$WANT" ]; then
    echo "[downloader] already present: $DST (skip, no network)"; exit 0
fi

set -- hf download "$REPO" --local-dir "$DST" \
    --include "*.safetensors" --include "*.json" --include "*.model" \
    --include "tokenizer*" --include "*.txt" --include "*.tiktoken" \
    --exclude "*.pth" --exclude "orig/*" --max-workers 4
[ -n "$REV" ] && set -- "$@" --revision "$REV"
"$@"
printf 'repo=%s\nrevision=%s\n' "$REPO" "$REV" > "$MARKER"
echo "[downloader] done: $DST"
