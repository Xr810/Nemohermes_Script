# NemoHermes Deploy

Scripted deployment of a Hermes agent sandbox (NVIDIA OpenShell + NemoClaw)
on a single Ubuntu 24.04 host.

The package entry point is `./deploy.sh`. Each of the five steps is its own
script: you can re-run one, or take one (plus the files it depends on) to
another machine.

| Goal | Run |
|---|---|
| Fresh host, full install (no Open WebUI) | `./deploy.sh` |
| Infra + sandbox + Hermes API only | `./01-infra.sh` |
| Change approval mode only | `./02-hermes.sh` |
| Install Open WebUI only | `./03-openwebui.sh` |
| Attach MCP Router only | `./04-mcp.sh` |
| Checks only, change nothing | `./05-verify.sh` |

Open WebUI is off by default. Run step 3 when you want it.

## Requirements

| Item | Requirement |
|---|---|
| OS | Ubuntu 24.04 |
| Privileges | `sudo` (step 1 uses it to install packages) |
| Commands | `bash`. Step 1 installs `git`, `curl`, `binutils`, `zstd`, `lsof` |
| Network | `nvidia.com`, GitHub/GHCR, and your inference endpoint; PyPI as well if you run step 3 |
| Inference | OpenAI-compatible base URL + model name + API key |
| MCP (optional) | Public HTTPS MCP Router URL + token |

The inference endpoint must resolve over real DNS. A local proxy in fake-ip
mode (Surge/Clash, `198.18.x.x`) makes the onboard probe fail; the scripts
detect this and stop with an explanation.

## Quick start

Copy the folder to the target Linux host and run it there:

```bash
scp -r Nemohermes_Script/ user@server:~/
ssh user@server
cd ~/Nemohermes_Script
./deploy.sh
```

On a fresh machine the first run stops once and asks you to reboot (see
[Reboot](#reboot-first-run-only)). After rebooting, run `./deploy.sh` again.

When everything succeeds the last step prints `0 failed`. Hermes API is at
`http://127.0.0.1:8642/v1`. To install Open WebUI later:

```bash
./deploy.sh 03
# or
./03-openwebui.sh
```

---

## Running a single script

Every `0N-*.sh` sources `lib.sh` and then reads `config.env` / `secrets.env`.
**Do not copy a numbered script on its own.**

Whatever step you run, the same directory must contain at least:

| File | Why |
|---|---|
| `lib.sh` | Logging, wizard helpers, sandbox helpers, systemd forwards |
| `config.env` | Sandbox name, inference URL, model, MCP URL, ports |
| `secrets.env` | API key and MCP token (the wizard writes this; you can also create it by hand, mode 600) |

Step 3 also needs the whole `resources/` directory.

`./deploy.sh` runs the configuration wizard first. Running `./01-infra.sh`
directly **does not**. Fill `config.env` and `secrets.env` first, or:

```bash
./deploy.sh --skip-config 01    # skip wizard, run step 1 only
./deploy.sh --skip-config 04    # step 4 only
./01-infra.sh                   # equivalent: call the script
./04-mcp.sh
```

When `deploy.sh` is given step numbers, it runs **only those steps**. It does
not fill in earlier ones. `./deploy.sh 04` will not run 01 first.

---

## What each file does

### `deploy.sh` — wizard and dispatcher

Default sequence is 1 → 2 → 4 → 5, **skipping 3**.

```bash
./deploy.sh                  # 1, 2, 4, 5
./deploy.sh --skip-approvals # skip step 2
./deploy.sh --skip-mcp       # skip step 4
./deploy.sh --skip-config    # no wizard; use current config.env
./deploy.sh 01               # step 1 only
./deploy.sh 01 04            # steps 1 and 4
./deploy.sh 03               # Open WebUI only
./deploy.sh --help
```

The wizard asks seven questions (inference URL / model / API key / MCP URL /
MCP token / approval mode / sandbox name). Items 1, 2, 4, 6, 7 are written
back to `config.env`. The API key and MCP token go to `secrets.env`
(gitignored, mode 600) so the mandatory first-run reboot does not ask for them
again.

Do not point the base URL at `https://inference.local/v1`. That name exists
only inside the sandbox.

### `01-infra.sh` — Docker, OpenShell, NemoClaw, sandbox, Hermes API

**What it does**

1. Check inference DNS (reject fake-ip) and that URL / model / API key are set
2. If components are missing, `sudo apt-get install git curl binutils zstd lsof`
3. If `docker` / `openshell` / `nemoclaw` are missing, run the NVIDIA installer
   (`https://www.nvidia.com/nemoclaw.sh`)
4. If the sandbox is not Ready, run `nemoclaw onboard` (no `--fresh` unless
   `ONBOARD_FRESH=1`; a local image is reused when present)
5. Install systemd user units: Hermes API `:8642`, dashboard `:18789`

**How to run it alone**

```bash
# config.env must have SANDBOX_NAME, INFERENCE_BASE_URL, INFERENCE_MODEL
# secrets.env must have INFERENCE_API_KEY
./01-infra.sh
```

After the first Docker install, user systemd does not yet have the `docker`
group. The script stops and asks you to reboot, then run it again. The second
run skips the installer and continues at onboard.

When it finishes: Hermes API `http://127.0.0.1:8642/v1`, dashboard
`http://127.0.0.1:18789/`. To reach them from another device, use SSH
forwarding — see [Access points](#access-points).

This is the slow step. It is enough on its own for a minimal Hermes host.

### `02-hermes.sh` — set `approvals.mode` and re-anchor the config hash

**What it does**

Sets Hermes `approvals.mode` to `APPROVALS_MODE` in `config.env`
(`off` / `smart` / `manual`). After writing `config.yaml` it must sync
`/sandbox/.hermes/.config-hash`, or the container enters a
`HERMES_MCP_CONFIG_DRIFT` restart loop. The script backs up, writes, re-anchors,
restarts to verify, and rolls back on failure.

Empty `APPROVALS_MODE` skips the step.

**How to run it alone**

```bash
# Prerequisite: step 1 done, sandbox Ready
# Edit APPROVALS_MODE in config.env, then:
./02-hermes.sh
```

Use this when you only want to change approvals. Do not edit `config.yaml`
inside the sandbox by hand — use this script or `openshell inference set`.
See [OPERATIONS.md](OPERATIONS.md#approval-mode).

### `03-openwebui.sh` — install Open WebUI inside the sandbox (optional)

**What it does**

Installs Open WebUI 0.9.5 **inside the same sandbox** (chat uploads and Hermes
read the same disk): copies `resources/`, installs dependencies, applies
branding, writes systemd units (`:3000`), waits for an admin, imports the
`hermes_source_files` filter.

Re-running **does not wipe the database**. For a blank instance, delete
`/sandbox/open-webui/data/webui.db` (and the WAL/SHM files) yourself.

**How to run it alone**

```bash
# Prerequisite: step 1 done
# resources/ must be in the same directory
./03-openwebui.sh
```

Headless admin: set `WEBUI_ADMIN_EMAIL` and `WEBUI_ADMIN_PASSWORD` in the
environment or `secrets.env`. If they are unset, the first visit is the
"create admin" page and the script waits up to `ADMIN_WAIT_SECS`
(default 600 seconds).

If the browser is not on this Linux host:

```bash
ssh -L 127.0.0.1:3000:127.0.0.1:3000 user@server
```

On a slow link this step can take an hour with little output — that is the
download. Upload behaviour and branding are below.

### `04-mcp.sh` — attach an MCP Router to the sandbox

**What it does**

Registers a public HTTPS MCP server with
`nemoclaw <sandbox> mcp add mcp-router`. The token stays in host-side
OpenShell; it is not written into sandbox `config.yaml` (that would drift
and skip gateway credential injection). If already registered, add is skipped
but probe / tool discovery still run.

Empty `MCP_URL` exits 0.

**How to run it alone**

```bash
# Prerequisite: step 1 done
# config.env: MCP_URL=https://.../mcp
# secrets.env or environment: MCP_ROUTER_TOKEN (raw token, no Bearer prefix)
./04-mcp.sh
```

If the token is missing, the script prompts for it. Use this when Hermes is
already up and you want MCP later.

### `05-verify.sh` — read-only checks

**What it does**

Changes nothing. Checks: sandbox Ready, `nemoclaw doctor`, Hermes version,
`approvals.mode`, API `/health`. If Open WebUI is installed, also its units /
admin / filter. If MCP is configured, tool discovery. Non-zero exit on any
failure.

**How to run it alone**

```bash
./05-verify.sh
# or
./deploy.sh --skip-config 05
```

Safe to run at any time. Branding is not checked — look at the page.

### Supporting files (every numbered script needs these)

| File | Role |
|---|---|
| `lib.sh` | `source`d by every script above. Do not execute it |
| `config.env` | Non-secret config. The wizard edits it; you can also edit it before a standalone run |
| `secrets.env` | `INFERENCE_API_KEY`, `MCP_ROUTER_TOKEN`; gitignored |
| `resources/` | Step 3: blank database, install/start, filter, branding, sandbox Dockerfile (host scripts do not use it; the image comes from the NVIDIA installer) |
| `OPERATIONS.md` | Day two: change model, MCP, logs, troubleshooting |

---

## Reboot (first run only)

The NVIDIA installer adds your user to the `docker` group, but the already
running user systemd manager never picks up new groups, so the managed
gateway cannot reach `/var/run/docker.sock`. The script stops with:

```text
[ERR ] User systemd manager (pid ...) lacks the docker group (gid ...)
  Fix: reboot the machine once ... then rerun ./deploy.sh
```

Reboot, then run `./deploy.sh` or `./01-infra.sh` again. The second run skips
the installer and reuses the key in `secrets.env`.

| Environment | How to reboot |
|---|---|
| Plain server | `sudo reboot`, then SSH back in |
| OrbStack | `orbctl restart -m <vm>`, then `orbctl run -m <vm>` |
| Hyper-V | Restart the Ubuntu VM from the manager |

This step does not appear if Docker was already installed and your user
already had working Docker access.

## File uploads (filter installed by step 3)

**User → Hermes.** A file attached directly to a chat is copied to an
ephemeral directory and handed to Hermes whole, instead of being chunked
for retrieval. The copy and the Open WebUI upload record are removed
afterwards. Knowledge collections stay on RAG.

**Hermes → user.** When the user asks for a downloadable file, Hermes must
write it into the outgoing directory the filter puts in the system prompt
(`/tmp/je-hermes-outgoing/...`). The filter registers it so you can download
it via `/api/v1/files/{id}/content?attachment=true`. Copies in `data/uploads`
are kept for 20 files or 3 days per user. Do not only print a sandbox path.

On Open WebUI **0.9.5**, a new chat's first turn may not run the filter outlet,
and reply links can vanish after a reload. The file remains in Workspace →
Files. This package stays on 0.9.5.

Hermes reads text-like files itself and analyses images with its vision tool.
PDFs are treated as binary, so `hermes_source_tool.py` renders pages to
images first (`install.sh` installs `pypdfium2`). All three files live in
`/sandbox/open-webui/`.

## Branding

Step 3 applies Johnson Electric branding in two places:

| What | Source | How to change |
|---|---|---|
| Product name in the UI | `WEBUI_NAME` in `resources/start.sh` | Edit `start.sh`, re-run step 3 |
| Favicon, splash, avatars | `company-icon.png` / `company-logo.png`, applied by `apply-webui-branding.sh` | Replace the PNGs, re-run step 3 |

Missing assets or a failed copy do not fail the deployment; the UI keeps
stock Open WebUI artwork. The overlay runs after `pip install`. To change
artwork without reinstalling, see [OPERATIONS.md](OPERATIONS.md#branding).

## Access points

All of these bind loopback on the deployment host. Step 1 owns the Hermes
forwards as systemd units (onboard's own forwards die with the gateway).
Open WebUI is added by step 3.

| Interface | Address |
|---|---|
| Hermes API | `http://127.0.0.1:8642/v1`, health at `/health` |
| Hermes dashboard | `http://127.0.0.1:18789/` |
| Open WebUI | `http://127.0.0.1:3000` (after step 3) |
| OpenShell TUI | `openshell term` |

From another machine:

```bash
ssh -L 127.0.0.1:8642:127.0.0.1:8642 -L 127.0.0.1:18789:127.0.0.1:18789 user@server
```

What each surface is for: [OPERATIONS.md](OPERATIONS.md).

## Configuration reference

`config.env` holds non-secret values only.

| Variable | Default | Purpose |
|---|---|---|
| `SANDBOX_NAME` | — | Sandbox created by onboard; required |
| `AGENT` | `hermes` | Agent runtime; keep as is |
| `INFERENCE_BASE_URL` | — | OpenAI-compatible endpoint; required |
| `INFERENCE_MODEL` | — | Default model; required |
| `INFERENCE_API_KEY` | from `secrets.env` | Not written to `config.env` |
| `APPROVALS_MODE` | `manual` | `off` / `smart` / `manual`; empty skips step 2 |
| `MCP_URL` | empty | Public HTTPS MCP; empty skips step 4 |
| `MCP_ENV_VAR` | `MCP_ROUTER_TOKEN` | Credential **variable name**, not the token |
| `WEBUI_PORT` | `3000` | Open WebUI port inside the sandbox. `resources/start.sh` hardcodes 3000; change both or neither |
| `WEBUI_LOCAL_PORT` | `3000` | Host forward port; empty disables the forward |
| `FORWARD_BIND` | `127.0.0.1` | Address the host-side forwards bind |
| `SANDBOX_WAIT_SECS` | `120` | How long to wait for the sandbox to be Ready |
| `ADMIN_WAIT_SECS` | `600` | How long to wait for the browser admin |
| `FORWARD_PORTS` | `8642 …` | Reserved; no step reads it |
| `DOCKERFILE` | `resources/Dockerfile` | Reserved; the sandbox image comes from the installer |

`OPENWEBUI_*` are paths into `resources/`. Touch them only to swap an asset.

Environment variables the scripts honour:

| Variable | Effect |
|---|---|
| `INFERENCE_API_KEY` | Pre-fills wizard item 3; also loaded from `secrets.env` |
| `MCP_ROUTER_TOKEN` | Pre-fills wizard item 5; also loaded from `secrets.env` |
| `WEBUI_ADMIN_EMAIL` / `WEBUI_ADMIN_PASSWORD` | Headless first-admin creation in step 3 |
| `FORWARD_BIND` | Override the forward bind address |
| `ONBOARD_FRESH=1` | Step 1 onboard adds `--fresh` |
| `REMOTE_HOST` | Run every command over SSH against that host |
| `UNIT_DIR` / `LIBEXEC_DIR` | Override systemd unit and helper directories |

Running the scripts directly on the target host (`REMOTE_HOST` unset) is
the supported path.

## Troubleshooting

| Symptom | Action |
|---|---|
| Prompted for a sudo password | Expected; step 1 installs packages |
| `User systemd manager ... lacks the docker group` | Expected on a fresh host. Reboot, then re-run `./01-infra.sh` or `./deploy.sh` |
| `resolves to fake-ip 198.18.x.x` | A local proxy is hijacking DNS. Disconnect it or exempt the domain |
| `does not resolve` | Wrong endpoint hostname, or no network access to it |
| `Missing required inference config` | URL, model, and API key must all be set |
| `Failed to install prerequisites` | `apt-get` could not reach its mirrors; fix networking or install `git curl binutils zstd lsof` by hand, then re-run |
| `docker daemon not usable` | Still failing after a reboot: `newgrp docker`, then re-run |
| `Still missing after install` | `source ~/.bashrc` or `export PATH="$HOME/.local/bin:$PATH"`, then re-run |
| Open WebUI produces no output | It is downloading; expect up to an hour on a slow link |
| Container stuck restarting after step 2 | Config drift. The script rolls back; check `nemoclaw <sandbox> logs --tail 50` |
| Open WebUI will not start | `journalctl --user -u je-open-webui -n 40` |
| UI still shows stock Open WebUI artwork | Branding overlay was skipped; see [OPERATIONS.md](OPERATIONS.md#branding) |
| Verification reports failures | Re-run the step it points at, then `./05-verify.sh` |

Day-two operations (change model, MCP, logs): [OPERATIONS.md](OPERATIONS.md).
