#!/usr/bin/env bash
# ============================================================
# 05-mcp: MCP Router bridge (optional, skipped if MCP_URL is empty)
# Usage: ./05-mcp.sh
#
# Registers via `nemoclaw <sandbox> mcp add` (OpenShell managed MCP).
# Do NOT write the token into the sandbox Hermes config.yaml — that
# triggers HERMES_MCP_CONFIG_DRIFT and bypasses egress credential injection.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
load_config

if [ -z "${MCP_URL:-}" ]; then
  log_ok "MCP_URL unset, skipping MCP config"
  exit 0
fi

log_step "Step 4/5: MCP Router config"
log_info "MCP URL: ${MCP_URL}"
log_info "Registering with: nemoclaw ${SANDBOX_NAME} mcp add mcp-router --url <url> --env ${MCP_ENV_VAR:-MCP_ROUTER_TOKEN}"

wait_sandbox_ready || exit 1

# Token: wizard already collected it into MCP_ROUTER_TOKEN (not written to disk).
# Fallback prompt if this step is re-run alone without the wizard.
if [ -z "${MCP_ROUTER_TOKEN:-}" ]; then
  echo -e "${C_YELLOW}MCP Router token (visible input; raw token only, no 'Bearer ' prefix)${C_RESET}"
  read -r -p "   > " MCP_ROUTER_TOKEN
  echo
  MCP_ROUTER_TOKEN="${MCP_ROUTER_TOKEN#Bearer }"
  MCP_ROUTER_TOKEN="${MCP_ROUTER_TOKEN#bearer }"
fi
[ -n "${MCP_ROUTER_TOKEN:-}" ] || die "MCP Router token is required when MCP_URL is set.
  Re-run ./deploy.sh and paste it at question 5, or:
  export MCP_ROUTER_TOKEN='...'  then  ./deploy.sh 05"

# Idempotent: skip add if already registered
if remote "nemoclaw ${SANDBOX_NAME} mcp list --json 2>/dev/null" | grep -q "mcp-router"; then
  log_ok "mcp-router already registered (token not re-sent)"
else
  log_info "Registering MCP bridge via nemoclaw mcp add (token via env only, not on argv or in the sandbox file)..."
  # Export for this process only; NemoClaw persists the *name* MCP_ROUTER_TOKEN
  # and stores the value in the OpenShell provider store.
  export MCP_ROUTER_TOKEN
  remote "nemoclaw ${SANDBOX_NAME} mcp add mcp-router --url ${MCP_URL} --env ${MCP_ENV_VAR:-MCP_ROUTER_TOKEN}" \
    || die "mcp add failed"
  unset MCP_ROUTER_TOKEN
  log_ok "mcp-router registered"
fi

# Verify
log_info "Verifying credential resolution..."
remote "nemoclaw ${SANDBOX_NAME} mcp status mcp-router --json --probe 2>/dev/null" \
  | grep -q '"ok": true' && log_ok "Credential resolution OK" || log_warn "Credential resolution is not ok:true (check token)"

log_info "Verifying tool discovery..."
TOOLS="$(remote "nemoclaw ${SANDBOX_NAME} mcp status mcp-router --json --tools 2>/dev/null")"
echo "$TOOLS" | grep -o '"count": [0-9]*' | head -1 | sed 's/.*: /MCP tool count: /'
echo "$TOOLS" | grep -q '"ok": true' && log_ok "Tool discovery OK" || log_warn "Tool discovery abnormal"

log_ok "Step 4 done. Next: ./06-verify.sh"
