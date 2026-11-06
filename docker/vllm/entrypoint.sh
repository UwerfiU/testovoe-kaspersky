#!/bin/sh

set -eu

exec vllm "$MODEL_PATH" "$@" \
    --host 0.0.0.0 --port "${PORT:-8000}" \
    --dtype "${DTYPE:-bfloat16}" \
    --max-model-len "${MAX_MODEL_LEN:-4096}" \
    --max-num-seqs "${MAX_NUM_SEQS:-64}" \
    --enable-log-requests --log-level INFO --max-log-len "${MAX_LOG_LEN:-0}" \
    --disable-access-log-for-endpoints /health,/metrics,/load \
    ${VLLM_EXTRA_ARGS:-}