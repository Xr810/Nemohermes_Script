#!/bin/sh
# Launch Open WebUI inside the sandbox; the ExecStart of je-open-webui.service.
# Reads the Hermes API host/port/key from /sandbox/.hermes/.env and points Open
# WebUI at it, then execs the server with a scrubbed environment (env -i), so
# nothing the service manager exports can leak in. WEBUI_NAME sets the UI name.
#
# Optional /sandbox/open-webui/.admin.env (mode 600) supplies WEBUI_ADMIN_* for
# headless first-boot account creation. Open WebUI ignores those variables once
# any user exists. 03-openwebui.sh removes the file after the admin and filter
# are in place.
set -eu

OPEN_WEBUI_ROOT=/sandbox/open-webui
HERMES_ENV=/sandbox/.hermes/.env
WEBUI_SECRET_FILE="$OPEN_WEBUI_ROOT/.webui_secret_key"
ADMIN_ENV_FILE="$OPEN_WEBUI_ROOT/.admin.env"

if [ ! -x "$OPEN_WEBUI_ROOT/.venv/bin/open-webui" ]; then
  echo 'Open WebUI is not installed. Run /sandbox/open-webui/install.sh first.' >&2
  exit 1
fi

if [ ! -r "$HERMES_ENV" ]; then
  echo 'Hermes environment file is not readable.' >&2
  exit 1
fi

set -a
. "$HERMES_ENV"
set +a

: "${API_SERVER_KEY:?API_SERVER_KEY is required}"
: "${API_SERVER_HOST:?API_SERVER_HOST is required}"
: "${API_SERVER_PORT:?API_SERVER_PORT is required}"

if [ ! -s "$WEBUI_SECRET_FILE" ]; then
  echo 'Open WebUI secret key is missing.' >&2
  exit 1
fi

WEBUI_SECRET_KEY=$(cat "$WEBUI_SECRET_FILE")

WEBUI_ADMIN_EMAIL=""
WEBUI_ADMIN_PASSWORD=""
WEBUI_ADMIN_NAME=""
if [ -r "$ADMIN_ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ADMIN_ENV_FILE"
  set +a
fi

set -- env -i \
  HOME=/sandbox \
  USER=sandbox \
  PATH="$OPEN_WEBUI_ROOT/.venv/bin:/usr/local/bin:/usr/bin:/bin" \
  SQLITE_TMPDIR=/tmp \
  DATA_DIR="$OPEN_WEBUI_ROOT/data" \
  CHROMA_DATA_PATH="$OPEN_WEBUI_ROOT/data/vector_db" \
  HOST=127.0.0.1 \
  PORT=3000 \
  WEBUI_AUTH=True \
  WEBUI_SECRET_KEY="$WEBUI_SECRET_KEY" \
  WEBUI_NAME='Johnson Electric' \
  ENABLE_OLLAMA_API=False \
  ENABLE_VERSION_UPDATE_CHECK=False \
  ENABLE_BASE_MODELS_CACHE=False \
  TOOL_SERVER_CONNECTIONS='[]' \
  ANONYMIZED_TELEMETRY=False \
  BYPASS_EMBEDDING_AND_RETRIEVAL=True \
  RAG_FULL_CONTEXT=False \
  ENABLE_RAG_HYBRID_SEARCH=False \
  RAG_EMBEDDING_ENGINE='' \
  RAG_EMBEDDING_MODEL='/sandbox/open-webui/data/models/all-MiniLM-L6-v2' \
  RAG_EMBEDDING_MODEL_AUTO_UPDATE=False \
  HF_HUB_OFFLINE=1 \
  TRANSFORMERS_OFFLINE=1 \
  OPENAI_API_BASE_URL="http://$API_SERVER_HOST:$API_SERVER_PORT/v1" \
  OPENAI_API_KEY="$API_SERVER_KEY" \
  AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST=15

if [ -n "${WEBUI_ADMIN_EMAIL:-}" ] && [ -n "${WEBUI_ADMIN_PASSWORD:-}" ]; then
  set -- "$@" \
    WEBUI_ADMIN_EMAIL="$WEBUI_ADMIN_EMAIL" \
    WEBUI_ADMIN_PASSWORD="$WEBUI_ADMIN_PASSWORD" \
    WEBUI_ADMIN_NAME="${WEBUI_ADMIN_NAME:-Admin}"
fi

exec "$@" \
  "$OPEN_WEBUI_ROOT/.venv/bin/open-webui" serve --host 127.0.0.1 --port 3000
