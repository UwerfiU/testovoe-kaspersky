#!/bin/sh
NS=llm
OVERLAY=${OVERLAY:-k8s/overlays/dev}
SVC=inference
PF_PORT=18000
if [ -n "${BASE_URL+x}" ]; then USER_BASE_URL=1; else BASE_URL="http://localhost:${PF_PORT}"; fi
PF_PID=""
REQ_FILE=$(mktemp)
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; rm -f "$REQ_FILE"; }
trap cleanup EXIT
IMAGE_VLLM=vllm-cpu:0.32.0
IMAGE_DL=model-downloader:v1
WAIT_FIRST=${WAIT_FIRST:-3000}
WAIT_RESTART=${WAIT_RESTART:-900}
MODEL_API_NAME=/models/Qwen2.5-1.5B-Instruct

cd "$(dirname "$0")/.."

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }

echo "=================================================="
echo " e2e: build -> deploy -> verify"
echo " overlay=$OVERLAY base_url=$BASE_URL"
echo " env: SKIP_BUILD=1 / SKIP_APPLY=1 / WAIT_FIRST=<sec> / WAIT_RESTART=<sec>"
echo "=================================================="

echo ""
echo "=== 1/7 preflight ==="
if docker info >/dev/null 2>&1; then ok "docker daemon"; else bad "docker daemon (start Docker Desktop)"; fi
if kubectl cluster-info >/dev/null 2>&1; then ok "k8s api reachable"; else bad "k8s api reachable (create cluster in Docker Desktop)"; fi
echo "   storage classes: $(kubectl get sc --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || echo '<none>')"

echo ""
echo "=== 2/7 build images ==="
if [ "${SKIP_BUILD:-0}" = "1" ]; then
  echo "   skipped (SKIP_BUILD=1)"
else
  docker build -f docker/vllm/Dockerfile -t "$IMAGE_VLLM" . || exit 1
  docker build -f docker/downloader/Dockerfile -t "$IMAGE_DL" . || exit 1
fi

if command -v minikube >/dev/null 2>&1; then
  for P in $(minikube profile list 2>/dev/null | awk 'NR>1 && $3=="Running" {print $1}'); do
    echo "   loading images into minikube profile: $P"
    minikube -p "$P" image load "$IMAGE_VLLM" || exit 1
    minikube -p "$P" image load "$IMAGE_DL" || exit 1
  done
fi

echo ""
echo "=== 3/7 deploy ==="
if [ "${SKIP_APPLY:-0}" = "1" ]; then
  echo "   skipped (SKIP_APPLY=1)"
else
  kubectl apply -k "$OVERLAY" || exit 1
  kubectl -n "$NS" rollout status deploy/vllm --timeout="${WAIT_ROLLOUT:-420}s" || true
fi

echo ""
echo "=== 4/7 wait for pod ready (first start downloads ~3GB of weights, up to $((WAIT_FIRST/60)) min) ==="
POD=""
start=$(date +%s)
hinted=0
while :; do
  now=$(date +%s); el=$((now-start))
  [ "$el" -ge "$WAIT_FIRST" ] && break
  POD=$(kubectl -n "$NS" get pod -l app=vllm --no-headers 2>/dev/null | awk '$2=="1/1"{print $1}')
  [ -n "$POD" ] && break
  line=$(kubectl -n "$NS" get pod -l app=vllm --no-headers 2>/dev/null | head -1)
  echo "   [$el s] ${line:-<no pod>}"
  if [ "$el" -gt 300 ] && [ "$hinted" = "0" ]; then
    hinted=1
    echo "   hint: kubectl -n $NS get pvc / describe pod / logs -c download-model"
  fi
  sleep 20
done
if [ -n "$POD" ]; then ok "pod ready: $POD"; else bad "pod not ready within ${WAIT_FIRST}s"; fi

if [ -z "$POD" ]; then
  echo ""
  echo "=== ABORT: pod never became ready, diagnostics below ==="
  kubectl -n "$NS" get pods -o wide || true
  kubectl -n "$NS" get pvc || true
  kubectl -n "$NS" describe pod -l app=vllm 2>/dev/null | tail -40 || true
  exit 1
fi

echo ""
if [ "${USER_BASE_URL:-0}" = "1" ]; then
  echo "   using user BASE_URL=$BASE_URL (port-forward not started)"
else
  kubectl -n "$NS" port-forward svc/"$SVC" "${PF_PORT}:8000" >/dev/null 2>&1 &
  PF_PID=$!
  i=0
  while [ "$i" -lt 30 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$BASE_URL/health" 2>/dev/null || true)
    [ "$code" = "200" ] && break
    i=$((i+1)); sleep 2
  done
fi

echo ""
echo "=== 5/7 functional checks ==="
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/health")
if [ "$code" = "200" ]; then ok "/health -> 200"; else bad "/health -> $code"; fi

SECRET=$(kubectl -n "$NS" get secret --no-headers | awk '{print $1}' | grep '^vllm-api-key-' | head -1)
API_KEY=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' | base64 -d)

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL_API_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}")
case "$code" in
  401|403) ok "request without Bearer rejected -> $code" ;;
  *) bad "request without Bearer expected 401/403, got $code" ;;
esac

printf '%s' "{\"model\":\"$MODEL_API_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Сколько будет 2+2? Ответь только числом. Код проверки: SECRET-MARKER-123\"}],\"max_tokens\":64}" > "$REQ_FILE"
RESP=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
  -d @"$REQ_FILE")
if printf '%s' "$RESP" | grep -q '"choices"'; then ok "request with Bearer -> completion"; else bad "request with Bearer failed: $(printf '%s' "$RESP" | head -c 200)"; fi

sleep 5
LOGS=$(kubectl -n "$NS" logs "$POD" -c vllm --tail=5000 2>/dev/null || true)
n=$(printf '%s' "$LOGS" | grep -c 'SECRET-MARKER-123' || true)
if [ "${n:-0}" = "0" ]; then ok "prompt marker absent in logs"; else bad "prompt marker found in logs ($n lines) — LEAK"; fi
n=$(printf '%s' "$LOGS" | grep -c 'Received request' || true)
if [ "${n:-0}" -ge 1 ]; then ok "request fact logged ($n lines)"; else bad "no 'Received request' line in logs"; fi
n=$(printf '%s' "$LOGS" | grep -c '<redacted>' || true)
if [ "${n:-0}" -ge 1 ]; then ok "custom logging active: output redacted ($n lines)"; else bad "no '<redacted>' line — custom dictConfig not applied?"; fi

echo ""
echo "=== 6/7 security checks ==="
uid=$(kubectl -n "$NS" exec "$POD" -c vllm -- id -u 2>/dev/null | tail -1)
if [ "$uid" = "10001" ]; then ok "container runs as uid 10001 (rootless)"; else bad "container uid=$uid, expected 10001"; fi

cuda=$(kubectl -n "$NS" exec "$POD" -c vllm -- python -c 'import torch;print(torch.cuda.is_available())' 2>/dev/null | tail -1)
if [ "$cuda" = "False" ]; then ok "torch CUDA unavailable (CPU-only image)"; else bad "torch cuda check returned: $cuda"; fi

nv=$(kubectl -n "$NS" exec "$POD" -c vllm -- sh -c 'ls /opt/venv/lib/python3.12/site-packages | grep -ci nvidia' 2>/dev/null | tail -1)
if [ "${nv:-0}" = "0" ]; then ok "no nvidia packages in venv"; else bad "nvidia packages found: ${nv:-?}"; fi

echo ""
echo "=== 7/7 cache test: restart pod, expect no re-download ==="
kubectl -n "$NS" delete pod -l app=vllm --wait=false 2>/dev/null || true
NEWPOD=""
start=$(date +%s)
while :; do
  now=$(date +%s); el=$((now-start))
  [ "$el" -ge "$WAIT_RESTART" ] && break
  NEWPOD=$(kubectl -n "$NS" get pod -l app=vllm --no-headers 2>/dev/null | awk -v old="$POD" '$2=="1/1" && $1!=old{print $1}')
  [ -n "$NEWPOD" ] && break
  echo "   [$((now-start)) s] waiting for restarted pod..."
  sleep 15
done
if [ -n "$NEWPOD" ]; then ok "restarted pod ready: $NEWPOD"; else bad "restarted pod not ready within ${WAIT_RESTART}s"; fi

if [ -n "$NEWPOD" ]; then
  INITLOG=$(kubectl -n "$NS" logs "$NEWPOD" -c download-model 2>/dev/null || true)
  if printf '%s' "$INITLOG" | grep -q 'already present'; then ok "init container skipped download (PVC cache hit, no network)"; else bad "no 'already present' in init log — weights were re-downloaded?"; fi
  if [ "${USER_BASE_URL:-0}" != "1" ] && [ -n "$PF_PID" ]; then
    kill "$PF_PID" 2>/dev/null
    PF_PID=""
    kubectl -n "$NS" port-forward svc/"$SVC" "${PF_PORT}:8000" >/dev/null 2>&1 &
    PF_PID=$!
  fi
  code=""
  i=0
  while [ "$i" -lt 30 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$BASE_URL/health" 2>/dev/null || true)
    [ "$code" = "200" ] && break
    i=$((i+1)); sleep 2
  done
  if [ "$code" = "200" ]; then ok "/health after restart -> 200"; else bad "/health after restart -> ${code:-000}"; fi
fi

echo ""
echo "=================================================="
echo " SUMMARY: PASS=$PASS FAIL=$FAIL"
echo "=================================================="
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "=== diagnostics ==="
  kubectl -n "$NS" get pods -o wide || true
  kubectl -n "$NS" get pvc || true
  kubectl -n "$NS" describe pod -l app=vllm 2>/dev/null | tail -40 || true
  echo ""
  echo "useful: kubectl -n $NS logs <pod> -c download-model / -c vllm"
  exit 1
fi
echo "ALL CHECKS PASSED"
