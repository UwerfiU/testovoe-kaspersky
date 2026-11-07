# vLLM CPU-инференс в Kubernetes

Инференс `Qwen2.5-1.5B-Instruct` на **vLLM 0.32.0, строго CPU**, в кластере Kubernetes (Docker Desktop K8s / Minikube): rootless-образы, закреплённые зависимости, кастомное логирование без промптов и ответов, кэш весов на PVC через `initContainer`, секреты и конфигурация через `ConfigMap`, деплой через kustomize.

## Соответствие ТЗ

| Требование | Реализация | Проверка |
|---|---|---|
| Полноценный k8s / Minikube | Манифесты через kustomize: `k8s/base` + оверлеи `dev`/`prod` | `kubectl kustomize k8s/overlays/dev` |
| Модель instruct, CPU-only | `Qwen/Qwen2.5-1.5B-Instruct`, vLLM CPU-wheel, ноль nvidia-пакетов | e2e: `torch.cuda.is_available() == False`, `ls site-packages | grep -i nvidia` → 0 |
| vLLM ≥ 0.27.0 | **vLLM 0.32.0** (официальный CPU-wheel, SHA256 закреплён) | `locks/vllm-cpu-py312-linux_x86_64.txt` |
| Rootless-образ | Оба образа работают от **uid 10001**, без privilege escalation, `drop: ALL`, seccomp | e2e: `id -u` → 10001 |
| Pinned dependencies | uv-локи с хэшами (`--require-hashes`), wheel vLLM с SHA256, все вторичные зависимости зафиксированы | `locks/` |
| Логи без промптов и ответов, факт обращения — логируется | Кастомные фильтры + `dictConfig` (см. «Логирование») | e2e: маркер в запросе отсутствует в логах, `Received request` и `<redacted>` присутствуют; `scripts/test_redact_filter.py` — 9/9 |
| PVC и кэш весов | initContainer качает веса в PVC; при рестарте — «already present», без сети | e2e: рестарта пода без перекачки |
| Secrets | HF-токен и Bearer-ключ в k8s `Secret` | `k8s/base/` (Secret'ы создаются скриптом) |
| Конфигурация через ConfigMap | Параметры vLLM в `k8s/base/vllm.env` → ConfigMap | правка без пересборки образа |
| **Бонус 1:** kustomize | `kubectl apply -k k8s/overlays/<env>` | см. «Деплой» |
| **Бонус 2:** initContainer-скачивание | Отдельный rootless-образ `model-downloader:v1` со своим Dockerfile | `docker/downloader/` |
| **Бонус 3:** нагрузочное тестирование | `scripts/bench.sh`, метрики и аналитика ниже | раздел «Нагрузочное тестирование» |

## Структура репозитория

```
docker/vllm/           Dockerfile + entrypoint.sh — образ инференса (rootless, uid 10001)
docker/downloader/     Dockerfile + download.sh — лёгкий initContainer-образ для скачивания весов
k8s/base/              Deployment, Service, PVC, Namespace, ConfigMap (vllm.env), logging.json
k8s/overlays/dev/      NodePort 30000, imagePullPolicy: Always
k8s/overlays/prod/     NetworkPolicy (ingress только на :8000), без NodePort
custom_logging/        redact.py — фильтры логирования
locks/                 uv-локи зависимостей (с хэшами) + инварианты .in
scripts/               deploy-and-verify.sh (e2e), bench.sh (нагрузка), test_redact_filter.py, make-locks.sh
results/               сырые логи нагрузочного тестирования (не в git; таблица — ниже)
```

## Требования

- Docker Desktop с включённым Kubernetes (или Minikube), Docker-демон запущен.
- ≥ 8 CPU и 16 GB RAM для Docker/WSL (веса ~3 GB, инференсу нужны ядра). При нехватке — `.wslconfig`:

```ini
[wsl2]
memory=16GB
processors=8
```

- `kubectl` и `sh`/`bash` (на Windows — Git Bash).

## Быстрый старт

Одна команда: сборка образов → деплой → 15 e2e-проверок (health, авторизация, логи без промптов, rootless, кэш PVC):

```sh
sh scripts/deploy-and-verify.sh
```

Ожидаемый итог: `SUMMARY: PASS=15 FAIL=0` и `ALL CHECKS PASSED`.

Первый запуск качает веса (~3 GB) — до 50 минут; последующие стартуют за секунды (кэш PVC). Полезные переменные: `SKIP_BUILD=1`, `SKIP_APPLY=1`, `WAIT_FIRST=<сек>`, `OVERLAY=k8s/overlays/prod`.

## Ручной запуск

```sh
docker build -f docker/vllm/Dockerfile -t vllm-cpu:0.32.0 .
docker build -f docker/downloader/Dockerfile -t model-downloader:v1 .
kubectl apply -k k8s/overlays/dev
kubectl -n llm rollout status deploy/vllm
kubectl -n llm port-forward svc/inference 18000:8000
```

## Доступ к API

Эндпоинт требует `Authorization: Bearer <token>`; токен — в Secret (создаётся при деплое):

```sh
API_KEY=$(kubectl -n llm get secret -o name | grep '^secret/vllm-api-key-' | head -1 \
  | xargs kubectl -n llm get -o jsonpath='{.data.token}' | base64 -d)

curl -s http://localhost:18000/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"/models/Qwen2.5-1.5B-Instruct",
       "messages":[{"role":"user","content":"Привет!"}], "max_tokens":64}'
```

- Без ключа — `401` (проверяется e2e-скриптом).
- Имя модели в API: `/models/Qwen2.5-1.5B-Instruct` (путь к каталогу весов, так vLLM называет её при `--model`-директории).
- dev-оверлей дополнительно публикует `NodePort 30000`; на Docker Desktop надёжнее port-forward (проверенный путь).

## Параметры конфигурации (ConfigMap)

`k8s/base/vllm.env` → ConfigMap → окружение контейнера. Изменения применяются `kubectl apply -k` без пересборки образа.

| Параметр | Значение | Назначение |
|---|---|---|
| `HF_REPO` / `HF_REVISION` | `Qwen/Qwen2.5-1.5B-Instruct` / `989aa79…` | откуда и какую ревизию качать; маркер кэша их сверяет |
| `MODEL_NAME` | `Qwen2.5-1.5B-Instruct` | каталог весов на PVC |
| `DTYPE` | `bfloat16` | тип данных (CPU-кодек) |
| `MEM_UTIL` | `0.75` | доля памяти под KV-кэш (для CPU — под `VLLM_CPU_KVCACHE_SPACE`) |
| `MAX_MODEL_LEN` | `4096` | максимальная длина контекста |
| `MAX_NUM_SEQS` | `64` | параллельных последовательностей в батче |
| `MAX_LOG_LEN` | `0` | лимит длины логируемых запросов (0 = без обрезки, но фильтры всё равно режут содержимое) |

Логирование вынесено в отдельный ConfigMap (`k8s/base/logging.json`) и подключается флагом `--logging-config.pylogging_config_file`.

## Логирование (кастомное, приватность)

Четыре уровня защиты, все проверяются e2e-скриптом и юнит-тестами:

1. **`NoModelOutputFilter`** — на записях `Generated response …` (ответ модели) извлекает только `request_id` и `finish_reason`, тело ответа заменяет на `<redacted>`; при неожиданном формате — fail-closed (запись не теряется, содержимое подменяется).
2. **`SensitiveContentFilter`** — редактирует промпты/тела запросов (`input prompt`, `json body`, `prompt: ` и т.п.), записи длиннее 2000 символов и **traceback'и** с совпадением (исключения печатаются форматтером в обход `getMessage()` — закрыт и этот вектор).
3. **`root`-логгер под теми же фильтрами** — иначе WARNING+ от сторонних библиотек уходили в `lastResort` (stderr) мимо фильтров.
4. **Факт обращения остаётся** — `Received request <id>`, статусы uvicorn-access, `Generated response … output: <redacted>`.

Токен API передаётся через окружение (`VLLM_API_KEY` из Secret), **не через argv** — не светится в `ps` / `/proc/*/cmdline` (e2e проверяет).

Юнит-тесты фильтров: `python scripts/test_redact_filter.py` → `ALL OK` (9 проверок).

Фрагмент реального лога:

```
INFO vllm.entrypoints.openai.serving_completion [pid=1] Received request chatcmpl-... with prompt token ids [..]
INFO vllm.entrypoints.serve.utils.request_logger [pid=1] Generated response chatcmpl-...: output: <redacted>, finish_reason: stop
```

## Хранилище и скачивание весов (PVC + initContainer)

- `initContainer download-model` (образ `model-downloader:v1`, rootless) запускается перед основным контейнером и скачивает веса в PVC (`/models`), если их нет.
- Маркер `.download-complete` хранит `repo=`/`revision=`: при смене `HF_REPO`/`HF_REVISION` в ConfigMap кэш перестаёт считаться валидным и веса качаются заново — молчаливой отдачи старых весов не бывает.
- Повторные запуски и рестарты: `already present: ... (skip, no network)` — без обращения к сети (проверяется e2e).
- Скачиваются только нужные файлы (`*.safetensors`, `*.json`, токенизаторы, `*.txt`/`*.tiktoken`), без `*.pth` и `orig/*`.

## Безопасность

- Rootless: оба контейнера от uid 10001, `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities: drop ALL`, `seccompProfile: RuntimeDefault`.
- Секреты (HF-токен, Bearer) — только в k8s `Secret`, не в ConfigMap и не в argv.
- prod-оверлей: `NetworkPolicy` — ingress на pod только на порт 8000, без NodePort.
- В образе нет nvidia-пакетов; `torch.cuda.is_available()` → `False`.

## Нагрузочное тестирование (бонус 3)

Клиент — `vllm bench serve` (входит в vLLM), стриминг, dataset `random`. Профили и параметры задаются окружением:

```sh
sh scripts/bench.sh                 # профиль по умолчанию (short)
PROFILE=short  NUM_PROMPTS=8  REQUEST_RATE=0.5 sh scripts/bench.sh   # лёгкая нагрузка
PROFILE=mixed  NUM_PROMPTS=8  sh scripts/bench.sh                    # средние промпты
PROFILE=long   NUM_PROMPTS=4  sh scripts/bench.sh                    # длинный контекст
```

На Windows запускать через Git Bash: `& 'C:\Program Files\Git\bin\bash.exe' scripts/bench.sh`.

### Результаты (Qwen2.5-1.5B-Instruct, vLLM 0.32.0+cpu, 8 vCPU)

| Профиль | Запросов | in / out токенов | RPS | Duration | out tok/s | total tok/s | TTFT mean / med / P99 (ms) | TPOT mean (ms) | ITL mean (ms) |
|---|---|---|---|---|---|---|---|---|---|
| light (short, спокойно) | 8 | 61 / 32 | 0.5 | 24.6 s | 10.42 | 30.28 | 1 783 / 1 656 / 2 207 | 400 | 387 |
| short (насыщенно) | 32 | 32 / 32 | 4.0 | 85.4 s | 11.99 (peak 64) | 34.85 | 41 515 / 49 588 / 53 973 | 1 276 | 1 236 |
| mixed | 8 | ~1 118 / 256 | 2.0 | 391.8 s | 6.84 (peak 32) | 29.67 | 235 685 / 261 391 / 279 321 | 514 | 388 |
| long | 4 | ~3 101 / 512 | 0.5 | 504.1 s | 4.06 (peak 24) | 28.67 | 279 455 / 294 799 / 393 316 | 429 | 428 |

Во всех прогонах `Failed = 0`.

**Как читать:**

- **TTFT включает очередь**: бенчмарк выдаёт запросы практически одновременно (`Peak concurrent` = числу запросов) — на short 32 запроса стартуют за ~8 с, и CPU-сервер обрабатывает их пачкой. Это поведение при перегрузке, а не изолированное время первого токена; строка `light` показывает TTFT на спокойной нагрузке (~1.8 с).
- **Суммарный throughput почти одинаков во всех профилях (28–35 tok/s)** — упирается в CPU (prefill + decode на 8 ядрах), а не в профиль запросов.
- Сырые логи: `results/bench-{light,short,mixed,long}.txt`.

### Аналитика: что менять для Throughput

**А) Большой поток запросов с малым числом токенов (short: 32 × 32):**

- `--max-num-seqs` вверх (64 → 128–256): префилл коротких промптов дешёвый, выигрыш в утилизации ядер от большего батча;
- `--enable-prefix-caching`: повторяющиеся префиксы не пересчитываются;
- включить компиляцию вместо `--compilation-config '{"mode": 0}'`: быстрее декод ценой первого (JIT) старта;
- отдать под инференс все ядра (`OMP_NUM_THREADS`/`taskset`), убрать конкуренцию с другими нагрузками на ноде.

**Б) Мало запросов, но огромный контекст (long: 4 × ~3 100):**

- вверх `--max-model-len` и объём KV-кэша (`--gpu-memory-utilization`, `VLLM_CPU_KVCACHE_SPACE`): длинный контекст упирается в память кэша;
- `--enable-prefix-caching` + `--chunked-prefill-size`: префилл режется на чанки — меньше head-of-line blocking для соседних запросов;
- `--max-num-seqs` вниз (8–16): батч из 64 длинных последовательностей не помещается в память и деградирует.

## Воспроизводимость зависимостей

- Все Python-зависимости (включая вторичные) зафиксированы в `locks/*.txt` с хэшами, установка — `uv pip install --require-hashes`.
- CPU-wheel vLLM 0.32.0 скачивается с GitHub Releases и верифицируется по SHA256.
- Базовый образ: `python:3.12-slim-trixie` (glibc ≥ 2.39 — под совместимость manylinux-пакетов).
- Обновление локов: `sh scripts/make-locks.sh`.

## Известные ограничения

- Инференс на CPU oneDNN: реалистичный throughput ~30 tok/s на 8 ядрах, TTFT под нагрузкой — десятки секунд.
- `MEM_UTIL=0.75` и `MAX_MODEL_LEN=4096` выбраны под 16 GB RAM машины; на большей памяти можно поднять.
- dev-оверлей использует `imagePullPolicy: Always` — намеренно: нода Docker Desktop разрешает локальные образы через registry-mirror, и `Always` гарантирует подхват пересборки (`IfNotPresent` оставляет старый кэш ноды).
- Стратегия обновления — `Recreate` (один инстанс, RWO PVC): обновление = короткий простой.
- NodePort dev-овера на Docker Desktop не пробрасывается наружу надёжно — используйте port-forward.

## Чеклист для проверяющего

```sh
sh scripts/deploy-and-verify.sh          # всё: сборка, деплой, 15 проверок, ожидаем PASS=15 FAIL=0
python scripts/test_redact_filter.py     # фильтры логирования, ожидаем ALL OK
kubectl kustomize k8s/overlays/dev       # манифесты собираются
sh scripts/bench.sh                      # нагрузочный тест (профиль short)
```
