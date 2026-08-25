#!/usr/bin/env bash
# ============================================================
# deploy — NemoHermes deployment entry point (wizard + ordered steps)
#
# Usage:
#   ./deploy.sh                    # steps 1, 2, 4, 5 (Open WebUI / step 3 skipped)
#   ./deploy.sh --skip-approvals   # leave approvals.mode unchanged
#   ./deploy.sh --skip-mcp         # skip MCP registration
#   ./deploy.sh --skip-config      # no wizard, use current config.env
#   ./deploy.sh 03                 # install Open WebUI later (optional)
#   ./deploy.sh 01 02 ...          # run only the given steps
#
# Each step lives in NN-*.sh and shares lib.sh / config.env. See README.md.
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
    0[1-5])           SELECTED+=("$arg") ;;
    -h|--help)
      # Reprint this file's header block, dropping the shebang and rule lines,
      # so editing the header cannot desync the help text.
      sed -n '2,/^[^#]/p' "$0" | sed -e '/^[^#]/d' -e '/^# =\{5,\}$/d' -e 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown argument: $arg (supported: --skip-approvals / --skip-mcp / --skip-config / 01..05)" ;;
  esac
done

# ---- Pre-checks ----
require_cmd bash ssh
# Empty REMOTE_HOST = run locally on the target machine (recommended: just run
# ./deploy.sh). Set it to an ssh alias or user@host only when deploying
# remotely from another machine.
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
  # SELECTED holds step numbers like "03"; match against the numeric prefix
  # of the script name ("03-openwebui" -> "03").
  if [ "${#SELECTED[@]}" -gt 0 ]; then
    ! printf '%s\n' "${SELECTED[@]}" | grep -qx "${script%%-*}" && return 0
  fi
  log_step "▶ ${name}"
  "${SCRIPT_DIR}/${script}.sh"
}

run_step 01-infra      "Step 1: Infrastructure (installs binaries + onboards sandbox)"
if [ "$SKIP_APPROVALS" = "0" ]; then
  run_step 02-hermes   "Step 2: Approvals mode"
fi
# Step 3 (Open WebUI) is opt-in: only when 03 is listed on the command line.
if [ "${#SELECTED[@]}" -gt 0 ] && printf '%s\n' "${SELECTED[@]}" | grep -qx 03; then
  run_step 03-openwebui "Step 3: Open WebUI"
else
  log_info "Step 3 (Open WebUI) skipped — point a remote Open WebUI at the Hermes API"
fi
if [ "$SKIP_MCP" = "0" ]; then
  run_step 04-mcp      "Step 4: MCP Router"
fi
run_step 05-verify     "Step 5: End-to-end verification"

log_step "Deployment finished"
log_info "Hermes API: http://127.0.0.1:${HERMES_API_PORT:-8642}/v1"
log_info "Dashboard:  http://127.0.0.1:${HERMES_DASHBOARD_PORT:-18789}/"
if [ "$SKIP_MCP" = "0" ] && [ -n "${MCP_URL:-}" ]; then
  log_info "MCP: ${MCP_URL}"
fi
# Explicit: the trailing test above would otherwise become the script's exit
# status, so ./deploy.sh --skip-mcp reported failure after a clean run.
exit 0
