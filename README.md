# NemoHermes Deploy

Scripted deployment of a Hermes agent sandbox (NVIDIA OpenShell + NemoClaw) with
Open WebUI as the chat front end, on a single Ubuntu host.

The entry point is `./deploy.sh`. It runs an interactive wizard, then five
numbered steps: install infrastructure, set the approval mode, install Open
WebUI, register MCP (optional), and verify the result.

## Requirements

| Item | Requirement |
|---|---|
| OS | Ubuntu 24.04 |
| Privileges | `sudo` (used to install prerequisite packages) |
| Commands | `bash`, `ssh`, `curl`, `git` (the rest is installed automatically) |
| Network | `nvidia.com`, GitHub/GHCR, PyPI, and your inference endpoint |
| Inference | OpenAI-compatible base URL + model name + API key |
| MCP (optional) | Public HTTPS MCP Router URL + token |

The inference endpoint must resolve over real DNS. A local proxy in fake-ip mode
(Surge/Clash, `198.18.x.x`) makes the onboard probe fail; the scripts detect this
and stop with an explanation.

## Quick start

Copy the folder to the target Linux host and run it there:

```bash
scp -r deploy/ user@server:~/
ssh user@server
cd ~/deploy
./deploy.sh
```

On a fresh machine the first run stops once and asks you to reboot (see
[Reboot](#reboot-first-run-only)). After rebooting, run `./deploy.sh` again.

When everything succeeds the last step prints `0 failed` and the Open WebUI URL.

## Configuration wizard

Every prompt shows the current value; press Enter to keep it. Required items
never fall back to a silent default.

| # | Prompt | Notes |
|---|---|---|
| 1 | Inference base URL | Required. OpenAI-compatible, e.g. `https://openrouter.ai/api/v1` |
| 2 | Default model name | Required, e.g. `DeepSeek-V4-Flash` |
| 3 | Inference API key | Visible input; only the prefix is echoed back |
| 4 | MCP Router URL | Optional. Leave blank to skip MCP entirely |
| 5 | MCP Router token | Only asked when 4 is set. Raw token, no `Bearer ` prefix |
| 6 | Approval mode | `off` (no prompts) / `smart` / `manual` (default) |
| 7 | Sandbox name | Required. Lowercase letters, digits, hyphens |

Answers for 1, 2, 4, 6, 7 are written back to `config.env`. **The API key and the
MCP token are never written to disk** — they live in memory for that run only, so
every run asks for them again. To avoid re-pasting:

```bash
export INFERENCE_API_KEY='sk-...'
export MCP_ROUTER_TOKEN='...'
./deploy.sh              # press Enter at the key/token prompts
```

Do not point the base URL at `https://inference.local/v1`. That name only exists
inside the sandbox and the onboard probe will fail.

## What the steps do

| Step | Script | Actions |
|---|---|---|
| 1 | `01-infra.sh` | Preflight (DNS, docker group, inference config); `apt-get install git curl binutils zstd lsof`; run the NVIDIA installer when components are missing; `nemoclaw onboard` until the sandbox is Ready |
| 2 | `02-hermes.sh` | Set `approvals.mode`, sync the Hermes config-hash anchor, restart the container to confirm no drift (rolls back on failure) |
| 3 | `03-openwebui.sh` | Upload resources; add uv/PyPI network policies; run `install.sh` (Open WebUI 0.9.5); install a blank database; write systemd units; start Open WebUI and the port-forward; wait for the admin account, then import the filter |
| 4 | `04-mcp.sh` | `nemoclaw <sandbox> mcp add mcp-router`, then probe credentials and tool discovery. Skipped when the MCP URL is empty |
| 5 | `05-verify.sh` | Read-only checks; exits non-zero if anything failed |

Steps 1 and 3 are the slow ones. On a constrained network the Open WebUI install
can take up to an hour with no output — that is the download, not a hang.

## Reboot (first run only)

The NVIDIA installer adds your user to the `docker` group, but the already
running user systemd manager never picks up new groups, so the managed gateway
cannot reach `/var/run/docker.sock`. The script detects this and stops:

```text
[ERR ] User systemd manager (pid ...) lacks the docker group (gid ...)
  Fix: reboot the machine once ... then rerun ./deploy.sh
```

Reboot the host, then run `./deploy.sh` again. The second run skips the
installer and continues at onboard.

| Environment | How to reboot |
|---|---|
| Plain server | `sudo reboot`, then SSH back in |
| OrbStack | `orbctl restart -m <vm>`, then `orbctl run -m <vm>` |
| Hyper-V | Restart the Ubuntu VM from the manager |

This step does not appear if Docker was already installed and your user already
had working Docker access.

## Create the Open WebUI admin

Step 3 installs a blank database, so the first visit shows the "create admin"
screen. The script prints the URL and polls for the account:

```text
[INFO]  Open in your browser: http://127.0.0.1:3000
```

| Where your browser runs | How to reach it |
|---|---|
| On the Linux host (desktop) | Open the printed URL directly |
| OrbStack VM, browser on macOS | The printed address usually works (OrbStack maps the port) |
| Remote server, browser elsewhere | `localhost` is your laptop, not the server. Use a tunnel: `ssh -L 127.0.0.1:3000:127.0.0.1:3000 user@server` |

Once the admin exists, the script imports the `hermes_source_files` filter and
enables it globally. The filter hands direct chat uploads to Hermes as whole
files instead of chunking them into RAG. If no admin appears within
`ADMIN_WAIT_SECS` (default 600), the deployment continues and prints the manual
import command.

## Verification

Step 5 checks, without changing anything:

- sandbox is Ready, `nemoclaw doctor` reports ok, Hermes reports a version
- `approvals.mode` matches the configured value (skipped if unset)
- Open WebUI serves static assets over the forwarded port (HTTP 200)
- an admin exists and the filter is active and global
- the three Open WebUI patches are present (new-chat `chat_id`, embedding bypass, uvicorn keep-alive)
- MCP tool discovery, when an MCP URL is configured

Re-run it any time with `./deploy.sh 05`.

## Command-line options

```bash
./deploy.sh                  # full pipeline
./deploy.sh --skip-approvals # leave the approval mode unchanged
./deploy.sh --skip-mcp       # skip MCP registration
./deploy.sh --skip-config    # no wizard; use the current config.env
./deploy.sh 03               # run only step 3
./deploy.sh 03 04            # run only steps 3 and 4
./deploy.sh --help
```

Any step can be re-run on its own after fixing a problem; there is no need to
reinstall from scratch.

> **Re-running step 3 reinstalls the blank database.** The existing Open WebUI
> admin account, users, and chat history are discarded and you must create the
> admin again. This is deliberate, so a failed install never leaves a stale
> database behind.

## Configuration reference

`config.env` holds everything except secrets.

| Variable | Default | Purpose |
|---|---|---|
| `SANDBOX_NAME` | — | Sandbox created by onboard; required |
| `AGENT` | `hermes` | Agent runtime; keep as is |
| `INFERENCE_BASE_URL` | — | OpenAI-compatible endpoint; required |
| `INFERENCE_MODEL` | — | Default model; required |
| `INFERENCE_API_KEY` | from env | Never written to the file |
| `APPROVALS_MODE` | `manual` | `off` / `smart` / `manual`; empty skips step 2 |
| `MCP_URL` | empty | Public HTTPS MCP Router; empty skips step 4 |
| `MCP_ENV_VAR` | `MCP_ROUTER_TOKEN` | Name of the credential variable, not the token |
| `WEBUI_PORT` | `3000` | Open WebUI port inside the sandbox. `resources/start.sh` hardcodes 3000, so change both or neither |
| `WEBUI_LOCAL_PORT` | `3000` | Host port for the forward; empty disables it |
| `SANDBOX_WAIT_SECS` | `120` | How long to wait for the sandbox to be Ready |
| `ADMIN_WAIT_SECS` | `600` | How long to wait for the browser admin |
| `FORWARD_PORTS` | `8642 …` | Reserved; not used by the current steps |
| `DOCKERFILE` | `resources/Dockerfile` | Reserved; the image comes from the installer |

Environment variables the scripts honour:

| Variable | Effect |
|---|---|
| `INFERENCE_API_KEY` | Pre-fills wizard item 3 |
| `MCP_ROUTER_TOKEN` | Pre-fills wizard item 5 |
| `REMOTE_HOST` | Run every command over SSH against that host instead of locally |
| `UNIT_DIR` | Override the systemd user unit directory |
| `LIBEXEC_DIR` | Override the helper script directory |

Running the scripts directly on the target host (`REMOTE_HOST` unset) is the
supported path; remote mode exists for deploying from a second machine.

## Troubleshooting

| Symptom | Action |
|---|---|
| Prompted for a sudo password | Expected; step 1 installs packages |
| `User systemd manager ... lacks the docker group` | Expected on a fresh host. Reboot, then re-run `./deploy.sh` |
| `resolves to fake-ip 198.18.x.x` | A local proxy is hijacking DNS. Disconnect it or exempt the domain |
| `does not resolve` | Wrong endpoint hostname, or no network access to it |
| `Missing required inference config` | URL, model, and API key must all be set |
| `git: command not found` | `sudo apt-get install -y git`, then re-run |
| `docker daemon not usable` | Still failing after a reboot: `newgrp docker`, then re-run |
| `Still missing after install` | `source ~/.bashrc` or `export PATH="$HOME/.local/bin:$PATH"`, then re-run |
| Open WebUI install produces no output | It is downloading; expect up to an hour on a slow link |
| Container stuck restarting after step 2 | Config drift. Step 2 rolls back automatically; check `nemoclaw <sandbox> logs --tail 50` |
| Open WebUI will not start | `journalctl --user -u je-open-webui -n 40` |
| Verification reports failures | Fix the step it points at and re-run that step, then `./deploy.sh 05` |

## Repository layout

| Path | Contents |
|---|---|
| `deploy.sh` | Entry point: wizard plus step dispatch |
| `01-infra.sh` | Prerequisites, NVIDIA installer, onboard, preflight checks |
| `02-hermes.sh` | Approval mode plus config-hash anchor sync |
| `03-openwebui.sh` | Open WebUI install, systemd units, filter import |
| `04-mcp.sh` | Optional `nemoclaw mcp add` registration |
| `05-verify.sh` | End-to-end verification |
| `lib.sh` | Shared logging, wizard, sandbox helpers |
| `config.env` | Host configuration; no secrets |
| `resources/` | Blank database, Open WebUI install/start scripts, filter, network policy, sandbox Dockerfile |

Day-two operations — changing the model or provider, adding MCP servers,
restarting services — are documented in [OPERATIONS.md](OPERATIONS.md).
