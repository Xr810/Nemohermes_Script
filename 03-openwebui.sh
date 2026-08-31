#!/usr/bin/env bash
# ============================================================
# 03-openwebui — Open WebUI install, branding, systemd units, and filter import
#
# Usage: ./03-openwebui.sh
#
# Opt-in via ./deploy.sh 03. Open WebUI is installed inside the sandbox so uploads
# land on the same disk Hermes reads.
#
# Headless: WEBUI_ADMIN_EMAIL + WEBUI_ADMIN_PASSWORD create the first admin on
# startup (Open WebUI 0.9.5). Without those, the first visit is still the
# browser "create admin" page. Re-running does not discard an existing admin
# or chat history; delete webui.db yourself to reset.
#
# Branding (company icon/logo overlay) runs after pip so the static assets it
# overwrites already exist; it is best-effort and never fails the step.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
load_config

log_step "Step 3/5: Open WebUI deployment"

OPENWEBUI_DIR="/sandbox/open-webui"

[ -f "$OPENWEBUI_START_SH" ] || die "Missing start.sh"
[ -f "$OPENWEBUI_INSTALL_SH" ] || die "Missing install.sh"
[ -f "$OPENWEBUI_FILTER_SRC" ] || die "Missing filter source: $OPENWEBUI_FILTER_SRC"
[ -f "$OPENWEBUI_FILTER_INSTALLER" ] || die "Missing filter installer: $OPENWEBUI_FILTER_INSTALLER"

HEADLESS=0
if [ -n "${WEBUI_ADMIN_EMAIL:-}" ] && [ -n "${WEBUI_ADMIN_PASSWORD:-}" ]; then
  HEADLESS=1
fi

wait_sandbox_ready || exit 1

# Open WebUI listens on sandbox loopback; the host reaches it through the forward
# unit, while the filter installer stays on loopback. Probe HTTP rather than
# trusting systemd: an "active" unit may still be binding, or already dead after
# the database underneath it was replaced.
# The port is hardcoded in resources/start.sh — see the WEBUI_PORT note in
# config.env before changing it here.
wait_webui_listen() {
  local secs="${1:-90}" waited=0
  local port="${WEBUI_PORT:-3000}"
  log_info "Waiting for Open WebUI HTTP on 127.0.0.1:${port} (max ${secs}s)..."
  while [ "$waited" -lt "$secs" ]; do
    if sandbox_exec "python3 -c \"
import os, urllib.request
for k in ('HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy','ALL_PROXY','all_proxy'):
    os.environ.pop(k, None)
urllib.request.urlopen('http://127.0.0.1:${port}/static/loader.js', timeout=3)
print('200')
\"" 2>/dev/null | grep -q '200'; then
      log_ok "Open WebUI is listening"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  log_err "Open WebUI did not listen within ${secs}s"
  return 1
}

webui_sql_count() {
  local sql="$1"
  sandbox_exec "python3 -c \"
import os, sqlite3
p = '${OPENWEBUI_DIR}/data/webui.db'
if not os.path.isfile(p):
    print(0)
    raise SystemExit
c = sqlite3.connect('file:' + p + '?mode=ro', uri=True)
try:
    print(c.execute(\\\"${sql}\\\").fetchone()[0])
except Exception:
    print(0)
\"" 2>/dev/null | tr -d '[:space:]' || echo 0
}

# ---- 1. Upload Open WebUI files to the sandbox ----
# Sandbox cannot see host files; upload with nemoclaw first.
log_info "Uploading Open WebUI files to the sandbox..."

for f in "$OPENWEBUI_START_SH" "$OPENWEBUI_INSTALL_SH" "$OPENWEBUI_PDF_TOOL" \
         "$OPENWEBUI_FILTER_SRC" "$OPENWEBUI_FILTER_INSTALLER" \
         ${OPENWEBUI_BRAND_ICON:+"$OPENWEBUI_BRAND_ICON"} \
         ${OPENWEBUI_BRAND_LOGO:+"$OPENWEBUI_BRAND_LOGO"} \
         ${OPENWEBUI_BRAND_SH:+"$OPENWEBUI_BRAND_SH"}; do
  [ -f "$f" ] || continue
  remote "nemoclaw ${SANDBOX_NAME} upload ${f} ${OPENWEBUI_DIR}/" \
    || log_warn "Upload of ${f} failed (continuing)"
done

# ---- 2. Install (venv + dependencies) ----
# install.sh needs GitHub (uv/Python) and PyPI. Built-in github preset only
# allows git, so add resources/openwebui-install-policy.yaml plus pypi.
# If policy add hits endpoint ambiguity (tls mismatch with brew etc.),
# patch that host to tls: skip and retry once. A failure is deliberately
# repeated with output captured, because only the error text names the
# conflicting host.
apply_openwebui_policy() {
  local out host
  if remote "nemoclaw ${SANDBOX_NAME} policy add --from-file ${POLICY_FILE} --yes" >/dev/null 2>&1; then
    return 0
  fi
  out="$(remote "nemoclaw ${SANDBOX_NAME} policy add --from-file ${POLICY_FILE} --yes" 2>&1)"
  if ! printf '%s' "$out" | grep -q "endpoint ambiguity validation failed"; then
    return 1
  fi
  host="$(printf '%s' "$out" | grep -oE "\([a-zA-Z0-9.-]+:[0-9]+\)" | head -1 | tr -d '()' | cut -d: -f1)"
  [ -n "$host" ] || return 1
  log_warn "policy conflict on ${host} (tls metadata vs applied preset) — patching with tls: skip and retrying"
  if ! awk -v h="$host" '
      $0 ~ "- host: " h { mark=1 }
      mark && $0 ~ /port:/ && !done { print; print "        tls: skip"; done=1; next }
      { print }
    ' "$POLICY_FILE" > "$POLICY_FILE.tmp"; then
    return 1
  fi
  mv "$POLICY_FILE.tmp" "$POLICY_FILE"
  remote "nemoclaw ${SANDBOX_NAME} policy add --from-file ${POLICY_FILE} --yes" >/dev/null 2>&1
}

log_info "Adding network policies for the Open WebUI install..."
POLICY_FILE="${SCRIPT_DIR}/resources/openwebui-install-policy.yaml"
if [ -f "$POLICY_FILE" ]; then
  apply_openwebui_policy \
    || log_warn "custom uv policy add failed (install may fail without GitHub access)"
else
  log_warn "Missing ${POLICY_FILE} — uv may be blocked from GitHub"
fi
remote "nemoclaw ${SANDBOX_NAME} policy add pypi --yes" \
  || log_warn "pypi policy add failed (install may fail without PyPI access)"

log_info "Running install.sh (create venv, install Open WebUI 0.9.5 + pypdfium2)..."
if sandbox_exec "test -x ${OPENWEBUI_DIR}/.venv/bin/open-webui" 2>/dev/null; then
  log_ok "Open WebUI already installed, skipping install"
else
  # sh -c wraps the shell builtin `cd`; nemoclaw exec cannot run builtins
  sandbox_exec "sh -c 'cd ${OPENWEBUI_DIR} && chmod +x install.sh && ./install.sh'" \
    || die "Open WebUI install failed"
fi

# Overlay the company icon/logo onto Open WebUI's static assets (favicons,
# splash, avatars). The displayed product name is separate — it comes from
# WEBUI_NAME in resources/start.sh.
if [ -f "${OPENWEBUI_BRAND_SH:-}" ]; then
  log_info "Applying Johnson Electric branding to Open WebUI..."
  sandbox_exec "sh -c 'chmod +x ${OPENWEBUI_DIR}/apply-webui-branding.sh && ${OPENWEBUI_DIR}/apply-webui-branding.sh'" \
    || log_warn "Branding overlay failed (UI will keep default Open WebUI assets)"
fi

# ---- 3. Place the clean DB only when no users exist ----
# Upload into the directory (trailing slash). A dest named *.db is treated as a
# folder by nemoclaw upload, so the file would land at *.db/*.db and cp fails.
EXISTING_USERS="$(webui_sql_count "SELECT COUNT(*) FROM user")"
case "${EXISTING_USERS}" in
  ''|*[!0-9]*) EXISTING_USERS=0 ;;
esac
if [ "${EXISTING_USERS}" -ge 1 ]; then
  log_ok "Keeping existing webui.db (${EXISTING_USERS} user(s))"
elif [ -f "${OPENWEBUI_FRESH_DB:-}" ]; then
  log_info "Placing clean database (no users yet)..."
  sandbox_exec "rm -rf ${OPENWEBUI_DIR}/open-webui-fresh.db" \
    || log_warn "Could not remove leftover ${OPENWEBUI_DIR}/open-webui-fresh.db"
  remote "nemoclaw ${SANDBOX_NAME} upload ${OPENWEBUI_FRESH_DB} ${OPENWEBUI_DIR}/" \
    || die "Failed to upload clean DB"
  # Drop leftover WAL/SHM first: otherwise SQLite can merge the blank file with
  # a previous admin row.
  sandbox_exec "sh -c 'mkdir -p ${OPENWEBUI_DIR}/data && rm -f ${OPENWEBUI_DIR}/data/webui.db-wal ${OPENWEBUI_DIR}/data/webui.db-shm && cp ${OPENWEBUI_DIR}/open-webui-fresh.db ${OPENWEBUI_DIR}/data/webui.db && rm -f ${OPENWEBUI_DIR}/open-webui-fresh.db'" \
    || die "Failed to place webui.db"
  log_ok "Clean DB in place"
else
  log_info "No fresh DB snapshot; Open WebUI will create the schema on first start"
  sandbox_exec "mkdir -p ${OPENWEBUI_DIR}/data" \
    || log_warn "Could not create ${OPENWEBUI_DIR}/data"
fi

# ---- 3b. Headless admin credentials for first boot ----
EXISTING_ADMIN="$(webui_sql_count "SELECT COUNT(*) FROM user WHERE role='admin'")"
case "${EXISTING_ADMIN}" in
  ''|*[!0-9]*) EXISTING_ADMIN=0 ;;
esac
if [ "$HEADLESS" = "1" ] && [ "${EXISTING_ADMIN}" -lt 1 ]; then
  log_info "Writing headless admin credentials for first Open WebUI start..."
  ADMIN_TMP_DIR="$(mktemp -d)"
  umask 077
  TMP_ADMIN_ENV="${ADMIN_TMP_DIR}/.admin.env"
  export TMP_ADMIN_ENV WEBUI_ADMIN_EMAIL WEBUI_ADMIN_PASSWORD
  export WEBUI_ADMIN_NAME="${WEBUI_ADMIN_NAME:-Admin}"
  python3 -c '
import os, shlex
from pathlib import Path
lines = []
for key in ("WEBUI_ADMIN_EMAIL", "WEBUI_ADMIN_PASSWORD", "WEBUI_ADMIN_NAME"):
    value = os.environ.get(key, "")
    if key == "WEBUI_ADMIN_NAME" and not value:
        value = "Admin"
    if value:
        lines.append(f"{key}={shlex.quote(value)}")
Path(os.environ["TMP_ADMIN_ENV"]).write_text("\n".join(lines) + "\n", encoding="utf-8")
'
  chmod 600 "$TMP_ADMIN_ENV"
  remote "nemoclaw ${SANDBOX_NAME} upload ${TMP_ADMIN_ENV} ${OPENWEBUI_DIR}/" \
    || die "Failed to upload .admin.env"
  sandbox_exec "chmod 600 ${OPENWEBUI_DIR}/.admin.env" \
    || log_warn "chmod 600 .admin.env failed"
  rm -rf "$ADMIN_TMP_DIR"
fi

# ---- 4. Place the filter source file ----
log_info "Placing filter source file..."
sandbox_exec "sh -c 'mkdir -p ${OPENWEBUI_DIR}/functions && cp ${OPENWEBUI_DIR}/hermes_source_files.py ${OPENWEBUI_DIR}/functions/hermes_source_files.py'" \
  || log_warn "Failed to place filter source (can be placed manually later)"

# ---- 5. Cleanup helper + start Open WebUI ----
LIBEXEC_DIR="${LIBEXEC_DIR:-$HOME/.local/libexec}"
mkdir -p "$LIBEXEC_DIR"
BIND_ADDR="$(forward_bind_addr)"
log_info "Creating systemd units (Open WebUI + forwards + Hermes + cleanup)..."
UNIT_DIR="${UNIT_DIR:-$HOME/.config/systemd/user}"
mkdir -p "$UNIT_DIR"

# ---- 5a. Cleanup helper ----
# Unquoted heredoc: $(command -v openshell), ${SANDBOX_NAME} and ${WEBUI_PORT}
# are baked in now, on the host; every \$ is escaped so it survives into the
# generated script and is expanded when systemd runs it.
cat > "$LIBEXEC_DIR/je-open-webui-cleanup" <<EOF
#!/bin/sh
set -eu
OPENSHELL=$(command -v openshell)
SANDBOX=${SANDBOX_NAME}
PROCESS_PATTERN='^/sandbox/open-webui/.venv/bin/python /sandbox/open-webui/.venv/bin/open-webui serve --host 127.0.0.1 --port ${WEBUI_PORT}\$'
if [ "\${1:-}" = '--stop-main' ] && [ -n "\${MAINPID:-}" ]; then
  kill -TERM "\$MAINPID" 2>/dev/null || true
fi
"\$OPENSHELL" -g nemoclaw sandbox exec -n "\$SANDBOX" --no-tty -- \
  /usr/bin/pkill -TERM -f "\$PROCESS_PATTERN" 2>/dev/null || true
i=0
while [ "\$i" -lt 10 ]; do
  if ! "\$OPENSHELL" -g nemoclaw sandbox exec -n "\$SANDBOX" --no-tty -- \
    /usr/bin/pgrep -f "\$PROCESS_PATTERN" >/dev/null 2>&1; then
    exit 0
  fi
  i=\$((i + 1)); sleep 1
done
echo 'Open WebUI process still present after cleanup timeout.' >&2
exit 1
EOF
chmod +x "$LIBEXEC_DIR/je-open-webui-cleanup"

webui_already_up=0
if sandbox_exec "python3 -c \"
import os, urllib.request
for k in ('HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy','ALL_PROXY','all_proxy'):
    os.environ.pop(k, None)
urllib.request.urlopen('http://127.0.0.1:${WEBUI_PORT:-3000}/static/loader.js', timeout=3)
print('200')
\"" 2>/dev/null | grep -q '200'; then
  webui_already_up=1
fi

# ---- 5b. Open WebUI unit ----
cat > "$UNIT_DIR/je-open-webui.service" <<EOF
[Unit]
Description=Open WebUI inside the OpenShell sandbox
After=nemoclaw-openshell-gateway.service network-online.target
Requires=nemoclaw-openshell-gateway.service
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
Type=simple
ExecStartPre=$LIBEXEC_DIR/je-open-webui-cleanup
ExecStart=$(command -v openshell) -g nemoclaw sandbox exec -n ${SANDBOX_NAME} --no-tty -- /sandbox/open-webui/start.sh
ExecStop=$LIBEXEC_DIR/je-open-webui-cleanup --stop-main
Restart=on-failure
RestartSec=10
TimeoutStopSec=20

[Install]
WantedBy=default.target
EOF

# ---- 5c. Open WebUI forward unit (skipped when WEBUI_LOCAL_PORT is empty) ----
if [ -n "${WEBUI_LOCAL_PORT:-}" ]; then
  cat > "$UNIT_DIR/je-open-webui-forward.service" <<EOF
[Unit]
Description=Forward Open WebUI to localhost
After=je-open-webui.service nemoclaw-openshell-gateway.service
Requires=nemoclaw-openshell-gateway.service
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
Type=simple
ExecStart=$(command -v openshell) -g nemoclaw forward service ${SANDBOX_NAME} --target-port ${WEBUI_PORT} --local ${BIND_ADDR}:${WEBUI_LOCAL_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
fi

# ---- 5d. Gateway ordering cycle + Hermes dashboard/API units ----
# Same units step 1 installs (lib.sh install_hermes_host_forwards): it also
# strips After=default.target from the gateway unit, which would otherwise form
# an ordering cycle with the WantedBy=default.target units written above and
# make systemd drop the Open WebUI start job on boot. Re-run after a gateway
# upgrade. Kept as one implementation so the ports cannot drift between steps.
install_hermes_host_forwards

systemctl --user daemon-reload

# User systemd only starts at boot when lingering is on; otherwise units wait
# for a login session. enable --now without linger still helps after an
# SSH/orb login.
if [ "$(loginctl show-user "${USER}" -p Linger --value 2>/dev/null || true)" != "yes" ]; then
  loginctl enable-linger "${USER}" 2>/dev/null \
    || sudo loginctl enable-linger "${USER}" \
    || log_warn "Could not enable lingering for ${USER}; after reboot, log in once so user systemd can start Open WebUI"
fi

# ---- 6. Enable and start ----
# enable writes the default.target.wants symlink so the units come back after a
# host reboot. Restart only when WebUI is down, or when a headless first boot
# needs to pick up .admin.env; otherwise keep an existing admin session.
log_info "Enabling Open WebUI..."
sandbox_exec "chmod +x ${OPENWEBUI_DIR}/start.sh" \
  || log_warn "chmod +x start.sh failed"
systemctl --user reset-failed je-open-webui.service 2>/dev/null || true
systemctl --user enable je-open-webui.service \
  || log_warn "enable je-open-webui failed (continuing with start)"
need_webui_restart=0
if [ "$webui_already_up" != "1" ]; then
  need_webui_restart=1
elif [ "$HEADLESS" = "1" ] && [ "${EXISTING_ADMIN}" -lt 1 ]; then
  need_webui_restart=1
fi
if [ "$need_webui_restart" = "1" ]; then
  systemctl --user restart je-open-webui.service \
    || { log_err "Start failed"; journalctl --user -u je-open-webui.service -n 40 --no-pager; exit 1; }
else
  log_ok "Open WebUI already listening; not restarting"
fi
if [ -n "${WEBUI_LOCAL_PORT:-}" ]; then
  systemctl --user reset-failed je-open-webui-forward.service 2>/dev/null || true
  systemctl --user enable je-open-webui-forward.service \
    || log_warn "enable je-open-webui-forward failed (continuing with restart)"
  if ! systemctl --user is-active --quiet je-open-webui-forward.service 2>/dev/null; then
    systemctl --user restart je-open-webui-forward.service \
      || log_warn "forward start failed (can retry later)"
  fi
fi
wait_webui_listen 90 \
  || { journalctl --user -u je-open-webui.service -n 40 --no-pager; exit 1; }
# The je-hermes-* units were enabled by install_hermes_host_forwards above.

# ---- 7. Wait for admin creation + import filter ----
log_step "Step 3.5: Wait for admin creation and import filter"

URL="http://127.0.0.1:${WEBUI_LOCAL_PORT:-3000}"
FILTER_INSTALL_CMD="${OPENWEBUI_DIR}/.venv/bin/python ${OPENWEBUI_DIR}/install-hermes-source-filter.py --source ${OPENWEBUI_DIR}/functions/hermes_source_files.py"

admin_present() {
  local n
  n="$(webui_sql_count "SELECT COUNT(*) FROM user WHERE role='admin'")"
  case "$n" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$n" -ge 1 ]
}

if admin_present; then
  log_ok "Admin already present"
else
  if [ "$HEADLESS" = "1" ]; then
    ADMIN_POLL_SECS=90
    log_info "Headless admin: waiting for Open WebUI to create ${WEBUI_ADMIN_EMAIL} (max ${ADMIN_POLL_SECS}s)..."
  else
    ADMIN_POLL_SECS="${ADMIN_WAIT_SECS}"
    WAIT_MIN=$((ADMIN_POLL_SECS / 60))
    log_info "Open in your browser: ${URL}"
    log_info "First visit shows the 'create admin' page. The script continues automatically once created (up to ${WAIT_MIN} min)..."
  fi
  waited=0
  while [ "$waited" -lt "${ADMIN_POLL_SECS}" ]; do
    if admin_present; then
      log_ok "Admin creation detected"
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done
  if [ "$waited" -ge "${ADMIN_POLL_SECS}" ] && ! admin_present; then
    if [ "$HEADLESS" = "1" ]; then
      log_err "Headless admin was not created within ${ADMIN_POLL_SECS}s"
      exit 1
    fi
    log_warn "Timed out waiting, no admin detected. You can run the filter install manually later:"
    log_warn "  After ./04-mcp.sh, run: nemoclaw ${SANDBOX_NAME} exec -- ${FILTER_INSTALL_CMD}"
    log_ok "Step 3 done. Next: ./04-mcp.sh"
    exit 0
  fi
fi

wait_webui_listen 90 \
  || { log_err "Open WebUI went away after admin creation; not importing filter"; exit 1; }
log_info "Importing filter (hermes_source_files v1.4.0)..."
# Must run under the Open WebUI venv python: the installer imports `jwt`,
# which is NOT in the sandbox system python3 (3.13), but IS in the venv
# (pyjwt is an open-webui dependency).
FILTER_OK=0
attempt=1
while [ "$attempt" -le 10 ]; do
  if sandbox_exec "sh -c 'cd ${OPENWEBUI_DIR} && chmod +x install-hermes-source-filter.py && env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy ${OPENWEBUI_DIR}/.venv/bin/python install-hermes-source-filter.py --source ${OPENWEBUI_DIR}/functions/hermes_source_files.py'"; then
    FILTER_OK=1
    break
  fi
  log_warn "filter import attempt ${attempt}/10 failed, retrying in 3s..."
  sleep 3
  attempt=$((attempt + 1))
done
if [ "$FILTER_OK" = "1" ]; then
  log_ok "filter imported (active + global)"
  sandbox_exec "rm -f ${OPENWEBUI_DIR}/.admin.env" \
    || true
else
  log_err "filter import failed after 10 attempts. Retry: nemoclaw ${SANDBOX_NAME} exec -- ${FILTER_INSTALL_CMD}"
  exit 1
fi

log_ok "Step 3 done. Next: ./04-mcp.sh"
