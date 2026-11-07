# syntax=docker/dockerfile:1

FROM python:3.12-slim-trixie AS builder

ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PATH=/opt/venv/bin:$PATH \
    VIRTUAL_ENV=/opt/venv \
    UV_LINK_MODE=copy \
    UV_PYTHON_PREFERENCE=only-system

RUN pip install "uv==0.13.7"

COPY locks/vllm-cpu-py312-linux_x86_64.txt /tmp/locks.txt

RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv "$VIRTUAL_ENV" --python 3.12 && \
    uv pip install --require-hashes -r /tmp/locks.txt \
        --extra-index-url https://download.pytorch.org/whl/cpu \
        --index-strategy unsafe-best-match

FROM python:3.12-slim-trixie AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends libnuma1 curl ca-certificates gcc g++ \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv

COPY custom_logging /opt/custom_logging

RUN set -eux; \
    L="$(find /opt/venv -name 'libiomp5.so*' | head -1)"; test -n "$L"; \
    ln -sf "$L" /usr/local/lib/libiomp5.so; ldconfig

RUN useradd -r -u 10001 -m -d /home/vllm vllm \
    && install -d -o 10001 -g 10001 /models /tmp/vllm /home/vllm/.cache

COPY --chmod=0755 docker/vllm/entrypoint.sh /usr/local/bin/entrypoint.sh

USER 10001:10001
WORKDIR /home/vllm

ENV PATH=/opt/venv/bin:$PATH \
    HOME=/home/vllm \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/models \
    XDG_CACHE_HOME=/home/vllm/.cache \
    TRITON_CACHE_DIR=/models/.triton-cache \
    TMPDIR=/tmp/vllm \
    LD_PRELOAD=libiomp5.so \
    PYTHONPATH=/opt \
    LOGGING_CONFIG_FILE=/etc/vllm/logging.json \
    VLLM_LOGGING_LEVEL=INFO \
    VLLM_DEBUG_LOG_API_SERVER_RESPONSE=0

EXPOSE 8000

LABEL org.opencontainers.image.title="vllm-cpu" \
      org.opencontainers.image.version="0.32.0+cpu"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
