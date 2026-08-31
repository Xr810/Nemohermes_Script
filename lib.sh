#!/usr/bin/env bash
# ============================================================
# lib — shared helpers: logging, config wizard, sandbox and config-hash utils
#
# Usage: source lib.sh   (not meant to be executed directly)
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

# NVIDIA installer puts binaries in ~/.local/bin and Node under nvm.
prepend_local_path() {
  case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) export PATH="${HOME}/.local/bin:${PATH}" ;;
  esac
  local nvmbin
  for nvmbin in "${HOME}"/.nvm/versions/node/*/bin; do
    [ -d "$nvmbin" ] || continue
    case ":${PATH}:" in
      *":${nvmbin}:"*) ;;
      *) export PATH="${nvmbin}:${PATH}" ;;
    esac
  done
}

forward_bind_addr() {
  printf '%s' "${FORWARD_BIND:-127.0.0.1}"
}

# NemoClaw onboard: 1-19 chars, lowercase, starts with a letter,
# letters/digits/single internal hyphens only, ends with a letter or digit.
sandbox_name_valid() {
  local name="${1:-}"
  local n=${#name}
  [ "$n" -ge 1 ] && [ "$n" -le 19 ] || return 1
  case "$name" in *--*) return 1 ;; esac
  [[ "$name" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]
}

sandbox_name_suggest() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '_' '-'
}

# API key / MCP token: gitignored secrets.env, so the mandatory first-run reboot
# does not require pasting them again.
secrets_path() {
  printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secrets.env"
}

load_secrets() {
  local f
  f="$(secrets_path)"
  [ -f "$f" ] || return 0
  # shellcheck disable=SC1090
  set -a
  source "$f"
  set +a
}

save_secrets() {
  local f tmp
  f="$(secrets_path)"
  tmp="${f}.tmp.$$"
  (
    umask 077
    {
      printf '%s\n' '# Local secrets for ./deploy.sh. Gitignored; do not commit.'
      printf 'INFERENCE_API_KEY=%q\n' "${INFERENCE_API_KEY:-}"
      printf 'MCP_ROUTER_TOKEN=%q\n' "${MCP_ROUTER_TOKEN:-}"
    } > "$tmp"
    mv "$tmp" "$f"
  )
  chmod 600 "$f"
}

# ---- Interactive config wizard ----
# Enter keeps the current value — from config.env, or from secrets.env for the
# two credential prompts. Required items never silently default.
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

  # 3. API key — always prompt; Enter keeps secrets.env, typing replaces it
  echo -e "${C_YELLOW}3) Inference API key (visible input; Enter = keep saved value)${C_RESET}"
  if [ -n "${INFERENCE_API_KEY:-}" ]; then
    echo -e "   current: (secrets.env, $(printf '%s' "$INFERENCE_API_KEY" | cut -c1-4)...) — Enter keeps it"
  else
    echo -e "   current: <none>"
  fi
  read -r -p "   > " API_KEY_INPUT
  echo
  if [ -n "$API_KEY_INPUT" ]; then
    printf -v INFERENCE_API_KEY '%s' "$API_KEY_INPUT"
    echo -e "   ($(printf '%s' "$INFERENCE_API_KEY" | cut -c1-4)..., $(printf '%s' "$INFERENCE_API_KEY" | wc -c | tr -d ' ') chars)"
  elif [ -z "${INFERENCE_API_KEY:-}" ]; then
    log_warn "No API key set — onboard will fail. Paste it above, or put INFERENCE_API_KEY in secrets.env"
  fi

  # 4. MCP URL (optional)
  echo -e "${C_YELLOW}4) MCP Router URL (Enter = keep current / blank = skip, e.g. https://xxx/mcp)${C_RESET}"
  echo -e "   current: ${cur_mcp:-<none>}"
  read -r -p "   > " MCP_URL
  [ -n "$MCP_URL" ] || MCP_URL="${cur_mcp:-}"

  # 5. MCP token — always prompt when URL is set; Enter keeps secrets.env value
  if [ -n "${MCP_URL:-}" ]; then
    echo -e "${C_YELLOW}5) MCP Router token (visible input; Enter = keep saved value)${C_RESET}"
    if [ -n "${MCP_ROUTER_TOKEN:-}" ]; then
      echo -e "   current: (secrets.env, $(printf '%s' "$MCP_ROUTER_TOKEN" | cut -c1-4)...) — Enter keeps it"
    else
      echo -e "   current: <none>"
    fi
    read -r -p "   > " MCP_TOKEN_INPUT
    echo
    if [ -n "$MCP_TOKEN_INPUT" ]; then
      MCP_TOKEN_INPUT="${MCP_TOKEN_INPUT#Bearer }"
      MCP_TOKEN_INPUT="${MCP_TOKEN_INPUT#bearer }"
      printf -v MCP_ROUTER_TOKEN '%s' "$MCP_TOKEN_INPUT"
      echo -e "   ($(printf '%s' "$MCP_ROUTER_TOKEN" | cut -c1-4)..., $(printf '%s' "$MCP_ROUTER_TOKEN" | wc -c | tr -d ' ') chars)"
    elif [ -z "${MCP_ROUTER_TOKEN:-}" ]; then
      die "MCP URL is set but no token was entered. Paste the Router token, or leave the URL blank to skip MCP"
    fi
  else
    MCP_ROUTER_TOKEN=""
  fi

  # 6. Approval mode (invalid input must be re-entered; Enter keeps current)
  echo -e "${C_YELLOW}6) Approval mode [off=no prompts / smart=auto low-risk / manual=prompt]${C_RESET}"
  echo -e "   current: ${cur_approvals:-manual}"
  while :; do
    read -r -p "   > " APPROVALS_MODE
    if [ -z "$APPROVALS_MODE" ]; then
      APPROVALS_MODE="${cur_approvals:-manual}"
      break
    fi
    case "$APPROVALS_MODE" in
      manual|smart|off) break ;;
      *) log_err "Invalid approval mode: '${APPROVALS_MODE}'. Re-enter — off, smart, or manual" ;;
    esac
  done

  # 7. Sandbox name (required; reject invalid names instead of warning)
  echo -e "${C_YELLOW}7) Sandbox name (required; lowercase letters/digits/hyphens, e.g. main / dev / je-accept)${C_RESET}"
  echo -e "   current: ${cur_sandbox:-<none>}"
  while :; do
    read -r -p "   > " SANDBOX_NAME
    if [ -z "$SANDBOX_NAME" ]; then
      if [ -n "$cur_sandbox" ]; then
        SANDBOX_NAME="$cur_sandbox"
      else
        log_err "Sandbox name is required (onboard creates it). Re-enter"
        continue
      fi
    fi
    if sandbox_name_valid "$SANDBOX_NAME"; then
      break
    fi
    local suggest
    suggest="$(sandbox_name_suggest "$SANDBOX_NAME")"
    if sandbox_name_valid "$suggest" && [ "$suggest" != "$SANDBOX_NAME" ]; then
      log_err "Invalid sandbox name: '${SANDBOX_NAME}'. Re-enter (try: ${suggest})"
    else
      log_err "Invalid sandbox name: '${SANDBOX_NAME}'. Re-enter — 1-19 chars, lowercase, start with a letter, letters/digits/single hyphens only"
    fi
  done

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
    log_ok "Config saved to config.env"
  fi
  save_secrets
  if [ -n "${MCP_ROUTER_TOKEN:-}" ]; then
    log_ok "API key and MCP token saved to secrets.env (gitignored; reused after reboot)"
  else
    log_ok "API key saved to secrets.env (gitignored; reused after reboot)"
  fi

  echo
  log_info "Confirmed: sandbox=${SANDBOX_NAME}  inference=${INFERENCE_BASE_URL}  model=${INFERENCE_MODEL}  approvals=${APPROVALS_MODE}"
  if [ -n "${MCP_URL:-}" ]; then
    log_info "MCP=${MCP_URL} (token from secrets.env, registered via nemoclaw mcp add)"
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
  # Caller exports win over config.env placeholders.
  local keep_sandbox="${SANDBOX_NAME:-}"
  local keep_bind="${FORWARD_BIND:-}"
  local keep_webui_email="${WEBUI_ADMIN_EMAIL:-}"
  local keep_webui_password="${WEBUI_ADMIN_PASSWORD:-}"
  local keep_webui_name="${WEBUI_ADMIN_NAME:-}"
  local keep_webui_port="${WEBUI_PORT:-}"
  local keep_webui_local="${WEBUI_LOCAL_PORT:-}"
  # shellcheck disable=SC1091
  source "${dir}/config.env"
  load_secrets
  prepend_local_path
  [ -n "$keep_sandbox" ] && SANDBOX_NAME="$keep_sandbox"
  [ -n "$keep_bind" ] && FORWARD_BIND="$keep_bind"
  [ -n "$keep_webui_email" ] && WEBUI_ADMIN_EMAIL="$keep_webui_email"
  [ -n "$keep_webui_password" ] && WEBUI_ADMIN_PASSWORD="$keep_webui_password"
  [ -n "$keep_webui_name" ] && WEBUI_ADMIN_NAME="$keep_webui_name"
  [ -n "$keep_webui_port" ] && WEBUI_PORT="$keep_webui_port"
  [ -n "$keep_webui_local" ] && WEBUI_LOCAL_PORT="$keep_webui_local"
  FORWARD_BIND="${FORWARD_BIND:-127.0.0.1}"
  export FORWARD_BIND SANDBOX_NAME
  export WEBUI_ADMIN_EMAIL WEBUI_ADMIN_PASSWORD WEBUI_ADMIN_NAME
  export WEBUI_PORT WEBUI_LOCAL_PORT
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

# Restart the container and confirm no drift.
# Usage: restart_sandbox_verify <container-id>
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

# Matched by label, not name: real names look like
# openshell-default--<sandbox>-<uuid>
sandbox_container_id() {
  remote "docker ps -a --filter 'label=openshell.ai/sandbox-name=${SANDBOX_NAME}' --format '{{.ID}}' | head -1"
}

# Hermes dashboard + API host forwards. Onboard publishes these, but those
# tunnels die with the gateway.
install_hermes_host_forwards() {
  local unit_dir bind openshell api_port dash_port
  unit_dir="${UNIT_DIR:-$HOME/.config/systemd/user}"
  bind="$(forward_bind_addr)"
  api_port="${HERMES_API_PORT:-8642}"
  dash_port="${HERMES_DASHBOARD_PORT:-18789}"
  openshell="$(command -v openshell)"
  [ -n "$openshell" ] || die "openshell not on PATH"
  mkdir -p "$unit_dir"

  local gateway_unit="${unit_dir}/nemoclaw-openshell-gateway.service"
  if [ -f "$gateway_unit" ]; then
    sed -i '/^After=default\.target$/d' "$gateway_unit"
  fi
  mkdir -p "${unit_dir}/nemoclaw-openshell-gateway.service.d"
  cat > "${unit_dir}/nemoclaw-openshell-gateway.service.d/no-after-default.conf" <<'EOF'
[Unit]
# Intentionally empty: After=default.target is removed from the unit file above.
EOF

  cat > "${unit_dir}/je-hermes-dashboard.service" <<EOF
[Unit]
Description=Hermes dashboard inside the OpenShell sandbox
After=nemoclaw-openshell-gateway.service
Requires=nemoclaw-openshell-gateway.service
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
Type=simple
ExecStart=${openshell} -g nemoclaw sandbox exec -n ${SANDBOX_NAME} --no-tty -- hermes dashboard --no-open --port 9119 --skip-build
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  cat > "${unit_dir}/je-hermes-dashboard-forward.service" <<EOF
[Unit]
Description=Forward Hermes dashboard to ${bind}:${dash_port}
After=je-hermes-dashboard.service nemoclaw-openshell-gateway.service
Requires=nemoclaw-openshell-gateway.service
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
Type=simple
ExecStart=${openshell} -g nemoclaw forward service ${SANDBOX_NAME} --target-port 9119 --local ${bind}:${dash_port}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  cat > "${unit_dir}/je-hermes-api-forward.service" <<EOF
[Unit]
Description=Forward Hermes API to ${bind}:${api_port}
After=nemoclaw-openshell-gateway.service
Requires=nemoclaw-openshell-gateway.service
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
Type=simple
ExecStart=${openshell} -g nemoclaw forward service ${SANDBOX_NAME} --target-port 18642 --local ${bind}:${api_port}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  if [ "$(loginctl show-user "${USER}" -p Linger --value 2>/dev/null || true)" != "yes" ]; then
    loginctl enable-linger "${USER}" 2>/dev/null \
      || sudo loginctl enable-linger "${USER}" \
      || log_warn "Could not enable lingering for ${USER}; after reboot, log in once so user systemd can start the Hermes API"
  fi
  systemctl --user reset-failed \
    je-hermes-dashboard.service je-hermes-dashboard-forward.service je-hermes-api-forward.service \
    2>/dev/null || true
  systemctl --user enable --now je-hermes-dashboard.service \
    || log_warn "Hermes dashboard start failed (can retry later)"
  systemctl --user enable --now je-hermes-dashboard-forward.service \
    || log_warn "Hermes dashboard forward start failed (can retry later)"
  systemctl --user enable --now je-hermes-api-forward.service \
    || log_warn "Hermes API forward start failed (can retry later)"
  log_ok "Hermes API http://${bind}:${api_port}/v1  dashboard http://${bind}:${dash_port}/"
}
