#!/bin/sh
# Генерация lock-файлов (pinned dependencies + sha256) ВНУТРИ контейнера.
# Контейнер берётся на той же базе, что и финальные образы => разрешение зависимостей
# идентично среде выполнения (glibc/платформа), флаги --python-platform не нужны.
#
# Запуск из корня репозитория:  sh scripts/make-locks.sh
set -eu

VLLM_VERSION=0.32.0
UV_VERSION=0.13.7
BASE_IMAGE=python:3.12-slim-trixie          # glibc 2.41 >= manylinux_2_39 у vllm+cpu wheel
CPU_WHEEL_SHA=e87a047cc5ab47eb14565dfcd060393876b33e913479982a56fca6fca73ed97a
UPSTREAM=https://raw.githubusercontent.com/vllm-project/vllm/v${VLLM_VERSION}
WHEEL=https://github.com/vllm-project/vllm/releases/download/v${VLLM_VERSION}/vllm-${VLLM_VERSION}+cpu-cp38-abi3-manylinux_2_39_x86_64.whl#sha256=${CPU_WHEEL_SHA}

cd "$(dirname "$0")/.."
SRC="$(pwd -W 2>/dev/null || pwd)"          # Git Bash -> D:/..., иначе docker не поймёт /d/...

run_uv() {
  MSYS_NO_PATHCONV=1 docker run --rm \
    -v "${SRC}:/w" -w //w \
    --mount type=volume,source=testovoe-uv-cache,target=/root/.cache/uv \
    "${BASE_IMAGE}" sh -c "pip install --no-cache-dir --quiet --root-user-action=ignore uv==${UV_VERSION} && $1"
}

echo "==> 1/4 входные файлы (upstream requirements + pin на CPU-wheel)"
# upstream cpu.txt содержит "-r common.txt", поэтому качем оба файла и сохраняем
# относительную структуру каталогов: uv разрешает include относительно файла, в котором он написан
mkdir -p "locks/upstream/v${VLLM_VERSION}"
curl -fsSL "${UPSTREAM}/requirements/cpu.txt"    -o "locks/upstream/v${VLLM_VERSION}/cpu.txt"
curl -fsSL "${UPSTREAM}/requirements/common.txt" -o "locks/upstream/v${VLLM_VERSION}/common.txt"
cat > locks/vllm-cpu.in <<EOF
-r upstream/v${VLLM_VERSION}/cpu.txt
vllm @ ${WHEEL}
EOF

echo "==> 2/4 лок образа vLLM"
run_uv "uv pip compile locks/vllm-cpu.in -o locks/vllm-cpu-py312-linux_x86_64.txt \
          --python-version 3.12 --generate-hashes \
          --index-strategy unsafe-best-match \
          --extra-index-url https://download.pytorch.org/whl/cpu"

echo "==> 3/4 лок образа downloader (initContainer)"
# в huggingface_hub 2.x экстры hf-transfer больше нет (ускорение встроено / отдельный пакет hf-xet)
cat > locks/downloader.in <<'EOF'
huggingface_hub
# hf-xet          # опционально: ускоренная доставка через Xet
EOF
run_uv "uv pip compile locks/downloader.in -o locks/downloader-py312.txt \
          --python-version 3.12 --generate-hashes"

echo "==> 4/4 самопроверка"
for f in locks/vllm-cpu-py312-linux_x86_64.txt locks/downloader-py312.txt; do
  lines=$(wc -l < "$f")
  hashes=$(grep -c -- '--hash=' "$f")
  nvidia=$(grep -ci nvidia "$f" || true)
  echo "    ${f}: строк=${lines} хэшей=${hashes} упоминаний_nvidia=${nvidia}"
  [ "${hashes}" -gt 0 ] || { echo "    ОШИБКА: нет хэшей — --require-hashes не сработает"; exit 1; }
done
grep -E '^(torch|intel-openmp) ' locks/vllm-cpu-py312-linux_x86_64.txt | sed 's/^/    /'
echo "OK: лок-файлы готовы. Закоммитьте locks/*.in и locks/*.txt"
