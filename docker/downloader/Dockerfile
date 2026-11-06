# syntax=docker/dockerfile:1

FROM python:3.12-slim-trixie

ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH \
    UV_LINK_MODE=copy \
    UV_PYTHON_PREFERENCE=only-system

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY locks/downloader-py312.txt /tmp/locks.txt

RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv "$VIRTUAL_ENV" --python 3.12 && \
    uv pip install --require-hashes -r /tmp/locks.txt && \
    command -v hf >/dev/null || { echo "no 'hf' CLI in image"; exit 1; }

RUN useradd -r -u 10001 -m -d /home/dl dl \
    && install -d -o 10001 -g 10001 /models /home/dl/.cache /tmp/dl

COPY --chmod=0755 docker/downloader/download.sh /usr/local/bin/download.sh

ENV HF_HOME=/models \
    XDG_CACHE_HOME=/home/dl/.cache \
    TMPDIR=/tmp/dl

USER 10001:10001
WORKDIR /home/dl

LABEL org.opencontainers.image.title="model-downloader" \
    org.opencontainers.image.description="initContainer: idempotent HF weights fetch to PVC"

   ENTRYPOINT ["/usr/local/bin/download.sh"]