# Operations Guide

Day-two operations for a deployment created by [`deploy.sh`](README.md): changing
the model or provider, managing MCP servers, restarting Open WebUI, and reading
logs.

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

If the host is a VM and you are working from outside it, prefix commands with
your VM runner — for example `orbctl run -m <vm> …` for OrbStack — or simply SSH
in first.

## Architecture

```
browser
  → 127.0.0.1:3000 on the host          (je-open-webui-forward.service)
    → Open WebUI in the sandbox          (je-open-webui.service → start.sh)
      → Hermes API server in the sandbox (host:port from /sandbox/.hermes/.env)
        → OpenShell gateway inference layer
          → provider (OpenAI-compatible endpoint) → model
```

| Concern | Where you change it |
|---|---|
| Provider and model | `openshell provider …` / `openshell inference …` |
| MCP over HTTPS | `nemoclaw <sandbox> mcp …` |
| MCP over local stdio | `hermes mcp …` inside the sandbox (the gateway has no local-process transport) |
| Approval mode | `./deploy.sh 02` |
| Open WebUI process | `systemctl --user … je-open-webui` |

Open WebUI shows a single Hermes agent model. Its base URL points at the Hermes
API server, not at your provider, so **switching models is a gateway change, not
an Open WebUI setting**.

## Service management

Two user units are created by step 3. They are enabled for `default.target`, so
they come back after a reboot once the gateway is up.

```bash
systemctl --user status  je-open-webui.service
systemctl --user restart je-open-webui.service
systemctl --user restart je-open-webui-forward.service   # only the local port forward
journalctl --user -u je-open-webui -n 50 --no-pager
```

`je-open-webui.service` runs `start.sh` inside the sandbox and depends on
`nemoclaw-openshell-gateway.service`. Stop and `ExecStartPre` both run
`~/.local/libexec/je-open-webui-cleanup`, which kills any leftover Open WebUI
process in the sandbox so a restart cannot end up with two servers on the same
port.

If the page will not load, check the forward unit first — the app is usually
running and only the tunnel died.

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

To add the router after the fact, set `MCP_URL` in `config.env`, export the
token, and re-run the step:

```bash
export MCP_ROUTER_TOKEN='...'
./deploy.sh 04
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
commands are safe — unlike hand-editing `config.yaml`. New servers apply from the
next agent request.

## Approval mode

Use the deployment step rather than changing it by hand:

```bash
# edit APPROVALS_MODE in config.env to off | smart | manual
./deploy.sh 02
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

## Reinstalling the Open WebUI filter

The `hermes_source_files` filter passes chat uploads to Hermes as whole files
instead of chunking them for retrieval. Step 3 imports it automatically once the
admin account exists; if that timed out, run it manually:

```bash
nemoclaw <sandbox> exec -- /sandbox/open-webui/.venv/bin/python \
  /sandbox/open-webui/install-hermes-source-filter.py \
  --source /sandbox/open-webui/functions/hermes_source_files.py
```

It must run under the Open WebUI virtualenv: the installer imports `jwt`, which
is a project dependency and is absent from the sandbox system Python.

## Diagnostics

```bash
./deploy.sh 05                                  # full verification, read-only
openshell -g nemoclaw sandbox list              # sandbox state
nemoclaw doctor                                 # gateway health
nemoclaw <sandbox> logs --tail 50               # sandbox / Hermes logs
journalctl --user -u je-open-webui -n 50        # Open WebUI logs
docker ps -a --filter 'label=openshell.ai/sandbox-name=<sandbox>'
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
| Uploads come back chunked | The filter is missing or disabled; reinstall it and confirm it is active and global |

## Escape hatch

Editing Hermes configuration inside the sandbox works but is overwritten by the
next gateway `inference set`, and requires an anchor resync afterwards:

```bash
nemoclaw <sandbox> exec -- hermes config set model.default <model>
nemoclaw <sandbox> exec -- hermes config edit
```

Use this for temporary debugging only. For anything you want to keep, go through
the gateway commands above.
