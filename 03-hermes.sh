#!/usr/bin/env bash
# ============================================================
# 03-hermes: approvals.mode setup + config hash anchor sync
# Usage: ./03-hermes.sh
# Note: editing Hermes config.yaml directly triggers HERMES_MCP_CONFIG_DRIFT,
#       this script syncs the .config-hash anchor after editing and restarts to verify (see OPERATIONS_LESSONS.md L2)
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
load_config

# Empty APPROVALS_MODE = skip
if [ -z "${APPROVALS_MODE:-}" ]; then
  log_ok "APPROVALS_MODE unset, skipping (keep onboard default)"
  exit 0
fi

# Validate allowed values
case "$APPROVALS_MODE" in
  manual|smart|off) ;;
  *) die "APPROVALS_MODE must be manual/smart/off (current: ${APPROVALS_MODE})" ;;
esac

log_step "Step 2/5: Hermes approvals.mode=${APPROVALS_MODE}"

# Get container ID
CID="$(sandbox_container_id)"
[ -n "$CID" ] || die "Cannot find sandbox container (openshell-${SANDBOX_NAME})"

# Backup (in-container + local)
remote "docker cp ${CID}:/sandbox/.hermes/config.yaml /tmp/hm-config.bak && docker cp ${CID}:/sandbox/.hermes/.config-hash /tmp/hm-hash.bak" \
  || log_warn "Backup failed (continuing)"

# Read current mode
CURRENT="$(sandbox_exec 'hermes config get approvals.mode' 2>/dev/null | tail -1 | tr -d "'\" " || echo '')"
log_info "Current approvals.mode: ${CURRENT:-unknown}"

if [ "$CURRENT" = "$APPROVALS_MODE" ]; then
  log_ok "Already ${APPROVALS_MODE}, no change needed"
else
  log_info "Setting approvals.mode = ${APPROVALS_MODE} ..."
  sandbox_exec "hermes config set approvals.mode ${APPROVALS_MODE}" \
    || die "hermes config set failed"
  log_ok "config.yaml written"

  # Key: sync the config hash anchor (otherwise drift on restart)
  log_info "Syncing .config-hash anchor (prevent drift)..."
  sync_config_hash "$CID"
fi

# Restart the container to verify no drift
if ! restart_sandbox_verify "$CID"; then
  log_err "Anomaly after restart! Attempting rollback..."
  remote "docker cp /tmp/hm-config.bak ${CID}:/sandbox/.hermes/config.yaml && docker cp /tmp/hm-hash.bak ${CID}:/sandbox/.hermes/.config-hash" \
    && remote "docker restart ${CID}" >/dev/null 2>&1 \
    && log_warn "Rolled back to pre-change state. Check the logs: nemoclaw ${SANDBOX_NAME} logs --tail 50" \
    || log_err "Rollback failed, manual intervention required"
  exit 1
fi

FINAL="$(sandbox_exec 'hermes config get approvals.mode' 2>/dev/null | tail -1 | tr -d "'\" ")"
log_ok "approvals.mode = ${FINAL} (still effective after restart)"
log_ok "Step 2 done. Next: ./04-openwebui.sh"
