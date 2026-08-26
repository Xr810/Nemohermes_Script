# Operations Guide

Day-two operations for a deployment created by `docker compose up` or
`./deploy.sh` (installation is covered in the [README](README.md)): changing the
model or provider, managing MCP servers, and reading logs. Docker does not
install Open WebUI; connect a remote Open WebUI to the Hermes API instead.

**The OpenShell gateway is the source of truth.** Hermes inside the sandbox only
executes what the gateway hands it. Change configuration through
`openshell` / `nemoclaw` on the host, not by editing files inside the sandbox —
gateway updates overwrite sandbox-side edits, and edits to Hermes `config.yaml`
break the integrity anchor (see [Approval mode](#approval-mode)).

## Conventions

All commands run **on the deployment host** (the machine where you ran
`./deploy.sh`), as the deploying user. `<sandbox>` is your `SANDBOX_NAME` from
`config.env`.

```bash
cd ~/deploy && . config.env && echo "$SANDBOX_NAME"
```

Inside the compose container the same commands work after:

```bash
docker compose exec nemohermes bash
```

If the host is a VM and you are working from outside it, prefix commands with
your VM runner — for example `orbctl run -m <vm> …` for OrbStack — or simply SSH
in first.

## Architecture

```text
Open WebUI on another device
  → http://<this-host-ip>:8642/v1     (openshell forward → sandbox 18642)
    → Hermes API server in the sandbox
      → OpenShell gateway inference layer
        → provider (OpenAI-compatible endpoint) → model
```

Ubuntu `./deploy.sh` step 3 can still put Open WebUI in the sandbox on
`127.0.0.1:3000`. The Docker image skips that and only publishes the Hermes API
and dashboard.

| Concern | Where you change it |
|---|---|
| Provider and model | `openshell provider …` / `openshell inference …` |
| MCP over HTTPS | `nemoclaw <sandbox> mcp …` |
| MCP over local stdio | `hermes mcp …` inside the sandbox (the gateway has no local-process transport) |
| Approval mode | `./deploy.sh 02` |
| Open WebUI process | `systemctl --user … je-open-webui` |
| Upload handling | The `hermes_source_files` filter; see [Upload handling](#upload-handling) |
| Company name and artwork | `resources/start.sh` and the branding assets; see [Branding](#branding) |

Open WebUI shows a single Hermes agent model. Its base URL points at the Hermes
API server, not at your provider, so **switching models is a gateway change, not
an Open WebUI setting**.

## Consoles and endpoints

The OpenShell gateway is a host process with no web interface; its console is a
TUI. Hermes ships a browser dashboard of its own, separate from Open WebUI.

| Surface | Open it | Use it for |
|---|---|---|
| Open WebUI | Ubuntu step 3: `http://127.0.0.1:3000`. Docker: a remote WebUI pointed at the Hermes API | Chat UI (not in the compose image) |
| Hermes dashboard | `http://<host>:18789/` (Docker) or `http://127.0.0.1:18789/` (Ubuntu) | Agent sessions, skills, approvals |
| Hermes API | `http://<host>:8642/v1` | OpenAI-compatible access for a remote Open WebUI; health at `/health` |
| OpenShell TUI | `openshell term` | Sandboxes, providers, live egress and network approvals |
| Hermes TUI | `nemoclaw <sandbox> exec -- hermes dashboard --tui` | The dashboard without a browser |

Onboard publishes `18789` and `8642` on the host, but those forwards die with the
gateway, so step 3 recreates all three host ports as systemd user units instead
(see [Service management](#service-management)). Inside the sandbox the dashboard
binds `9119` and the API binds `18642`, which are not reachable as host
addresses. `FORWARD_PORTS` in `config.env` is unused.

```bash
openshell -g nemoclaw forward list   # confirm 3000 / 8642 / 18789
```

`openshell term` is keyboard-driven; `q` quits. Docker already binds the Hermes
API on `0.0.0.0:8642`. On Ubuntu, to reach loopback ports from another machine,
forward `8642` and `18789` over SSH.

## Service management

On a Ubuntu host these user units are written and lingering is enabled, so they
all come back after a host reboot once the gateway is up.

| Unit | Written by | Role |
|---|---|---|
| `je-hermes-dashboard.service` | step 1 | `hermes dashboard` on sandbox port `9119` |
| `je-hermes-dashboard-forward.service` | step 1 | Host `HERMES_DASHBOARD_PORT` (`18789`) → the dashboard |
| `je-hermes-api-forward.service` | step 1 | Host `HERMES_API_PORT` (`8642`) → the Hermes API on `18642` |
| `je-open-webui.service` | step 3 | Open WebUI in the sandbox, via `start.sh` |
| `je-open-webui-forward.service` | step 3 | Host `3000` → Open WebUI; skipped when `WEBUI_LOCAL_PORT` is empty |

Step 3 is opt-in (`./deploy.sh 03`), so a default run leaves only the three
Hermes units. Both steps go through the same `install_hermes_host_forwards` in
`lib.sh`, so re-running step 3 rewrites the Hermes units with the same ports
rather than drifting from step 1.

The two Open WebUI units are enabled and then *restarted*, not started with
`enable --now`, so that re-running step 3 actually picks up the blank database it
just placed; the three Hermes units use `enable --now`.

```bash
systemctl --user status  je-open-webui.service
systemctl --user restart je-open-webui.service
systemctl --user restart je-open-webui-forward.service   # only the local port forward
systemctl --user restart je-hermes-dashboard.service je-hermes-dashboard-forward.service
journalctl --user -u je-open-webui -n 50 --no-pager
```

`je-open-webui.service` runs `start.sh` inside the sandbox and depends on
`nemoclaw-openshell-gateway.service`. Stop and `ExecStartPre` both run
`~/.local/libexec/je-open-webui-cleanup`, which kills any leftover Open WebUI
process in the sandbox so a restart cannot end up with two servers on the same
port.

If the page will not load, check the forward unit first — the app is usually
running and only the tunnel died.

**Compose image:** no Open WebUI. The wrapper runs an inner dockerd (no host
socket, no host-network mode). Onboard starts the OpenShell gateway, which
creates the sandbox inside that engine, then forwards Hermes API `:8642` and
dashboard `:18789` via published ports. Restart with `docker compose restart`.
List sandboxes with `docker compose exec nemohermes docker ps`. Connection file:

```bash
docker compose exec nemohermes cat /root/hermes-openai.env
```

## Provider and model

Inspect the current state before changing anything:

```bash
openshell inference get           # active provider + model
openshell provider list           # registered providers
openshell provider list-profiles  # built-in provider profiles
```

Switch model within the same provider (the common case):

```bash
openshell inference set --provider <provider> --model <model>
# optional: --timeout <seconds>, --no-verify to skip validation
```

Rotate a key or change the endpoint:

```bash
openshell provider update <provider> \
  --credential <KEY>=<new-value> \
  --config <KEY>=<new-value>
# expiring credentials: --credential-expires-at <KEY>=<timestamp>
```

Add a provider:

```bash
openshell provider list-profiles                # pick a built-in profile
openshell provider profile import <file-or-dir> # or import a custom profile
openshell provider update <provider> --credential KEY=VALUE --config KEY=VALUE
openshell inference set --provider <provider> --model <model>
```

Remove one with `openshell provider delete <provider>`.

Changes take effect on the next request, so send a message to confirm. If the
sandbox still behaves as before, restart the gateway:

```bash
systemctl --user restart nemoclaw-openshell-gateway.service
```

## MCP servers

### Gateway-managed (HTTPS)

This is the path `04-mcp.sh` uses. The URL must be public HTTPS.

```bash
nemoclaw <sandbox> mcp add <name> --url https://<host>/mcp --env <KEY>
nemoclaw <sandbox> mcp list
nemoclaw <sandbox> mcp status <name> --probe   # credential resolution
nemoclaw <sandbox> mcp status <name> --tools   # tool discovery
nemoclaw <sandbox> mcp remove <name>
```

`--env <KEY>` names a credential registered with OpenShell; it is not the token
itself. The sandbox only ever sees an `openshell:resolve:env:<KEY>` placeholder,
which the gateway resolves on egress while enforcing the MCP policy. The
deployment registers this server as `mcp-router`.

To add the router after the fact on an Ubuntu host, set `MCP_URL` in
`config.env`, export the token, and re-run the step:

```bash
export MCP_ROUTER_TOKEN='...'
./deploy.sh 04
```

On the compose image, set `MCP_URL` and `MCP_ROUTER_TOKEN` in `.env` and
recreate the container — the entrypoint registers the router on start and skips
it when it is already present:

```bash
docker compose up -d
```

### Local stdio

Local process MCP servers bypass the gateway and are configured inside the
sandbox:

```bash
nemoclaw <sandbox> exec -- hermes mcp add <name> \
  --command npx --args -y @modelcontextprotocol/server-filesystem /sandbox/data
nemoclaw <sandbox> exec -- hermes mcp list
nemoclaw <sandbox> exec -- hermes mcp test <name>
nemoclaw <sandbox> exec -- hermes mcp remove <name>
```

`hermes mcp` maintains its own state alongside the config anchor, so these
commands are safe — unlike hand-editing `config.yaml`. New servers apply from
the next agent request.

## Approval mode

Use the deployment step rather than changing it by hand:

```bash
# Ubuntu: edit APPROVALS_MODE in config.env to off | smart | manual
./deploy.sh 02

# Docker: edit APPROVALS_MODE in .env, then
docker compose up -d
```

NemoClaw pins the SHA-256 of `/sandbox/.hermes/config.yaml` in
`/sandbox/.hermes/.config-hash`. Writing the config without updating that anchor
makes the container fail with `HERMES_MCP_CONFIG_DRIFT` and restart in a loop.
Step 2 does the whole sequence: back up config and anchor, set the mode, rewrite
the anchor, restart, verify, and roll back if the container comes up unhealthy.

Check the current value at any time:

```bash
nemoclaw <sandbox> exec -- hermes config get approvals.mode
```

## Upload handling

The `hermes_source_files` filter passes files attached directly to a chat to
Hermes whole, through an ephemeral copy, instead of chunking them for retrieval.
Knowledge collections are untouched and still go through RAG. Three files in
`/sandbox/open-webui/` are involved:

| File | Role |
|---|---|
| `functions/hermes_source_files.py` | The filter itself; registered in the WebUI database, not loaded from disk at runtime |
| `hermes_source_tool.py` | Renders PDF pages to images, because Hermes treats PDF as binary |
| `install-hermes-source-filter.py` | Registers/updates the filter and turns it active and global |

Because the filter runs from the database, editing the `.py` file changes
nothing until you re-run the installer.

### Reinstalling the filter

Step 3 imports it automatically once the admin account exists; if that timed
out, or after editing the filter, run it manually:

```bash
nemoclaw <sandbox> exec -- /sandbox/open-webui/.venv/bin/python \
  /sandbox/open-webui/install-hermes-source-filter.py \
  --source /sandbox/open-webui/functions/hermes_source_files.py
```

It must run under the Open WebUI virtualenv: the installer imports `jwt`, which
is a project dependency and is absent from the sandbox system Python.

The installer talks to the WebUI API over loopback, so it drops any inherited
`HTTP_PROXY`/`HTTPS_PROXY` and retries a refused connection for about 20 seconds
while uvicorn finishes binding. A failure after that is real — check that the
service is up before re-running.

Tune behaviour (max files per request, ephemeral copy lifetime) from the
filter's valves in the Open WebUI admin UI rather than by editing the source.

## Branding

Two independent things carry the company identity:

| What | Source | Applied by |
|---|---|---|
| Product name shown in the UI | `WEBUI_NAME` in `resources/start.sh` | The service environment, read at start |
| Favicon, splash, default avatars | `resources/company-icon.png`, `resources/company-logo.png` | `apply-webui-branding.sh`, which overwrites the matching PNGs under the installed `open_webui` package |

To change the artwork, replace the PNGs in `resources/` and re-apply the overlay
without reinstalling Open WebUI:

```bash
nemoclaw <sandbox> upload resources/company-icon.png /sandbox/open-webui/
nemoclaw <sandbox> upload resources/company-logo.png /sandbox/open-webui/
nemoclaw <sandbox> exec -- /sandbox/open-webui/apply-webui-branding.sh
systemctl --user restart je-open-webui.service
```

To change the name, edit `WEBUI_NAME` in `resources/start.sh`, re-upload it, and
restart the service. Hard-refresh the browser afterwards; the old favicon and
splash are cached aggressively.

A `pip install` or an Open WebUI upgrade restores the stock assets, so re-run
the overlay after either. The script is idempotent and exits cleanly when the
assets are absent.

## Diagnostics

```bash
./deploy.sh 05                                  # full verification, read-only
openshell -g nemoclaw sandbox list              # sandbox state
nemoclaw <sandbox> doctor                       # sandbox and gateway health
nemoclaw <sandbox> logs --tail 50               # sandbox / Hermes logs
journalctl --user -u je-open-webui -n 50        # Open WebUI logs
# Ubuntu host:
docker ps -a --filter 'label=openshell.ai/sandbox-name=<sandbox>'
# Compose (inner dockerd):
docker compose exec nemohermes docker ps -a --filter 'label=openshell.ai/sandbox-name=<sandbox>'
```

A container in `restarting` state almost always means config drift.

## Troubleshooting

| Symptom | Action |
|---|---|
| Model change had no effect | Confirm with `openshell inference get`, send a new message, then restart the gateway service |
| Wanted provider not listed | `openshell provider list-profiles`; import a custom profile if it is not built in |
| Need a local (npx) MCP server | The gateway only supports HTTPS; use `hermes mcp add --command` |
| MCP credential resolution fails | `nemoclaw <sandbox> mcp status <name> --probe`; verify the `--env` key is registered as an OpenShell credential |
| Sandbox container restarts in a loop | Config drift. Re-run `./deploy.sh 02`, and check `nemoclaw <sandbox> logs --tail 50` |
| Edited Hermes config by hand | Re-run `./deploy.sh 02` (or `openshell inference set`) to restore a consistent, anchored state |
| Open WebUI unreachable, service active | Restart `je-open-webui-forward.service`; from a remote machine use an SSH tunnel |
| Open WebUI unit is `inactive` after reboot, journal says `ordering cycle` | NVIDIA's gateway unit had `After=default.target`. Re-run `./deploy.sh 03` (it strips that line) or `systemctl --user start je-open-webui.service je-open-webui-forward.service` |
| Uploads come back chunked | The filter is missing or disabled; reinstall it and confirm it is active and global |
| Filter edits have no effect | The filter runs from the WebUI database; re-run the installer after editing the `.py` |
| PDFs are not read, other files are | Check `/sandbox/open-webui/hermes_source_tool.py` exists and `pypdfium2` is in the venv |
| Stock Open WebUI artwork is back | A reinstall or upgrade overwrote it; re-run `apply-webui-branding.sh` and hard-refresh |

## Escape hatch

Editing Hermes configuration inside the sandbox works but is overwritten by the
next gateway `inference set`, and requires an anchor resync afterwards:

```bash
nemoclaw <sandbox> exec -- hermes config set model.default <model>
nemoclaw <sandbox> exec -- hermes config edit
```

Use this for temporary debugging only. For anything you want to keep, go through
the gateway commands above.
