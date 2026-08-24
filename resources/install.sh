#!/bin/sh
# Install Open WebUI 0.9.5 into /sandbox/open-webui, inside the sandbox.
# Uploaded and run by 03-openwebui.sh; not meant to be run on the host.
# Applies two upstream patches (see below) and mints the WebUI secret key.
# Idempotent: an existing venv and secret key are reused.
set -eu

OPEN_WEBUI_ROOT=/sandbox/open-webui
OPEN_WEBUI_VENV="$OPEN_WEBUI_ROOT/.venv"
WEBUI_SECRET_FILE="$OPEN_WEBUI_ROOT/.webui_secret_key"

mkdir -p \
  "$OPEN_WEBUI_ROOT/data" \
  "$OPEN_WEBUI_ROOT/python"

export UV_PYTHON_INSTALL_DIR="$OPEN_WEBUI_ROOT/python"
export UV_NO_CACHE=1

uv python install 3.11
if [ ! -x "$OPEN_WEBUI_VENV/bin/python" ]; then
  uv venv --python 3.11 "$OPEN_WEBUI_VENV"
fi
uv pip install --python "$OPEN_WEBUI_VENV/bin/python" \
  'open-webui==0.9.5' \
  'pypdfium2==5.12.1'

# ---- Patch 1: new-chat chat_id=None crash ----
# Open WebUI 0.9.5: the first message of a NEW chat sends chat_id=None
# (the key exists with value None), so .get('chat_id', '') returns None and
# .startswith() throws — every new chat answers 400 and looks like "no reply".
# Both occurrences need (or ''). Idempotent.
"$OPEN_WEBUI_VENV/bin/python" - <<'PYEOF'
from pathlib import Path

TARGET = Path("/sandbox/open-webui/.venv/lib/python3.11/site-packages/open_webui/socket/main.py")
if not TARGET.is_file():
    raise SystemExit(f"open_webui/socket/main.py not found: {TARGET}")

text = TARGET.read_text(encoding="utf-8")
original = text

text = text.replace(
    "if request_info.get('chat_id', '').startswith('channel:'):",
    "if (request_info.get('chat_id') or '').startswith('channel:'):",
)
text = text.replace(
    "if update_db and message_id and not request_info.get('chat_id', '').startswith('local:'):",
    "if update_db and message_id and not (request_info.get('chat_id') or '').startswith('local:'):",
)

if text == original:
    print("socket/main.py already patched or pattern absent — nothing to do")
else:
    TARGET.write_text(text, encoding="utf-8")
    print("Patched open_webui/socket/main.py (chat_id=None crash fix)")
PYEOF

# ---- Patch 2: uvicorn keep-alive ----
# Open WebUI 0.9.5 uses 5s; raise it to 300s. The frontend polls
# every ~30s, and the port-forward bridge never propagates uvicorn's close, so
# pooled browser sockets pile up half-open until the whole UI freezes.
# Idempotent.
"$OPEN_WEBUI_VENV/bin/python" - <<'PYEOF'
from pathlib import Path

TARGET = Path("/sandbox/open-webui/.venv/lib/python3.11/site-packages/open_webui/__init__.py")
if not TARGET.is_file():
    raise SystemExit(f"open_webui/__init__.py not found: {TARGET}")

text = TARGET.read_text(encoding="utf-8")
original = text

OLD = """        forwarded_allow_ips='*',
        workers=UVICORN_WORKERS,
        loop=loop,
    )"""
NEW = """        forwarded_allow_ips='*',
        workers=UVICORN_WORKERS,
        loop=loop,
        timeout_keep_alive=300,
    )"""

if OLD in text:
    text = text.replace(OLD, NEW)
    TARGET.write_text(text, encoding="utf-8")
    print("Patched open_webui/__init__.py (timeout_keep_alive=300)")
elif "timeout_keep_alive=300" in text:
    print("open_webui/__init__.py already patched — nothing to do")
else:
    print("WARNING: keep-alive patch pattern not found in __init__.py (manual check needed)")
PYEOF

if [ ! -s "$WEBUI_SECRET_FILE" ]; then
  umask 077
  "$OPEN_WEBUI_VENV/bin/python" -c 'import secrets; print(secrets.token_urlsafe(48))' \
    > "$WEBUI_SECRET_FILE"
fi

chmod 600 "$WEBUI_SECRET_FILE"

"$OPEN_WEBUI_VENV/bin/open-webui" --help >/dev/null
echo 'Open WebUI v0.9.5 installed in /sandbox/open-webui'
