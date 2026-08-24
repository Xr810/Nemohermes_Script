#!/usr/bin/env bash
# ============================================================
# 01-infra — Docker, OpenShell/NemoClaw binaries, and sandbox onboarding
#
# Usage: ./01-infra.sh
#
# Runs the NVIDIA installer (https://www.nvidia.com/nemoclaw.sh) when any
# component is missing, then onboards until the sandbox reports Ready.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
load_config

# ---- Preflight: inference DNS ----
# Fail fast if the endpoint is fake-ip or unresolvable.
# Onboard's SSRF probe would only say "no HTTP response".
check_inference_dns() {
  local host ip
  host="$(printf '%s' "${INFERENCE_BASE_URL}" | sed -E 's#^[a-z][a-z0-9+.-]*://([^/:]+).*#\1#')"
  [ -n "${host}" ] || return 0
  # Any literal IPv4 skips the DNS check; a LAN one (192.168.x / 10.x) is also
  # trusted by NemoClaw's SSRF guard.
  case "${host}" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) return 0 ;;
  esac
  if command -v dig >/dev/null 2>&1; then
    ip="$(dig +short "${host}" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
  else
    ip="$(getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1}' | head -1)"
  fi
  case "${ip}" in
    198.18.*|198.19.*)
      die "Inference host ${host} resolves to fake-ip ${ip} — a local proxy (Surge/Clash fake-ip mode) is hijacking DNS.
  Fix: disconnect the proxy, or add a per-domain exemption (always-real-ip + [Host]/[Rule] DIRECT), then rerun"
      ;;
    "")
      die "Inference host ${host} does not resolve — no DNS record is available for it, or the network is unreachable.
  Fix: use a real public endpoint URL, or a LAN IP endpoint (192.168.x.x is trusted by the SSRF guard); then rerun"
      ;;
  esac
  log_info "Inference host ${host} resolves to ${ip}"
}

# ---- Preflight: user systemd must have the docker group ----
# Installer adds docker group after this manager started; it never picks up
# new groups. Gateway then cannot reach docker.sock. Fail fast (reboot to fix).
check_user_manager_docker_group() {
  local dgid mgr
  dgid="$(getent group docker 2>/dev/null | cut -d: -f3)"
  [ -n "$dgid" ] || return 0
  mgr="$(pgrep -u "${USER}" -x systemd 2>/dev/null | head -1)"
  [ -n "$mgr" ] || return 0
  if ! grep -qE "(^|[[:space:]])${dgid}([[:space:]]|$)" "/proc/${mgr}/status" 2>/dev/null; then
    die "User systemd manager (pid ${mgr}) lacks the docker group (gid ${dgid}).
  The docker group was added after the manager started, so systemd services (the managed
  OpenShell gateway) cannot reach /var/run/docker.sock and onboard would fail.
  Fix: reboot the machine once (or: loginctl terminate-user ${USER}, then log in again),
  then rerun ./deploy.sh — the second run skips installation and goes straight to onboard."
  fi
}

# ---- Preflight: URL, model, and API key ----
# Onboard never asks again. An empty key fails later with
# "Provider credential is required", so check here.
require_inference_config() {
  if [ -z "${INFERENCE_BASE_URL:-}" ] || [ -z "${INFERENCE_MODEL:-}" ] || [ -z "${INFERENCE_API_KEY:-}" ]; then
    die "Missing required inference config: URL/model/key must all be set.
  Wizard enforces URL and model; the API key is saved in secrets.env after the first run."
  fi
}

log_step "Step 1/5: Infrastructure (Docker + OpenShell/NemoClaw + Gateway)"

sandbox_name_valid "${SANDBOX_NAME:-}" \
  || die "Invalid sandbox name: '${SANDBOX_NAME:-}'. Allowed: 1-19 lowercase letters/digits, start with a letter, single hyphens only (e.g. je-final-test)"

NEMOCLAW_INSTALL_URL="https://www.nvidia.com/nemoclaw.sh"

# ---- Detect missing components ----
need_install=0
command -v docker >/dev/null 2>&1 || need_install=1
command -v openshell >/dev/null 2>&1 || need_install=1
command -v openshell-gateway >/dev/null 2>&1 || need_install=1
command -v openshell-sandbox >/dev/null 2>&1 || need_install=1
command -v nemoclaw >/dev/null 2>&1 || need_install=1

# ---- Pre-install prerequisites required by the official installer ----
# The NemoClaw installer needs git/curl/binutils(strings)/zstd/lsof on a fresh VM.
if [ "$need_install" = "1" ]; then
  log_info "Installing prerequisites (git curl binutils zstd lsof)..."
  sudo apt-get update -qq
  sudo apt-get install -y git curl binutils zstd lsof \
    || die "Failed to install prerequisites (git curl binutils zstd lsof)"
fi

# ---- Auto-install if docker / openshell / nemoclaw are missing ----
# Official installer does three things: Node.js, CLI/binaries, then onboard
# (gateway + sandbox). Inference settings come from the env vars below.
if [ "$need_install" = "1" ]; then
  log_info "Missing components detected, running NVIDIA official installer (agent=${AGENT})..."
  log_info "  Inference: ${INFERENCE_BASE_URL}  model=${INFERENCE_MODEL}"
  echo -e "${C_YELLOW}  (Installs Node.js + OpenShell + NemoClaw, then auto-onboards the sandbox)${C_RESET}"

  check_inference_dns
  require_inference_config

  if curl -fsSL "$NEMOCLAW_INSTALL_URL" | \
      NEMOCLAW_AGENT="${AGENT}" \
      NEMOCLAW_PROVIDER=custom \
      NEMOCLAW_ENDPOINT_URL="${INFERENCE_BASE_URL}" \
      NEMOCLAW_MODEL="${INFERENCE_MODEL}" \
      COMPATIBLE_API_KEY="${INFERENCE_API_KEY}" \
      NEMOCLAW_PREFERRED_API=openai-completions \
      bash -s -- --yes-i-accept-third-party-software; then
    log_ok "Official installer finished (binaries + onboard)"
  else
    die "Official installer failed. Run manually then retry:
      curl -fsSL ${NEMOCLAW_INSTALL_URL} | NEMOCLAW_AGENT=${AGENT} bash -s -- --yes-i-accept-third-party-software"
  fi

  # Refresh PATH: binaries may live under ~/.local/bin or nvm node bin
  export PATH="$HOME/.local/bin:$PATH"
  for nvmbin in "$HOME"/.nvm/versions/node/*/bin; do
    [ -d "$nvmbin" ] && export PATH="$nvmbin:$PATH"
  done

  # Installer may have added the user to the docker group AFTER the user
  # systemd manager started — the manager needs a reboot to pick it up.
  check_user_manager_docker_group
fi

# ---- Second check (everything should be present after install) ----
MISSING=()
for bin in docker openshell openshell-gateway openshell-sandbox nemoclaw; do
  command -v "$bin" >/dev/null 2>&1 || MISSING+=("$bin")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  die "Still missing after install: ${MISSING[*]}.
  PATH may not be refreshed. Run: source ~/.bashrc  then retry ./deploy.sh"
fi

log_ok "Docker: $(docker --version 2>/dev/null | head -1)"
log_ok "openshell: $(openshell --version 2>&1 | head -1)"
log_ok "nemoclaw: $(nemoclaw --version 2>&1 | head -1)"

# Docker daemon availability
if ! docker info >/dev/null 2>&1; then
  log_warn "docker daemon not usable by current user. If the installer just added you to the docker group, re-login:"
  log_warn "  exit and re-enter, or run: newgrp docker  then retry ./deploy.sh"
  if sg docker -c "docker info >/dev/null 2>&1" 2>/dev/null; then
    log_ok "docker usable via sg docker (this process)"
  else
    die "docker daemon not usable; run newgrp docker then retry"
  fi
fi

# ---- Onboard if the sandbox is not Ready ----
# Commands may already be installed (installer skipped) while the sandbox
# is still missing, e.g. a previous onboard failed halfway.
if ! remote "openshell -g nemoclaw sandbox list 2>/dev/null" | grep -q "${SANDBOX_NAME}.*Ready"; then
  log_info "Sandbox '${SANDBOX_NAME}' not Ready — running onboard (agent=${AGENT})..."
  check_user_manager_docker_group
  check_inference_dns
  require_inference_config
  NEMOCLAW_PROVIDER=custom \
    NEMOCLAW_ENDPOINT_URL="${INFERENCE_BASE_URL}" \
    NEMOCLAW_MODEL="${INFERENCE_MODEL}" \
    COMPATIBLE_API_KEY="${INFERENCE_API_KEY}" \
    NEMOCLAW_PREFERRED_API=openai-completions \
    nemoclaw onboard --non-interactive --fresh --agent "${AGENT}" --name "${SANDBOX_NAME}" --yes \
    || die "onboard failed. Check the inference endpoint/API key, then retry ./deploy.sh"
fi

# ---- Verify the sandbox is Ready ----
log_info "Verifying sandbox '${SANDBOX_NAME}' is Ready..."
wait_sandbox_ready || {
  log_warn "Sandbox not Ready yet. Retry ./deploy.sh (already-downloaded layers are cached)."
  exit 1
}
log_ok "Sandbox '${SANDBOX_NAME}' Ready"

log_ok "Step 1 done (binaries + Docker + sandbox onboarded). Next: ./02-hermes.sh"
