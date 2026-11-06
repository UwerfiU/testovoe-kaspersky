#!/bin/sh
set -eu

: "${MODEL_PATH:?MODEL_PATH is not set; provide it via env (k8s ConfigMap)}"

LOG_ARGS=""
if [ -n "${LOGGING_CONFIG_FILE:-}" ] && [ -f "$LOGGING_CONFIG_FILE" ]; then
    LOG_ARGS="--logging-config.pylogging_config_file $LOGGING_CONFIG_FILE"
fi

exec vllm "$MODEL_PATH" "$@" \
    --host 0.0.0.0 --port "${PORT:-8000}" \
    --dtype "${DTYPE:-bfloat16}" \
    --max-model-len "${MAX_MODEL_LEN:-4096}" \
    --max-num-seqs "${MAX_NUM_SEQS:-64}" \
    --enable-log-requests --log-level INFO --max-log-len "${MAX_LOG_LEN:-0}" \
    --disable-access-log-for-endpoints /health,/metrics,/load \
    $LOG_ARGS \
    ${VLLM_EXTRA_ARGS:-}
