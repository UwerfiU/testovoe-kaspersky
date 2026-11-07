#!/bin/sh
set -eu

: "${MODEL_PATH:?MODEL_PATH is not set; provide it via env (k8s ConfigMap)}"

LOG_ARGS=""
if [ -n "${LOGGING_CONFIG_FILE:-}" ] && [ -f "$LOGGING_CONFIG_FILE" ]; then
    LOG_ARGS="--logging-config.pylogging_config_file $LOGGING_CONFIG_FILE"
fi

API_ARGS=""
if [ -n "${VLLM_API_KEY:-}" ]; then
    API_ARGS="--api-key $VLLM_API_KEY"
fi

exec vllm serve --model "$MODEL_PATH" \
    --host 0.0.0.0 --port "${PORT:-8000}" \
    --dtype "${DTYPE:-bfloat16}" \
    --gpu-memory-utilization "${MEM_UTIL:-0.85}" \
    --max-model-len "${MAX_MODEL_LEN:-4096}" \
    --max-num-seqs "${MAX_NUM_SEQS:-64}" \
    --compilation-config '{"mode": 0}' \
    --enable-log-requests --enable-log-outputs --log-level INFO --max-log-len "${MAX_LOG_LEN:-0}" \
    --disable-access-log-for-endpoints /health,/metrics,/load \
    $LOG_ARGS \
    $API_ARGS \
    ${VLLM_EXTRA_ARGS:-}
