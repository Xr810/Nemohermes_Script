#!/usr/bin/env bash
# ============================================================
# 02-hermes — Hermes approvals.mode plus config hash anchor sync
#
# Usage: ./02-hermes.sh
#
# Editing config.yaml alone triggers HERMES_MCP_CONFIG_DRIFT on the next
# restart, so this script re-anchors .config-hash and restarts once to confirm,
# rolling back if the container comes up unhealthy. See OPERATIONS.md.
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

# Container is looked up by the openshell.ai/sandbox-name label, not by name
CID="$(sandbox_container_id)"
[ -n "$CID" ] || die "Cannot find the container for sandbox '${SANDBOX_NAME}'.
  Check: docker ps -a --filter 'label=openshell.ai/sandbox-name=${SANDBOX_NAME}'"

# Copy both config.yaml and its .config-hash lock to host /tmp; rollback needs
# the pair, since restoring one without the other re-creates the drift
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
log_ok "Step 2 done. Next: ./03-openwebui.sh"
