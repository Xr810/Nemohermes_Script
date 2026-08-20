#!/usr/bin/env bash
# ============================================================
# Shared library: logging, assertions, sandbox wait, config hash sync helpers
# ============================================================

# ---- Colors ----
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

log_info()  { echo -e "${C_CYAN}[INFO]${C_RESET}  $*"; }
log_ok()    { echo -e "${C_GREEN}[ OK ]${C_RESET}  $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
log_err()   { echo -e "${C_RED}[ERR ]${C_RESET}  $*" >&2; }
log_step()  { echo; echo -e "${C_BOLD}${C_CYAN}━━━ $* ━━━${C_RESET}"; }

die() { log_err "$*"; exit 1; }

# ─── Interactive config wizard ───
# Enter keeps the current config.env value; required items never silently default.
prompt_config() {
  local env_file
  env_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.env"

  local cur_url cur_model cur_mcp cur_approvals cur_sandbox
  cur_url="$(grep -E '^INFERENCE_BASE_URL=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
  cur_model="$(grep -E '^INFERENCE_MODEL=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
  cur_mcp="$(grep -E '^MCP_URL=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
  cur_approvals="$(grep -E '^APPROVALS_MODE=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
  cur_sandbox="$(grep -E '^SANDBOX_NAME=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"

  echo
  echo -e "${C_BOLD}${C_CYAN}━━━ Deployment Config (Enter = keep current value) ━━━${C_RESET}"
  echo -e "${C_YELLOW}Each item shows the current value; press Enter to keep it, type to override.${C_RESET}"

  # 1. Inference endpoint (required)
  echo -e "${C_YELLOW}1) Inference base URL (OpenAI-compatible, e.g. https://xxx.example.com/v1)${C_RESET}"
  echo -e "   current: ${cur_url:-<none>}"
  while :; do
    read -r -p "   > " INFERENCE_BASE_URL
    [ -n "$INFERENCE_BASE_URL" ] && break
    [ -n "$cur_url" ] && { INFERENCE_BASE_URL="$cur_url"; break; }
    log_warn "Inference base URL is required (onboard probes it). Paste a real OpenAI-compatible endpoint"
  done
  case "$INFERENCE_BASE_URL" in
    http://*|https://*) ;;
    *) log_warn "URL does not start with http(s); onboard will likely fail, please double-check" ;;
  esac

  # 2. Model name (required)
  echo -e "${C_YELLOW}2) Default model name (required, e.g. DeepSeek-V4-Flash / Pro / V3.2)${C_RESET}"
  echo -e "   current: ${cur_model:-<none>}"
  while :; do
    read -r -p "   > " INFERENCE_MODEL
    [ -n "$INFERENCE_MODEL" ] && break
    [ -n "$cur_model" ] && { INFERENCE_MODEL="$cur_model"; break; }
    log_warn "Model name is required (onboard configures it). Type the model id of your endpoint"
  done

  # 3. API key (visible input; only the prefix is echoed back)
  echo -e "${C_YELLOW}3) Inference API key (visible input; Enter = keep env INFERENCE_API_KEY)${C_RESET}"
  if [ -n "${INFERENCE_API_KEY:-}" ]; then
    echo -e "   current: (from env INFERENCE_API_KEY, prefix $(printf '%s' "$INFERENCE_API_KEY" | cut -c1-4)...) — Enter keeps it"
  else
    echo -e "   current: <none>"
  fi
  read -r -p "   > " API_KEY_INPUT
  echo
  if [ -n "$API_KEY_INPUT" ]; then
    printf -v INFERENCE_API_KEY '%s' "$API_KEY_INPUT"
    echo -e "   (recorded, prefix $(printf '%s' "$INFERENCE_API_KEY" | cut -c1-4)..., total $(printf '%s' "$INFERENCE_API_KEY" | wc -c | tr -d ' ') chars)"
  elif [ -z "${INFERENCE_API_KEY:-}" ]; then
    log_warn "No API key set — onboard will fail. Paste it above, or export INFERENCE_API_KEY and rerun"
  fi

  # 4. MCP URL (optional)
  echo -e "${C_YELLOW}4) MCP Router URL (Enter = keep current / blank = skip, e.g. https://xxx/mcp)${C_RESET}"
  echo -e "   current: ${cur_mcp:-<none>}"
  read -r -p "   > " MCP_URL
  [ -n "$MCP_URL" ] || MCP_URL="${cur_mcp:-}"

  # 4b. MCP token — only when a URL is set. Never written to config.env;
  # `nemoclaw mcp add` keeps it host-side and the sandbox sees a placeholder.
  if [ -n "${MCP_URL:-}" ]; then
    echo -e "${C_YELLOW}5) MCP Router token (visible input; raw token only, no 'Bearer ' prefix)${C_RESET}"
    if [ -n "${MCP_ROUTER_TOKEN:-}" ]; then
      echo -e "   current: (from env MCP_ROUTER_TOKEN, prefix $(printf '%s' "$MCP_ROUTER_TOKEN" | cut -c1-4)...) — Enter keeps it"
    else
      echo -e "   current: <none>"
    fi
    read -r -p "   > " MCP_TOKEN_INPUT
    echo
    if [ -n "$MCP_TOKEN_INPUT" ]; then
      MCP_TOKEN_INPUT="${MCP_TOKEN_INPUT#Bearer }"
      MCP_TOKEN_INPUT="${MCP_TOKEN_INPUT#bearer }"
      printf -v MCP_ROUTER_TOKEN '%s' "$MCP_TOKEN_INPUT"
      echo -e "   (recorded, prefix $(printf '%s' "$MCP_ROUTER_TOKEN" | cut -c1-4)..., total $(printf '%s' "$MCP_ROUTER_TOKEN" | wc -c | tr -d ' ') chars)"
    elif [ -z "${MCP_ROUTER_TOKEN:-}" ]; then
      die "MCP URL is set but no token was entered. Paste the Router token, or leave the URL blank to skip MCP"
    fi
  else
    MCP_ROUTER_TOKEN=""
  fi

  # 6. Approval mode
  echo -e "${C_YELLOW}6) Approval mode [off=no prompts / smart=auto low-risk / manual=prompt]${C_RESET}"
  echo -e "   current: ${cur_approvals:-manual}"
  read -r -p "   > " APPROVALS_MODE
  [ -n "$APPROVALS_MODE" ] || APPROVALS_MODE="${cur_approvals:-manual}"
  case "$APPROVALS_MODE" in
    manual|smart|off) ;;
    *) log_warn "Invalid value, using manual"; APPROVALS_MODE="manual" ;;
  esac

  # 7. Sandbox name (required)
  echo -e "${C_YELLOW}7) Sandbox name (required; lowercase letters/digits/hyphens, e.g. main / dev / je-accept)${C_RESET}"
  echo -e "   current: ${cur_sandbox:-<none>}"
  while :; do
    read -r -p "   > " SANDBOX_NAME
    [ -n "$SANDBOX_NAME" ] && break
    [ -n "$cur_sandbox" ] && { SANDBOX_NAME="$cur_sandbox"; break; }
    log_warn "Sandbox name is required (onboard creates it)"
  done
  case "$SANDBOX_NAME" in
    *[!a-z0-9-]*|"") log_warn "Sandbox name should be lowercase letters/digits/hyphens only: '${SANDBOX_NAME}'" ;;
  esac

  # Persist to config.env (| delimiter survives the / in URLs)
  if [ -f "$env_file" ]; then
    sed -i.bak \
      -e "s|^INFERENCE_BASE_URL=.*|INFERENCE_BASE_URL=\"${INFERENCE_BASE_URL}\"|" \
      -e "s|^INFERENCE_MODEL=.*|INFERENCE_MODEL=\"${INFERENCE_MODEL}\"|" \
      -e "s|^MCP_URL=.*|MCP_URL=\"${MCP_URL}\"|" \
      -e "s|^APPROVALS_MODE=.*|APPROVALS_MODE=\"${APPROVALS_MODE}\"|" \
      -e "s|^SANDBOX_NAME=.*|SANDBOX_NAME=\"${SANDBOX_NAME}\"|" \
      "$env_file"
    rm -f "$env_file.bak"
    log_ok "Config saved to config.env (API key and MCP token kept in-memory only)"
  fi

  echo
  log_info "Confirmed: sandbox=${SANDBOX_NAME}  inference=${INFERENCE_BASE_URL}  model=${INFERENCE_MODEL}  approvals=${APPROVALS_MODE}"
  if [ -n "${MCP_URL:-}" ]; then
    log_info "MCP=${MCP_URL} (token in-memory only, will register via nemoclaw mcp add)"
  else
    log_info "MCP=skip"
  fi

  # Export so child scripts inherit these values
  export INFERENCE_BASE_URL INFERENCE_MODEL INFERENCE_API_KEY MCP_URL MCP_ROUTER_TOKEN APPROVALS_MODE SANDBOX_NAME
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd (install it first)"
}

load_config() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "${dir}/config.env"
}

# Empty REMOTE_HOST = run locally; set = run over ssh (remote deploy)
remote() {
  if [ -n "${REMOTE_HOST:-}" ]; then
    ssh -o ConnectTimeout=15 "$REMOTE_HOST" "$@"
  else
    # eval parses the whole command line the way a remote shell would
    eval "$*"
  fi
}

sandbox_exec() { remote "nemoclaw ${SANDBOX_NAME} exec -- $*"; }

wait_sandbox_ready() {
  local secs="${SANDBOX_WAIT_SECS:-120}" waited=0
  log_info "Waiting for sandbox '${SANDBOX_NAME}' Ready (max ${secs}s)..."
  while [ "$waited" -lt "$secs" ]; do
    if remote "openshell -g nemoclaw sandbox list 2>/dev/null" | grep -q "${SANDBOX_NAME}.*Ready"; then
      log_ok "sandbox Ready"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log_err "sandbox not Ready within ${secs}s. Check: openshell -g nemoclaw sandbox list"
  return 1
}

# Restarting status = config drift signal
sandbox_restarting() {
  remote "docker ps -a --filter 'label=openshell.ai/sandbox-name=${SANDBOX_NAME}' --format '{{.Status}}' 2>/dev/null" | grep -q restarting
}

# ---- Hermes config hash anchor sync ----
# NemoClaw locks the config.yaml sha256 in /sandbox/.hermes/.config-hash. After
# editing config.yaml the anchor MUST be updated, or restart triggers
# HERMES_MCP_CONFIG_DRIFT. Usage: sync_config_hash <container-id>
sync_config_hash() {
  local cid="$1"
  [ -n "$cid" ] || die "sync_config_hash: missing container ID"

  remote "docker cp ${cid}:/sandbox/.hermes/config.yaml /tmp/hm-config.yaml 2>/dev/null" \
    || die "cannot read container config.yaml"
  remote "docker cp ${cid}:/sandbox/.hermes/.config-hash /tmp/hm-config-hash 2>/dev/null" \
    || die "cannot read container .config-hash"

  local new_hash
  new_hash="$(remote "sha256sum /tmp/hm-config.yaml | awk '{print \$1}'")"
  [ -n "$new_hash" ] || die "failed to compute config.yaml sha256"

  # Replace line 1 only; the .env and MCP state lines must stay untouched
  remote "awk -v h='${new_hash}' 'NR==1{print h \"  /sandbox/.hermes/config.yaml\"; next} {print}' /tmp/hm-config-hash > /tmp/hm-config-hash.new" \
    || die "failed to update anchor"
  remote "docker cp /tmp/hm-config-hash.new ${cid}:/sandbox/.hermes/.config-hash" \
    || die "failed to write back anchor"
  log_ok "config hash anchor synced (config.yaml → ${new_hash:0:12}...)"
}

# Restart the container and confirm no drift. Usage: restart_sandbox_verify <container-id>
restart_sandbox_verify() {
  local cid="$1"
  log_info "Restarting sandbox container to verify no drift..."
  remote "docker restart ${cid}" >/dev/null 2>&1 || die "failed to restart container"
  sleep 8
  if sandbox_restarting; then
    log_err "container entered Restarting (likely HERMES_MCP_CONFIG_DRIFT)"
    return 1
  fi
  wait_sandbox_ready || return 1
  log_ok "sandbox healthy after restart"
  return 0
}

# Matched by label, not name: real names look like openshell-default--<sandbox>-<uuid>
sandbox_container_id() {
  remote "docker ps -a --filter 'label=openshell.ai/sandbox-name=${SANDBOX_NAME}' --format '{{.ID}}' | head -1"
}
