#!/usr/bin/env bash
# ============================================================
# 05-verify — read-only end-to-end verification
#
# Usage: ./05-verify.sh
#
# Changes nothing; exits non-zero when any check fails.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
load_config

log_step "Step 5/5: End-to-end verification"
PASS=0; FAIL=0

check() {
  local name="$1" result="$2"
  # result is the match count: non-empty and non-0 = pass
  if [ -n "$result" ] && [ "$result" != "0" ]; then
    log_ok "✓ $name"; PASS=$((PASS+1))
  else
    log_err "✗ $name"; FAIL=$((FAIL+1))
  fi
}

# 1. Sandbox Ready
check "Sandbox Ready" "$(remote "openshell -g nemoclaw sandbox list 2>/dev/null" | grep -c "${SANDBOX_NAME}.*Ready" || true)"

# 2. doctor
DOCTOR_OK="$(remote "nemoclaw ${SANDBOX_NAME} doctor --json 2>/dev/null" | grep -c '"status": "ok"' || true)"
check "doctor ok" "$DOCTOR_OK"

# 3. Hermes version
VER="$(sandbox_exec 'hermes --version' 2>/dev/null | grep -oE 'v[0-9.]+' | head -1 || echo '')"
check "Hermes version ($VER)" "$( [ -n "$VER" ] && echo 1 || echo 0 )"

# 4. approvals.mode
AMODE="$(sandbox_exec 'hermes config get approvals.mode' 2>/dev/null | tail -1 | tr -d "'\" " || echo '')"
if [ -n "${APPROVALS_MODE:-}" ]; then
  check "approvals.mode=${APPROVALS_MODE} (actual $AMODE)" "$( [ "$AMODE" = "$APPROVALS_MODE" ] && echo 1 || echo 0 )"
else
  log_info "approvals.mode = ${AMODE:-unknown} (no change requested)"
fi

# 5. Open WebUI static assets (via forward or direct probe)
WEBUI_URL="http://127.0.0.1:${WEBUI_LOCAL_PORT:-3000}"
LOADER_CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "${WEBUI_URL}/static/loader.js" 2>/dev/null || echo 000)"
check "Open WebUI static assets (${LOADER_CODE})" "$( [ "$LOADER_CODE" = "200" ] && echo 1 || echo 0 )"

# 6. Admin exists (if created)
ADMIN="$(sandbox_exec "python3 -c \"
import sqlite3
c = sqlite3.connect('file:/sandbox/open-webui/data/webui.db?mode=ro', uri=True)
print(c.execute(\\\"SELECT COUNT(*) FROM user WHERE role='admin'\\\").fetchone()[0])
\"" 2>/dev/null | tail -1 || echo 0)"
check "Admin created" "$( [ "${ADMIN:-0}" -ge 1 ] && echo 1 || echo 0 )"

# 7. Filter active (if admin created)
FILTER="$(sandbox_exec "python3 -c \"
import sqlite3
c = sqlite3.connect('file:/sandbox/open-webui/data/webui.db?mode=ro', uri=True)
r = c.execute(\\\"SELECT is_active, is_global FROM function WHERE id='hermes_source_files'\\\").fetchone()
print((r[0] and r[1]) if r else False)
\"" 2>/dev/null | tail -1 || echo 0)"
# python's and returns an int (1/0); accept "True"/"1"/"False"/"0"
FILTER_BOOL="$(echo "${FILTER}" | tr -d "[:space:]")"
check "filter active+global" "$( [ "${FILTER_BOOL}" = "True" ] || [ "${FILTER_BOOL}" = "1" ] && echo 1 || echo 0 )"

# 8. socket/main.py chat_id=None patch (without it every new chat answers 400)
SOCKET_PATCH="$(sandbox_exec "grep -c \"(request_info.get('chat_id') or '').startswith('channel:')\" /sandbox/open-webui/.venv/lib/python3.11/site-packages/open_webui/socket/main.py 2>/dev/null" || echo 0)"
check "socket/main.py chat_id=None patch" "$SOCKET_PATCH"

# 9. BYPASS_EMBEDDING_AND_RETRIEVAL enabled in start.sh (uploads reach Hermes whole)
BYPASS_SET="$(sandbox_exec "grep -c 'BYPASS_EMBEDDING_AND_RETRIEVAL=True' /sandbox/open-webui/start.sh 2>/dev/null" || echo 0)"
check "start.sh BYPASS_EMBEDDING_AND_RETRIEVAL=True" "$BYPASS_SET"

# 10. uvicorn keep-alive 300s patch (prevents half-open browser connections)
KEEPALIVE_SET="$(sandbox_exec "grep -c 'timeout_keep_alive=300' /sandbox/open-webui/.venv/lib/python3.11/site-packages/open_webui/__init__.py 2>/dev/null" || echo 0)"
check "uvicorn timeout_keep_alive=300 patch" "$KEEPALIVE_SET"

# 11. MCP tool discovery (if configured)
if [ -n "${MCP_URL:-}" ]; then
  MCP_TOOLS="$(remote "nemoclaw ${SANDBOX_NAME} mcp status mcp-router --json --tools 2>/dev/null" | grep -c '"ok": true' || true)"
  check "MCP tool discovery" "$MCP_TOOLS"
else
  log_info "MCP not configured, skipping"
fi

echo
echo "━━━ Verification result: ${PASS} passed, ${FAIL} failed ━━━"
if [ "$FAIL" -gt 0 ]; then
  log_err "Failures found. See README.md (Troubleshooting); logs: nemoclaw ${SANDBOX_NAME} logs --tail 50; journalctl --user -u je-open-webui -n 40"
  exit 1
else
  log_ok "All passed! Deployment complete."
fi
