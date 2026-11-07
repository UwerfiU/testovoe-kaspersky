#!/bin/sh
NS=llm
IMAGE_VLLM=vllm-cpu:0.32.0
SVC=inference
NODEPORT_URL=http://localhost:30000
PF_PORT=18000
PROFILE=${PROFILE:-mixed}

cd "$(dirname "$0")/.."

case "$PROFILE" in
  short|mixed|long|all) ;;
  *) echo "ERROR: unknown PROFILE=$PROFILE (use short|mixed|long|all)"; exit 1 ;;
esac

CM=$(kubectl -n "$NS" get cm --no-headers 2>/dev/null | awk '{print $1}' | grep '^vllm-config-' | head -1)
SECRET=$(kubectl -n "$NS" get secret --no-headers 2>/dev/null | awk '{print $1}' | grep '^vllm-api-key-' | head -1)
MODEL_NAME=$(kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.MODEL_NAME}')
HF_REPO=$(kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.HF_REPO}')
API_KEY=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' | base64 -d)

if [ -z "$MODEL_NAME" ] || [ -z "$HF_REPO" ] || [ -z "$API_KEY" ]; then
  echo "ERROR: cannot read vllm-config ConfigMap or vllm-api-key Secret from namespace $NS"
  exit 1
fi

POD=$(kubectl -n "$NS" get pod -l app=vllm --no-headers 2>/dev/null | awk '$2=="1/1"{print $1}')
if [ -z "$POD" ]; then
  echo "ERROR: no ready vllm pod in namespace $NS (run scripts/deploy-and-verify.sh first)"
  exit 1
fi

PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; }
trap cleanup EXIT

TARGET_URL="$NODEPORT_URL"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$NODEPORT_URL/health" 2>/dev/null || true)
if [ "$code" = "200" ]; then
  echo "external entry: NodePort $NODEPORT_URL"
else
  echo "NodePort not reachable from host, falling back to port-forward on :$PF_PORT"
  kubectl -n "$NS" port-forward svc/"$SVC" "${PF_PORT}:8000" >/dev/null 2>&1 &
  PF_PID=$!
  i=0
  while [ "$i" -lt 30 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:${PF_PORT}/health" 2>/dev/null || true)
    [ "$code" = "200" ] && break
    i=$((i+1)); sleep 2
  done
  TARGET_URL="http://localhost:${PF_PORT}"
fi

HOST_TARGET=$(printf '%s' "$TARGET_URL" | sed 's#//localhost:#//host.docker.internal:#')

set_profile() {
  case "$1" in
    short) NUM_PROMPTS=${NUM_PROMPTS:-32}; REQUEST_RATE=${REQUEST_RATE:-4};   INPUT_LEN=32;   OUTPUT_LEN=32;  RANGE_RATIO=0 ;;
    mixed) NUM_PROMPTS=${NUM_PROMPTS:-32}; REQUEST_RATE=${REQUEST_RATE:-2};   INPUT_LEN=1536; OUTPUT_LEN=256; RANGE_RATIO=0.9 ;;
    long)  NUM_PROMPTS=${NUM_PROMPTS:-8};  REQUEST_RATE=${REQUEST_RATE:-0.5}; INPUT_LEN=3072; OUTPUT_LEN=512; RANGE_RATIO=0 ;;
  esac
}

run_profile() {
  P="$1"
  set_profile "$P"
  echo ""
  echo "=================================================="
  echo " PROFILE: $P"
  echo " client OUTSIDE the cluster -> $TARGET_URL"
  echo " prompts=$NUM_PROMPTS rate=${REQUEST_RATE}/s in=$INPUT_LEN out=$OUTPUT_LEN range_ratio=$RANGE_RATIO"
  echo "=================================================="
  MSYS_NO_PATHCONV=1 docker run --rm \
    -e OPENAI_API_KEY="$API_KEY" \
    --entrypoint vllm \
    "$IMAGE_VLLM" bench serve \
      --backend openai-chat \
      --base-url "$HOST_TARGET" \
      --endpoint /v1/chat/completions \
      --model "$HF_REPO" \
      --served-model-name "/models/$MODEL_NAME" \
      --dataset-name random \
      --random-input-len "$INPUT_LEN" \
      --random-output-len "$OUTPUT_LEN" \
      --random-range-ratio "$RANGE_RATIO" \
      --num-prompts "$NUM_PROMPTS" \
      --request-rate "$REQUEST_RATE"
}

if [ "$PROFILE" = "all" ]; then
  for P in short mixed long; do
    run_profile "$P"
  done
else
  run_profile "$PROFILE"
fi
