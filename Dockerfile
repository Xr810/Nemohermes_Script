# syntax=docker/dockerfile:1
#
# One-command deploy:
#   cp .env.example .env     # then set INFERENCE_API_KEY
#   docker compose up -d
#
# This file holds no secrets and no per-deployment configuration. Compose
# injects all of that from .env at container start (docker-compose.yml
# env_file), so the image is byte-identical on every machine, changing a key
# never triggers a rebuild, and nothing sensitive lands in an image layer.
# The ENV below is runtime constants only.
#
# Rebuild is needed only when the RUN layers or the entrypoint change:
#   docker compose up -d --build

FROM ubuntu:24.04

# HOME stays /root, and /root is bind-mounted from the host at the same path
# (see docker-compose.yml). Two separate constraints force exactly this:
#
#  1. NemoClaw hands absolute paths under HOME -- the guest TLS bundle, the
#     sandbox supervisor binary -- to the host Docker daemon, which resolves
#     them in the host filesystem, not in here. Behind a named volume the
#     daemon finds nothing, silently mounts an empty directory, and the sandbox
#     dies with: exec "/opt/openshell/bin/openshell-sandbox": is a directory.
#
#  2. The path cannot simply be moved somewhere neutral either. systemd carries
#     a synthesized user record for root with the home directory hardcoded to
#     /root and ignores /etc/passwd for it, so the user manager resolves %h, %E
#     and %S -- and its unit search path -- under /root no matter what HOME
#     says. Point HOME elsewhere and the gateway unit is written where systemd
#     will not look, and onboard fails step 2/8 with "service identity query
#     returned invalid metadata".
#
# So /root is the one path that host Docker, systemd and NemoClaw all agree on.
#
# NOTE: do NOT set NEMOCLAW_GATEWAY_BIND_ADDRESS=0.0.0.0 here. It looks like
# the fix for "sandbox containers cannot reach the gateway", but NemoClaw
# rejects it outright: "not supported for the OpenShell Docker-driver gateway
# while gateway JWT auth is active". The gateway is loopback-only by design.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    IN_CONTAINER=1 \
    FORWARD_BIND=0.0.0.0 \
    HERMES_API_PORT=8642 \
    HERMES_DASHBOARD_PORT=18789 \
    HOME=/root \
    PATH="/root/bin:/root/.local/bin:/usr/local/bin:${PATH}"

# ---- 01-infra.sh: host packages (NVIDIA CLI is installed at first run; it
# needs a live Docker engine, which does not exist at build time) ----
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      binutils \
      zstd \
      lsof \
      python3 \
      sudo \
      systemd \
      systemd-sysv \
      dbus \
      dbus-user-session \
      docker.io \
      docker-buildx \
      procps \
      gawk \
      openssl \
      openssh-client \
      xz-utils \
      iproute2 \
 && rm -rf /var/lib/apt/lists/* \
 && echo 'root ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/root \
 && chmod 440 /etc/sudoers.d/root

# ---- systemd as PID 1 ----
# NemoClaw starts the OpenShell gateway as a systemd *user* unit and refuses to
# attach to a gateway it cannot prove is supervised: see
# SUPPORTED_GATEWAY_SUPERVISOR_KINDS in the nemoclaw source, which accepts only
# systemd-system and systemd-user. Onboard therefore cannot complete without a
# real init. Mask the units that want hardware or a tty, and pre-enable
# lingering so root's user manager (user@0.service) starts at boot instead of
# waiting for a login that never happens in a container.
RUN systemctl mask \
      systemd-udevd.service \
      systemd-udevd-kernel.socket \
      systemd-udevd-control.socket \
      systemd-modules-load.service \
      systemd-journald-audit.socket \
      sys-kernel-config.mount \
      sys-kernel-debug.mount \
      sys-kernel-tracing.mount \
      getty.target \
      console-getty.service \
      getty@tty1.service \
      docker.service \
      docker.socket \
 && systemctl set-default multi-user.target \
 && mkdir -p /var/lib/systemd/linger \
 && touch /var/lib/systemd/linger/root

# ---- runtime: 01 onboard + 02 approvals + 04 MCP + Hermes API/dashboard ----
COPY <<'ENTRY' /usr/local/sbin/nemohermes
#!/usr/bin/env bash
set -euo pipefail

# systemd hands services a clean environment, so nothing compose put in
# `env_file` reaches this script -- those values live only in PID 1's
# environment. Read them back from there, whitelisted, before anything else
# runs. Without this the script sees no INFERENCE_API_KEY and dies in
# need_inference even though .env was correct.
if [ -r /proc/1/environ ]; then
  while IFS= read -r -d '' kv; do
    case "$kv" in
      INFERENCE_*|SANDBOX_NAME=*|APPROVALS_MODE=*|MCP_*|FORWARD_BIND=*|\
      HERMES_*|IN_CONTAINER=*|AGENT=*|ONBOARD_FRESH=*|SANDBOX_WAIT_SECS=*|\
      NEMOCLAW_*)
        export "$kv"
        ;;
    esac
  done < /proc/1/environ
fi

export HOME="${HOME:-/root}"
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
for nvmbin in "${HOME}"/.nvm/versions/node/*/bin; do
  [ -d "$nvmbin" ] && export PATH="${nvmbin}:${PATH}"
done

log() { echo "[nemohermes] $*"; }
die() { echo "[nemohermes] ERROR: $*" >&2; exit 1; }
log_warn_mcp() { echo "[nemohermes] WARN: $*" >&2; }

sandbox_name_valid() {
  local name="${1:-}"
  local n=${#name}
  [ "$n" -ge 1 ] && [ "$n" -le 19 ] || return 1
  case "$name" in *--*) return 1 ;; esac
  [[ "$name" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]
}

check_inference_dns() {
  local host ip
  host="$(printf '%s' "${INFERENCE_BASE_URL}" | sed -E 's#^[a-z][a-z0-9+.-]*://([^/:]+).*#\1#')"
  [ -n "${host}" ] || return 0
  case "${host}" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) return 0 ;;
  esac
  ip="$(getent ahostsv4 "${host}" 2>/dev/null | awk 'NR==1{print $1}')"
  case "${ip}" in
    198.18.*|198.19.*)
      die "Inference host ${host} resolves to fake-ip ${ip} (proxy fake-ip). Exempt the domain or disable the proxy."
      ;;
    "")
      die "Inference host ${host} does not resolve."
      ;;
  esac
  log "inference host ${host} -> ${ip}"
}

cid() {
  docker ps -a --filter "label=openshell.ai/sandbox-name=${SANDBOX_NAME}" --format '{{.ID}}' | awk 'NR==1{print}'
}

wait_sandbox_ready() {
  local secs="${SANDBOX_WAIT_SECS:-180}" waited=0
  log "waiting for sandbox '${SANDBOX_NAME}' Ready (max ${secs}s)"
  while [ "$waited" -lt "$secs" ]; do
    if openshell -g nemoclaw sandbox list 2>/dev/null | grep "${SANDBOX_NAME}.*Ready" >/dev/null; then
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

sync_config_hash() {
  local id="$1" new_hash
  docker cp "${id}:/sandbox/.hermes/config.yaml" /tmp/hm-config.yaml
  docker cp "${id}:/sandbox/.hermes/.config-hash" /tmp/hm-config-hash
  new_hash="$(sha256sum /tmp/hm-config.yaml | awk '{print $1}')"
  awk -v h="$new_hash" 'NR==1{print h "  /sandbox/.hermes/config.yaml"; next} {print}' \
    /tmp/hm-config-hash > /tmp/hm-config-hash.new
  docker cp /tmp/hm-config-hash.new "${id}:/sandbox/.hermes/.config-hash"
}

lan_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

write_openai_env() {
  local id="$1" key host_hint
  docker cp "${id}:/sandbox/.hermes/.env" /tmp/hermes.env
  key="$(awk -F= '/^API_SERVER_KEY=/{print substr($0, index($0,"=")+1); exit}' /tmp/hermes.env | tr -d '"' | tr -d "'")"
  [ -n "$key" ] || die "sandbox /sandbox/.hermes/.env has no API_SERVER_KEY"
  host_hint="$(lan_ip || true)"
  umask 077
  cat > "${HOME}/hermes-openai.env" <<EOF
# Point another device's Open WebUI at this (Admin → Connections → OpenAI).
# Use this machine's LAN IP, not 127.0.0.1, from the other device.
OPENAI_API_BASE_URL=http://${host_hint:-<this-host-ip>}:${HERMES_API_PORT}/v1
OPENAI_API_KEY=${key}
EOF
}

[ -z "${INFERENCE_BASE_URL:-}" ] && unset INFERENCE_BASE_URL || true
[ -z "${INFERENCE_MODEL:-}" ] && unset INFERENCE_MODEL || true
[ -z "${INFERENCE_API_KEY:-}" ] && unset INFERENCE_API_KEY || true
SANDBOX_NAME="${SANDBOX_NAME:-main}"

sandbox_name_valid "${SANDBOX_NAME}" \
  || die "invalid SANDBOX_NAME '${SANDBOX_NAME}' (1-19 lowercase letters/digits, start with a letter, single hyphens)"

need_inference() {
  [ -n "${INFERENCE_BASE_URL:-}" ] && [ -n "${INFERENCE_MODEL:-}" ] && [ -n "${INFERENCE_API_KEY:-}" ] \
    || die "Set INFERENCE_BASE_URL, INFERENCE_MODEL and INFERENCE_API_KEY in .env (cp .env.example .env), then: docker compose up -d"
}

AGENT="${AGENT:-hermes}"
APPROVALS_MODE="${APPROVALS_MODE:-manual}"
BIND="${FORWARD_BIND:-0.0.0.0}"
HERMES_API_PORT="${HERMES_API_PORT:-8642}"
HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-18789}"
LOG_DIR=/var/log
mkdir -p "$LOG_DIR" /var/run/nemohermes

# ---- gateway bind address reconciliation ----
# NemoClaw writes OPENSHELL_BIND_ADDRESS into gateway.env once, at first
# onboard, and never revisits it. That file lives in the persisted /root
# volume, so a container that was first started before this setting existed
# keeps a loopback-only gateway forever and every later onboard fails step 2/8
# with a firewall warning. Reconcile the file with the declared value and
# restart the unit when they disagree.
reconcile_gateway_bind() {
  local want="${NEMOCLAW_GATEWAY_BIND_ADDRESS:-}" f="${HOME}/.config/openshell/gateway.env" have
  [ -n "$want" ] || return 0
  [ -f "$f" ] || return 0
  have="$(awk -F= '/^OPENSHELL_BIND_ADDRESS=/{print $2; exit}' "$f")"
  [ -n "$have" ] || return 0
  [ "$have" = "$want" ] && return 0
  log "gateway bind ${have} -> ${want} (rewriting $(basename "$f"))"
  sed -i "s|^OPENSHELL_BIND_ADDRESS=.*|OPENSHELL_BIND_ADDRESS=${want}|" "$f"
  systemctl --user restart nemoclaw-openshell-gateway.service 2>/dev/null || true
  sleep 5
}

[ -S /var/run/docker.sock ] || die "mount the host Docker socket at /var/run/docker.sock"
docker info >/dev/null 2>&1 || die "host Docker engine is not usable"

# ---- systemd user manager ----
# Onboard drives the gateway through `systemctl --user`, which needs root's
# user bus to be live. Lingering is baked into the image, so user@0.service
# comes up on its own; this only waits for it and fails loudly if it does not,
# because the alternative is onboard aborting at step 2/8 with a message that
# blames systemctl rather than the missing bus.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
wait_user_manager() {
  local secs="${USER_MANAGER_WAIT_SECS:-90}" waited=0
  systemctl start user@0.service >/dev/null 2>&1 || true
  while [ "$waited" -lt "$secs" ]; do
    if systemctl --user is-system-running >/dev/null 2>&1 \
       || [ "$(systemctl --user is-system-running 2>/dev/null)" = "degraded" ]; then
      log "systemd user manager ready (XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR})"
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}
wait_user_manager || die "systemd user manager (user@0.service) never became ready; onboard cannot start the gateway. Check: systemctl status user@0.service"
reconcile_gateway_bind

# ---- sandbox -> gateway route ----
# NemoClaw pins the gateway to 127.0.0.1 and rejects an override outright
# ("NEMOCLAW_GATEWAY_BIND_ADDRESS=0.0.0.0 is not supported ... while gateway
# JWT auth is active"). Sandbox containers, though, dial it at
# host.openshell.internal, which Docker resolves to the openshell-docker bridge
# gateway address -- where a loopback-only listener never answers. Onboard
# reports that as a host firewall problem and no firewall rule can fix it.
#
# Publish loopback onto the bridge address only. Binding 0.0.0.0 would have put
# the gateway on every interface including the LAN; this exposes it to exactly
# the one subnet that has to reach it. route_localnet is what lets a DNAT
# target 127.0.0.1 from an external interface.
install_gateway_bridge_route() {
  local net="${OPENSHELL_DOCKER_NETWORK_NAME:-openshell-docker}" gwip
  gwip="$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
  [ -n "$gwip" ] || return 1
  sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true
  iptables -t nat -C PREROUTING -d "$gwip" -p tcp --dport 8080 \
    -j DNAT --to-destination 127.0.0.1:8080 2>/dev/null && return 0
  iptables -t nat -A PREROUTING -d "$gwip" -p tcp --dport 8080 \
    -j DNAT --to-destination 127.0.0.1:8080 2>/dev/null || return 1
  log "sandbox route: ${gwip}:8080 -> 127.0.0.1:8080"
}

# The bridge does not exist until the gateway creates it, which happens inside
# onboard step 2 -- moments before the probe that needs the route. Install it
# now if a previous run left the network behind, and otherwise race a watcher
# against onboard so the first run usually succeeds too. If the watcher loses,
# Restart=on-failure retries and the network is there by then.
watch_gateway_bridge_route() {
  (
    n=0
    while [ "$n" -lt 80 ]; do
      install_gateway_bridge_route && break
      sleep 2
      n=$((n + 1))
    done
  ) &
}

install_gateway_bridge_route || watch_gateway_bridge_route

# ---- stale lifecycle locks ----
# NemoClaw guards sandbox mutations with lock files under ~/.nemoclaw/state,
# recording the owner pid and PID namespace. Those live in the persisted /root
# volume, so a container that is recreated while a lock is held leaves the lock
# behind forever: every later onboard then dies with "Timed out waiting for the
# sandbox mutation lock (owner pid N)" naming a process from a container
# generation that no longer exists. NemoClaw does not reclaim them itself.
#
# Drop only locks that provably cannot be live: a different PID namespace, or a
# pid with nothing running under it. A lock whose owner is alive in this
# namespace is left alone -- removing that would let two mutations race.
clear_stale_lifecycle_locks() {
  local dir="${HOME}/.nemoclaw/state/mcp-lifecycle-locks" cur f ns pid name
  [ -d "$dir" ] || return 0
  cur="$(readlink /proc/self/ns/pid 2>/dev/null || true)"
  for f in "$dir"/*.lock; do
    [ -f "$f" ] || continue
    ns="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pidNamespaceIdentity",""))' "$f" 2>/dev/null || true)"
    pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$f" 2>/dev/null || true)"
    name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sandboxName",""))' "$f" 2>/dev/null || true)"
    if [ -n "$cur" ] && [ -n "$ns" ] && [ "$ns" != "$cur" ]; then
      log "clearing lock from a dead container generation: ${name:-?} (ns ${ns})"
    elif [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      log "clearing lock with no live owner: ${name:-?} (pid ${pid})"
    else
      continue
    fi
    rm -f "$f" "${f}.containment" "${f}".candidate-* 2>/dev/null || true
  done
}

clear_stale_lifecycle_locks

# ---- GPU passthrough ----
# Preflight already reports "Sandbox GPU: disabled (no NVIDIA GPU detected)",
# but sandbox creation still runs a Docker GPU compatibility patch. On a
# GPU-less host that patch fails, the create stream exits 1, and the sandbox is
# left in Error phase -- which then also blocks the next run as a name/agent
# conflict. Decide from the hardware rather than hardcoding either way: a real
# NVIDIA host must keep passthrough, and an explicit value in .env always wins.
if [ -z "${NEMOCLAW_SANDBOX_GPU:-}" ]; then
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q '^GPU'; then
    log "NVIDIA GPU present; leaving sandbox GPU passthrough enabled"
  else
    export NEMOCLAW_SANDBOX_GPU=0
    log "no NVIDIA GPU; setting NEMOCLAW_SANDBOX_GPU=0 to skip the Docker GPU patch"
  fi
fi

# ---- errored sandbox from a failed create ----
# A create that dies partway leaves the sandbox in Error phase, and the next
# onboard refuses it as "already exists as OpenClaw" -- a misleading message
# that has nothing to do with agent choice. An Error-phase sandbox holds no
# state worth keeping, so clear it; anything Ready or Running is left alone.
clear_errored_sandbox() {
  local row phase
  # `|| true`: the script runs under `set -o pipefail`, and openshell exits
  # non-zero whenever the gateway is not up yet. Without the guard the failing
  # pipeline propagates through the assignment and set -e kills the script here,
  # before onboard ever runs.
  row="$(openshell -g nemoclaw sandbox list 2>/dev/null | awk -v n="${SANDBOX_NAME}" '$1 == n {print}' | head -1 || true)"
  [ -n "$row" ] || return 0
  phase="$(printf '%s' "$row" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $NF}')"
  [ "$phase" = "Error" ] || return 0
  log "sandbox '${SANDBOX_NAME}' is in Error phase from a failed create; deleting it"
  openshell -g nemoclaw sandbox delete "${SANDBOX_NAME}" >/dev/null 2>&1 || true
  sleep 3
}

# ---- host-visible binaries (Docker-out-of-Docker) ----
# The gateway asks the HOST docker daemon to bind-mount the sandbox supervisor
# into every sandbox container. That path is resolved on the host, so the copy
# the installer put in this container's /usr/local/bin is invisible to it.
# Publish it under HOME, which is the one tree with an identical path on both
# sides, and tell NemoClaw to use that copy.
publish_shared_binaries() {
  local dst="${HOME}/bin" name src
  mkdir -p "$dst"
  for name in openshell-sandbox openshell-gateway; do
    src="$(command -v "$name" 2>/dev/null || true)"
    [ -n "$src" ] || continue
    case "$src" in "$dst"/*) continue ;; esac
    if [ ! -e "$dst/$name" ] || ! cmp -s "$src" "$dst/$name"; then
      install -m 755 "$src" "$dst/$name" || return 1
      log "published $name to $dst (path the host daemon can resolve)"
    fi
  done
  [ -x "$dst/openshell-sandbox" ] || return 1
  export NEMOCLAW_OPENSHELL_SANDBOX_BIN="$dst/openshell-sandbox"
}

# gateway.env is generated once and keeps whatever supervisor path was current
# then, so an existing deployment would go on handing the host an unresolvable
# path. Reconcile it the same way the bind address is reconciled.
reconcile_supervisor_bin() {
  local want="${NEMOCLAW_OPENSHELL_SANDBOX_BIN:-}" f="${HOME}/.config/openshell/gateway.env" have
  [ -n "$want" ] || return 0
  [ -f "$f" ] || return 0
  have="$(awk -F= '/^OPENSHELL_DOCKER_SUPERVISOR_BIN=/{print $2; exit}' "$f")"
  [ "$have" = "$want" ] && return 0
  log "supervisor bin ${have:-unset} -> ${want}"
  if [ -n "$have" ]; then
    sed -i "s|^OPENSHELL_DOCKER_SUPERVISOR_BIN=.*|OPENSHELL_DOCKER_SUPERVISOR_BIN=${want}|" "$f"
  else
    printf 'OPENSHELL_DOCKER_SUPERVISOR_BIN=%s\n' "$want" >> "$f"
  fi
  systemctl --user restart nemoclaw-openshell-gateway.service 2>/dev/null || true
  sleep 5
}



# Local image first; docker pull only when the ref is missing.
# Onboard also does this for the managed Hermes image (exact digest).
ensure_image() {
  local ref="$1"
  [ -n "$ref" ] || return 0
  if docker image inspect "$ref" >/dev/null 2>&1; then
    log "using local image ${ref}"
    return 0
  fi
  log "image not local, pulling ${ref}"
  docker pull "$ref" || log "pull failed for ${ref} (onboard may still resolve another candidate)"
}

ensure_sandbox_images() {
  local ref
  for ref in ghcr.io/nvidia/nemoclaw/hermes-sandbox-base:latest \
             ghcr.io/nvidia/nemoclaw/sandbox-base:latest \
             ${SANDBOX_PULL_IMAGES:-}; do
    ensure_image "$ref"
  done
}

# ---- 01: NVIDIA CLI (binaries only) + onboard (gateway creates sandbox) ----
if ! command -v nemoclaw >/dev/null || ! command -v openshell >/dev/null; then
  need_inference
  check_inference_dns
  log "installing OpenShell/NemoClaw CLI"
  curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
    NEMOCLAW_AGENT="${AGENT}" \
    NEMOCLAW_PROVIDER=custom \
    NEMOCLAW_ENDPOINT_URL="${INFERENCE_BASE_URL}" \
    NEMOCLAW_MODEL="${INFERENCE_MODEL}" \
    COMPATIBLE_API_KEY="${INFERENCE_API_KEY}" \
    NEMOCLAW_PREFERRED_API=openai-completions \
    bash -s -- --yes-i-accept-third-party-software \
    || log "installer returned non-zero; continuing if CLI is on PATH"
  export PATH="${HOME}/.local/bin:${PATH}"
  for nvmbin in "${HOME}"/.nvm/versions/node/*/bin; do
    [ -d "$nvmbin" ] && export PATH="${nvmbin}:${PATH}"
  done
fi
command -v nemoclaw >/dev/null && command -v openshell >/dev/null \
  || die "nemoclaw/openshell missing after install"

# These need the OpenShell CLI, so they run only once it is installed.
clear_errored_sandbox
publish_shared_binaries || die "could not publish openshell-sandbox to ${HOME}/bin; the host daemon cannot mount it"
reconcile_supervisor_bin

# ---- partial gateway PKI ----
# The gateway refuses to start on a half-written TLS tree ("partial PKI state
# ... some files exist but not all") and never cleans it up, so a run
# interrupted during certificate generation wedges every later start.
#
# The usual cause here is worse than a truncated write: asked to bind-mount a
# file it cannot resolve on the host, the host Docker daemon creates an empty
# DIRECTORY at that path. So ca.crt and the client/server leaves can come back
# as directories, which no amount of regeneration fixes. Move the tree aside
# (rather than delete it) whenever it is not intact and let the gateway rebuild.
clear_partial_gateway_pki() {
  local dir="${HOME}/.local/state/nemoclaw/openshell-docker-gateway/tls" f intact=1
  [ -d "$dir" ] || return 0
  for f in ca.crt server/tls.crt server/tls.key client/tls.crt client/tls.key; do
    [ -f "$dir/$f" ] || { intact=0; break; }
  done
  [ "$intact" = "1" ] && return 0
  log "gateway PKI at ${dir} is incomplete; moving it aside so the gateway regenerates"
  mv "$dir" "${dir}.broken-$(date +%s)" 2>/dev/null || true
}
clear_partial_gateway_pki

# ---- Docker-out-of-Docker debris ----
# Told to bind-mount a file that does not exist on the host, the host Docker
# daemon does not fail: it creates an empty DIRECTORY at that path. Each one
# then poisons the real file forever -- the gateway cannot write sandbox.jwt
# because a directory already occupies the path, the sandbox logs "failed to
# read sandbox token from /etc/openshell/auth/sandbox.jwt", and the phase goes
# to Error. NemoClaw never cleans these up and they persist in the shared /root
# tree, so one bad run wedges every run after it.
#
# rmdir is deliberate: it removes a path only when it is an empty directory, so
# a real key, certificate or token is never at risk.
clear_dood_debris() {
  local d n=0
  for d in $(find "${HOME}/.local/state/openshell" "${HOME}/.local/state/nemoclaw" \
               -type d \( -name '*.jwt' -o -name '*.crt' -o -name '*.key' -o -name '*.pem' \) \
               2>/dev/null); do
    rmdir "$d" 2>/dev/null && n=$((n + 1))
  done
  [ "$n" -gt 0 ] && log "removed ${n} empty directories the host daemon left in place of mount sources"
  return 0
}
clear_dood_debris

if ! openshell -g nemoclaw sandbox list 2>/dev/null | grep "${SANDBOX_NAME}.*Ready" >/dev/null; then
  need_inference
  check_inference_dns
  ensure_sandbox_images
  log "onboard: starting gateway and creating sandbox '${SANDBOX_NAME}' (local image if present, pull if missing)"
  onboard_cmd=(nemoclaw onboard --non-interactive --agent "${AGENT}" --name "${SANDBOX_NAME}" --yes)
  if [ "${ONBOARD_FRESH:-0}" = "1" ]; then
    log "ONBOARD_FRESH=1: discarding the onboard session (may re-resolve the base image)"
    onboard_cmd+=(--fresh)
  fi
  NEMOCLAW_PROVIDER=custom \
    NEMOCLAW_ENDPOINT_URL="${INFERENCE_BASE_URL}" \
    NEMOCLAW_MODEL="${INFERENCE_MODEL}" \
    COMPATIBLE_API_KEY="${INFERENCE_API_KEY}" \
    NEMOCLAW_PREFERRED_API=openai-completions \
    "${onboard_cmd[@]}" \
    || die "onboard failed"
fi
wait_sandbox_ready || die "sandbox not Ready"

CID="$(cid)"
[ -n "$CID" ] || die "sandbox container not found"

# ---- 02-hermes.sh: approvals.mode + config-hash (skip if APPROVALS_MODE empty) ----
if [ -n "${APPROVALS_MODE}" ]; then
  case "$APPROVALS_MODE" in
    off|smart|manual) ;;
    *) die "APPROVALS_MODE must be off, smart, or manual" ;;
  esac
  current="$(nemoclaw "${SANDBOX_NAME}" exec -- hermes config get approvals.mode 2>/dev/null \
    | tail -1 | tr -d "'\" " || true)"
  if [ "$current" = "$APPROVALS_MODE" ]; then
    log "approvals.mode already ${APPROVALS_MODE}"
  else
    log "setting approvals.mode=${APPROVALS_MODE}"
    docker cp "${CID}:/sandbox/.hermes/config.yaml" /tmp/hm-config.bak 2>/dev/null || true
    docker cp "${CID}:/sandbox/.hermes/.config-hash" /tmp/hm-hash.bak 2>/dev/null || true
    nemoclaw "${SANDBOX_NAME}" exec -- hermes config set approvals.mode "${APPROVALS_MODE}" \
      || die "hermes config set failed"
    sync_config_hash "$CID"
    docker restart "$CID" >/dev/null
    sleep 8
    if docker ps -a --filter "id=${CID}" --format '{{.Status}}' | grep restarting >/dev/null; then
      log "sandbox restarting after approvals change; rolling back"
      docker cp /tmp/hm-config.bak "${CID}:/sandbox/.hermes/config.yaml" 2>/dev/null || true
      docker cp /tmp/hm-hash.bak "${CID}:/sandbox/.hermes/.config-hash" 2>/dev/null || true
      docker restart "$CID" >/dev/null || true
      die "approvals change triggered config drift"
    fi
    wait_sandbox_ready || die "sandbox not Ready after approvals restart"
    CID="$(cid)"
  fi
fi

# ---- 04-mcp.sh ----
if [ -n "${MCP_URL:-}" ]; then
  [ -n "${MCP_ROUTER_TOKEN:-}" ] || die "MCP_URL is set but MCP_ROUTER_TOKEN is empty"
  if nemoclaw "${SANDBOX_NAME}" mcp list --json 2>/dev/null | grep mcp-router >/dev/null; then
    log "mcp-router already registered"
  else
    log "registering MCP router"
    export MCP_ROUTER_TOKEN
    mcp_add=(nemoclaw "${SANDBOX_NAME}" mcp add mcp-router --url "${MCP_URL}"
             --env "${MCP_ENV_VAR:-MCP_ROUTER_TOKEN}")

    # A proxy in fake-ip mode (Surge/Clash) answers every DNS query from
    # 198.18.0.0/15, so the MCP host looks like a private address and NemoClaw
    # refuses to register it. The tool's own remedy is to name the host as
    # trusted; pass it only when the address really is in that range, so a
    # genuinely private endpoint elsewhere is still rejected.
    mcp_host="$(printf '%s' "${MCP_URL}" | sed -E 's#^[a-z][a-z0-9+.-]*://([^/:]+).*#\1#')"
    mcp_ip="$(getent ahostsv4 "${mcp_host}" 2>/dev/null | awk 'NR==1{print $1}')"
    case "${mcp_ip}" in
      198.18.*|198.19.*)
        log "MCP host ${mcp_host} resolves to fake-ip ${mcp_ip}; passing --trusted-private-host"
        mcp_add+=(--trusted-private-host "${mcp_host}")
        ;;
    esac

    # Not fatal. MCP is optional, and letting a registration failure kill this
    # service would leave the Hermes API unreachable even though onboard,
    # approvals and the sandbox all succeeded.
    "${mcp_add[@]}" || log_warn_mcp "mcp add failed; continuing without the MCP router"
    unset MCP_ROUTER_TOKEN
  fi
fi

write_openai_env "$CID"

ensure() {
  local name="$1" pattern="$2"
  shift 2
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    return 0
  fi
  log "start ${name}"
  nohup setsid "$@" >>"${LOG_DIR}/${name}.log" 2>&1 &
}

# The gateway is NOT started here. Onboard registers it as a systemd user unit
# (nemoclaw-openshell-gateway.service) and NemoClaw refuses to attach to a
# listener it cannot prove that unit owns; a second copy started from this
# script is the bind conflict its source explicitly warns about.
start_all() {
  local openshell
  openshell="$(command -v openshell || true)"
  [ -n "$openshell" ] || return 1
  ensure dashboard "hermes dashboard --no-open --port 9119" \
    "$openshell" -g nemoclaw sandbox exec -n "${SANDBOX_NAME}" --no-tty -- hermes dashboard --no-open --port 9119 --skip-build
  ensure dashboard-forward "forward service ${SANDBOX_NAME} --target-port 9119" \
    "$openshell" -g nemoclaw forward service "${SANDBOX_NAME}" --target-port 9119 --local "${BIND}:${HERMES_DASHBOARD_PORT}"
  ensure api-forward "forward service ${SANDBOX_NAME} --target-port 18642" \
    "$openshell" -g nemoclaw forward service "${SANDBOX_NAME}" --target-port 18642 --local "${BIND}:${HERMES_API_PORT}"
}

log "Hermes API  http://${BIND}:${HERMES_API_PORT}/v1"
log "dashboard   http://${BIND}:${HERMES_DASHBOARD_PORT}/"
log "Open WebUI on another device: Admin → Connections → OpenAI"
log "  base URL + key: docker compose exec nemohermes cat /root/hermes-openai.env"
trap 'pkill -P $$ || true; exit 0' TERM INT
while true; do
  start_all || true
  sleep 5
done
ENTRY
RUN chmod +x /usr/local/sbin/nemohermes

# The workload runs as a system unit, not as PID 1: journal+console puts its
# output in `docker logs`, and After=user@0.service means it starts only once
# the user manager that will own the gateway is up.
COPY <<'UNIT' /etc/systemd/system/nemohermes.service
[Unit]
Description=NemoHermes bootstrap (onboard, approvals, MCP, forwards)
After=network-online.target user@0.service
Wants=network-online.target user@0.service

[Service]
Type=simple
Environment=HOME=/root
Environment=USER=root
Environment=XDG_RUNTIME_DIR=/run/user/0
ExecStart=/usr/local/sbin/nemohermes
Restart=on-failure
# Sandbox creation holds a mutation lock and can run for tens of minutes. A
# short restart interval makes the next attempt collide with the previous
# process's lock and fail with "Timed out waiting for the sandbox mutation
# lock", which looks like a NemoClaw bug but is self-inflicted.
RestartSec=90
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT
RUN systemctl enable nemohermes.service

EXPOSE 8642 18789
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/lib/systemd/systemd"]
