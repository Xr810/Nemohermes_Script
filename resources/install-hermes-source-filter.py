#!/usr/bin/env python3
"""Create/update and enable the local Hermes source-file Open WebUI filter.

Runs inside the sandbox, against the loopback Open WebUI API. Authenticates by
minting a short-lived admin JWT from the WebUI secret key, so it needs no
password. Safe to re-run: an existing function is updated in place.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

import jwt

# `nemoclaw exec` inherits the host's proxy variables, but Open WebUI listens on
# loopback inside this network namespace, so a proxied request never reaches it.
for _proxy_key in (
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "http_proxy",
    "https_proxy",
    "ALL_PROXY",
    "all_proxy",
):
    os.environ.pop(_proxy_key, None)


ROOT = Path("/sandbox/open-webui")
DB_PATH = ROOT / "data" / "webui.db"
SECRET_PATH = ROOT / ".webui_secret_key"
DEFAULT_SOURCE = ROOT / "functions" / "hermes_source_files.py"
FUNCTION_ID = "hermes_source_files"
BASE_URL = "http://127.0.0.1:3000/api/v1/functions"


def request_json(method: str, path: str, token: str, payload: dict | None = None) -> tuple[int, dict]:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(
        BASE_URL + path,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    # Step 3 starts Open WebUI and imports the filter back to back, so uvicorn
    # may still be binding when the first request goes out. Retry URLError
    # (connection refused) for ~20s; HTTP errors are answers, so return at once.
    last_error: Exception | None = None
    for attempt in range(1, 11):
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                raw = response.read().decode("utf-8")
                return response.status, json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            raw = error.read().decode("utf-8", errors="replace")
            try:
                detail = json.loads(raw)
            except json.JSONDecodeError:
                detail = {"detail": raw}
            return error.code, detail
        except urllib.error.URLError as error:
            last_error = error
            if attempt < 10:
                time.sleep(2)
    raise last_error if last_error is not None else RuntimeError("request failed")


def admin_id() -> str:
    with sqlite3.connect(f"file:{DB_PATH.resolve()}?mode=ro", uri=True) as connection:
        row = connection.execute(
            "SELECT id FROM user WHERE role = 'admin' ORDER BY created_at LIMIT 1"
        ).fetchone()
    if not row:
        raise RuntimeError("No Open WebUI admin user exists")
    return str(row[0])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    args = parser.parse_args()

    content = args.source.read_text(encoding="utf-8")
    secret = SECRET_PATH.read_text(encoding="utf-8").strip()
    now = int(time.time())
    token = jwt.encode(
        {"id": admin_id(), "jti": str(uuid.uuid4()), "iat": now, "exp": now + 300},
        secret,
        algorithm="HS256",
    )
    form = {
        "id": FUNCTION_ID,
        "name": "Hermes Source Files",
        "content": content,
        "meta": {
            "description": (
                "Move direct chat uploads into one-request Hermes handoffs, register Hermes outgoing files "
                "into Workspace Files, and leave knowledge collections persistent on RAG."
            )
        },
    }

    status, existing = request_json("GET", f"/id/{FUNCTION_ID}", token)
    if status == 200:
        status, result = request_json("POST", f"/id/{FUNCTION_ID}/update", token, form)
        action = "updated"
    elif status == 401:
        # Open WebUI answers an unknown function id with 401 + NOT_FOUND, not
        # 404, so this branch means "does not exist yet" rather than a bad
        # token — the JWT was minted a few lines above from the WebUI secret.
        status, result = request_json("POST", "/create", token, form)
        action = "created"
    else:
        raise RuntimeError(f"Function lookup failed ({status}): {existing}")
    if status != 200:
        raise RuntimeError(f"Function {action} failed ({status}): {result}")

    if not result.get("is_active"):
        status, result = request_json("POST", f"/id/{FUNCTION_ID}/toggle", token)
        if status != 200:
            raise RuntimeError(f"Could not activate function ({status}): {result}")
    if not result.get("is_global"):
        status, result = request_json("POST", f"/id/{FUNCTION_ID}/toggle/global", token)
        if status != 200:
            raise RuntimeError(f"Could not make function global ({status}): {result}")

    print(
        json.dumps(
            {
                "status": "ok",
                "action": action,
                "id": result.get("id"),
                "type": result.get("type"),
                "is_active": result.get("is_active"),
                "is_global": result.get("is_global"),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
