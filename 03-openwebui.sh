#!/usr/bin/env bash
# ============================================================
# 03-openwebui — Open WebUI install, systemd units, and filter import
#
# Usage: ./03-openwebui.sh
#
# Installs a blank database (resources/open-webui-fresh.db), so the first visit
# shows the "create admin" screen; step 3.5 polls for that account and then
# imports the filter. Re-running this step discards existing WebUI users.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
load_config

log_step "Step 3/5: Open WebUI deployment"

# Pre-flight file checks
[ -f "$OPENWEBUI_FRESH_DB" ] || die "Missing clean DB: $OPENWEBUI_FRESH_DB"
[ -f "$OPENWEBUI_START_SH" ] || die "Missing start.sh"
[ -f "$OPENWEBUI_INSTALL_SH" ] || die "Missing install.sh"
[ -f "$OPENWEBUI_FILTER_SRC" ] || die "Missing filter source: $OPENWEBUI_FILTER_SRC"
[ -f "$OPENWEBUI_FILTER_INSTALLER" ] || die "Missing filter installer: $OPENWEBUI_FILTER_INSTALLER"

wait_sandbox_ready || exit 1

# ---- 1. Upload Open WebUI files to the sandbox ----
# Sandbox cannot see host files; upload with nemoclaw first.
log_info "Uploading Open WebUI files to the sandbox..."
OPENWEBUI_DIR="/sandbox/open-webui"

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
# patch that host to tls: skip and retry once.
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
  # sh -c wraps the shell builtin `cd` (nemoclaw exec cannot run builtins directly)
  sandbox_exec "sh -c 'cd ${OPENWEBUI_DIR} && chmod +x install.sh && ./install.sh'" \
    || die "Open WebUI install failed"
fi

# Overlay company name/logo onto Open WebUI static assets (after pip so files exist).
if [ -f "${OPENWEBUI_BRAND_SH:-}" ]; then
  log_info "Applying Johnson Electric branding to Open WebUI..."
  sandbox_exec "sh -c 'chmod +x ${OPENWEBUI_DIR}/apply-webui-branding.sh && ${OPENWEBUI_DIR}/apply-webui-branding.sh'" \
    || log_warn "Branding overlay failed (UI will keep default Open WebUI assets)"
fi

# ---- 3. Place the clean DB ----
# Upload the fresh DB first, then move it into data/ inside the sandbox.
log_info "Placing clean database (first visit = create admin)..."
remote "nemoclaw ${SANDBOX_NAME} upload ${OPENWEBUI_FRESH_DB} ${OPENWEBUI_DIR}/open-webui-fresh.db" \
  || die "Failed to upload clean DB"
# sh -c keeps the whole && chain inside the sandbox (eval would split it and run
# the tail commands on the host)
sandbox_exec "sh -c 'mkdir -p ${OPENWEBUI_DIR}/data && cp ${OPENWEBUI_DIR}/open-webui-fresh.db ${OPENWEBUI_DIR}/data/webui.db && rm -f ${OPENWEBUI_DIR}/open-webui-fresh.db'" \
  || die "Failed to place webui.db"
log_ok "Clean DB in place"

# ---- 4. Place the filter source file ----
log_info "Placing filter source file..."
sandbox_exec "sh -c 'mkdir -p ${OPENWEBUI_DIR}/functions && cp ${OPENWEBUI_DIR}/hermes_source_files.py ${OPENWEBUI_DIR}/functions/hermes_source_files.py'" \
  || log_warn "Failed to place filter source (can be placed manually later)"

# ---- 5. systemd units ----
log_info "Creating systemd units (Open WebUI + forward + cleanup)..."
UNIT_DIR="${UNIT_DIR:-$HOME/.config/systemd/user}"
LIBEXEC_DIR="${LIBEXEC_DIR:-$HOME/.local/libexec}"
mkdir -p "$UNIT_DIR" "$LIBEXEC_DIR"

# cleanup script
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

# main unit
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

# forward unit (optional)
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
ExecStart=$(command -v openshell) -g nemoclaw forward service ${SANDBOX_NAME} --target-port ${WEBUI_PORT} --local 127.0.0.1:${WEBUI_LOCAL_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
fi

systemctl --user daemon-reload

# User systemd only starts at boot when lingering is on; otherwise units wait
# for a login session. enable --now without linger still helps after SSH/orb login.
if [ "$(loginctl show-user "${USER}" -p Linger --value 2>/dev/null || true)" != "yes" ]; then
  loginctl enable-linger "${USER}" 2>/dev/null \
    || sudo loginctl enable-linger "${USER}" \
    || log_warn "Could not enable lingering for ${USER}; after reboot, log in once so user systemd can start Open WebUI"
fi

# ---- 6. Enable and start ----
# enable writes the default.target.wants symlink so both units come back after
# a host reboot. --now also starts them for this deploy.
log_info "Enabling and starting Open WebUI..."
# start.sh needs exec permission (uploaded files default to 644)
sandbox_exec "chmod +x ${OPENWEBUI_DIR}/start.sh" \
  || log_warn "chmod +x start.sh failed"
# Clear any failed state from earlier runs before starting
systemctl --user reset-failed je-open-webui.service 2>/dev/null || true
systemctl --user enable --now je-open-webui.service || { log_err "Start failed"; journalctl --user -u je-open-webui.service -n 40 --no-pager; exit 1; }
sleep 5
if [ -n "${WEBUI_LOCAL_PORT:-}" ]; then
  systemctl --user enable --now je-open-webui-forward.service || log_warn "forward start failed (can retry later)"
fi

# ---- 7. Wait for admin creation + import filter ----
log_step "Step 3.5: Wait for admin creation and import filter"

URL="http://127.0.0.1:${WEBUI_LOCAL_PORT:-3000}"
log_info "Open in your browser: ${URL}"
log_info "First visit shows the 'create admin' page. The script continues automatically once created (up to ${ADMIN_WAIT_SECS}s)..."

waited=0
while [ "$waited" -lt "${ADMIN_WAIT_SECS}" ]; do
  if sandbox_exec "python3 -c \"
import sqlite3
c = sqlite3.connect('file:${OPENWEBUI_DIR}/data/webui.db?mode=ro', uri=True)
r = c.execute(\\\"SELECT COUNT(*) FROM user WHERE role='admin'\\\").fetchone()[0]
print(r)
\"" 2>/dev/null | grep -q "^[1-9]"; then
    log_ok "Admin creation detected"
    break
  fi
  sleep 5
  waited=$((waited + 5))
done

FILTER_INSTALL_CMD="${OPENWEBUI_DIR}/.venv/bin/python ${OPENWEBUI_DIR}/install-hermes-source-filter.py --source ${OPENWEBUI_DIR}/functions/hermes_source_files.py"
if [ "$waited" -ge "${ADMIN_WAIT_SECS}" ]; then
  log_warn "Timed out waiting, no admin detected. You can run the filter install manually later:"
  log_warn "  After ./04-mcp.sh, run: nemoclaw ${SANDBOX_NAME} exec -- ${FILTER_INSTALL_CMD}"
else
  log_info "Importing filter (hermes_source_files v1.3.3)..."
  # Must run under the Open WebUI venv python: the installer imports `jwt`,
  # which is NOT in the sandbox system python3 (3.13), but IS in the venv
  # (pyjwt is an open-webui dependency).
  sandbox_exec "sh -c 'cd ${OPENWEBUI_DIR} && chmod +x install-hermes-source-filter.py && ${OPENWEBUI_DIR}/.venv/bin/python install-hermes-source-filter.py --source ${OPENWEBUI_DIR}/functions/hermes_source_files.py'" \
    && log_ok "filter imported (active + global)" \
    || log_warn "filter import failed, rerun the above command manually later"
fi

log_ok "Step 3 done. Next: ./04-mcp.sh"
