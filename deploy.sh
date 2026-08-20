#!/usr/bin/env bash
# ============================================================
# NemoHermes Linux one-click deployment main entry
#
# Usage:
#   ./deploy.sh                # full pipeline
#   ./deploy.sh --skip-approvals   # skip approvals.mode change
#   ./deploy.sh --skip-mcp         # skip MCP config
#   ./deploy.sh --skip-config      # skip wizard, use current config.env
#   ./deploy.sh 01 02 ...          # run only the given steps
#
# Interactive prompts (security-sensitive, manual input):
#   ① onboard inference API key (if INFERENCE_API_KEY unset)
#   ② Open WebUI initial admin creation (browser)
#   ③ MCP Router token (if MCP is configured)
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
load_config

# ---- Argument parsing ----
SKIP_APPROVALS=0; SKIP_MCP=0; SKIP_CONFIG=0
SELECTED=()
for arg in "$@"; do
  case "$arg" in
    --skip-approvals) SKIP_APPROVALS=1 ;;
    --skip-mcp)       SKIP_MCP=1 ;;
    --skip-config)    SKIP_CONFIG=1 ;;
    0[1-6])           SELECTED+=("$arg") ;;
    -h|--help)
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown argument: $arg (supported: --skip-approvals / --skip-mcp / --skip-config / 01..06)" ;;
  esac
done

# ---- Pre-checks ----
require_cmd bash ssh
# Empty REMOTE_HOST = run locally on the target machine (recommended, just run ./deploy.sh)
# Only needed when deploying remotely from another machine (ssh alias or user@host)
if [ -n "${REMOTE_HOST:-}" ]; then
  log_info "Remote deploy mode: ${REMOTE_HOST}"
else
  log_info "Local deploy mode (this machine is the target)"
  export REMOTE_HOST=""   # explicit empty = lib.sh remote() runs local eval
fi

# ---- Interactive config wizard (no manual config.env editing, just paste) ----
# Can be skipped with --skip-config (uses current config.env values)
if [ "$SKIP_CONFIG" = "0" ]; then
  prompt_config
fi

log_step "NemoHermes Linux deployment"
log_info "Target host: ${REMOTE_HOST}"
log_info "Sandbox: ${SANDBOX_NAME} | Inference: ${INFERENCE_MODEL} @ ${INFERENCE_BASE_URL}"
[ "$SKIP_APPROVALS" = "1" ] && log_info "(approvals change skipped)"
[ "$SKIP_MCP" = "1" ] && log_info "(MCP config skipped)"

run_step() {
  local script="$1" name="$2"
  # SELECTED holds step numbers like "04"; match against the numeric prefix
  # of the script name ("04-openwebui" -> "04").
  if [ "${#SELECTED[@]}" -gt 0 ]; then
    ! printf '%s\n' "${SELECTED[@]}" | grep -qx "${script%%-*}" && return 0
  fi
  log_step "▶ ${name}"
  "${SCRIPT_DIR}/${script}.sh"
}

run_step 01-infra      "Step 1: Infrastructure (installs binaries + onboards sandbox)"
if [ "$SKIP_APPROVALS" = "0" ]; then
  run_step 03-hermes   "Step 2: Approvals mode"
fi
run_step 04-openwebui  "Step 3: Open WebUI"
if [ "$SKIP_MCP" = "0" ]; then
  run_step 05-mcp      "Step 4: MCP Router"
fi
run_step 06-verify     "Step 5: End-to-end verification"

log_step "Deployment finished"
log_info "Open WebUI: http://127.0.0.1:${WEBUI_LOCAL_PORT:-3000}"
[ "$SKIP_MCP" = "0" ] && [ -n "${MCP_URL:-}" ] && log_info "MCP: ${MCP_URL}"
