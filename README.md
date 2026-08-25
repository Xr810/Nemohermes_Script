# NemoHermes Deploy

Hermes agent sandbox (NVIDIA OpenShell + NemoClaw). The Docker path exposes the
Hermes OpenAI-compatible API so **Open WebUI on another device** can connect to
it. Open WebUI is not installed in the image (old step 3 is skipped for now).

`docker compose up` starts the OpenShell gateway, which creates the Hermes
sandbox from the host Docker store. Bare-metal `./deploy.sh` on Ubuntu is still
supported, including optional step 3 if you want WebUI on the same host later.

## Requirements

| Item | Docker (`docker compose up`) | Bare-metal `./deploy.sh` |
|---|---|---|
| OS | Docker Engine, Docker Desktop, or OrbStack | Ubuntu 24.04 |
| Privileges | `privileged: true`, `network_mode: host`, and bind mounts of `/var/run/docker.sock` and the host's `/root` — see [How the container works](#how-the-container-works) | `sudo` for packages |
| Commands | `docker` and `docker compose` | `bash` and `ssh`. Step 1 installs `git`, `curl`, `binutils`, `zstd`, `lsof` |
| Network | `nvidia.com` (CLI install on first run) and your inference endpoint | same, plus PyPI/GitHub if you run step 3 |
| Inference | OpenAI-compatible base URL + model name + API key | same |
| MCP (optional) | Public HTTPS MCP Router URL + token | same |

The inference endpoint must resolve over real DNS. A local proxy in fake-ip mode
(Surge/Clash, `198.18.x.x`) makes the onboard probe fail; the scripts detect
this and stop with an explanation.

## Quick start (Docker)

```bash
cp .env.example .env     # then set INFERENCE_API_KEY
docker compose up -d
```

That is the whole deployment: it builds the image on first run, starts the
OpenShell gateway, creates the Hermes sandbox, and publishes the API on port
`8642`. You do not run `./deploy.sh` or the numbered scripts, and Open WebUI is
not included.

First start takes a while — it installs the CLI, pulls two sandbox base images
and builds an 84-layer sandbox image. The healthcheck allows 15 minutes before
reporting unhealthy. Watch it with `docker compose logs -f`.

Confirm it is actually serving, not merely running:

```bash
KEY=$(docker compose exec -T nemohermes \
        awk -F= '/^OPENAI_API_KEY=/{print $2}' /root/hermes-openai.env)

curl -s -X POST http://127.0.0.1:8642/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"ping"}]}'
```

A reply from `hermes-agent` means the whole chain works: forward, gateway,
sandbox, and your inference endpoint. `/health` returning 200 only proves the
forward is up.

All configuration lives in `.env`; the image holds none of it. Changing the
key, the model or the sandbox name is `docker compose up -d` — never a rebuild.
Rebuild (`docker compose up -d --build`) only after the `Dockerfile` RUN layers
or the entrypoint change.

`.env` is gitignored and never enters the build context, so no secret is stored
in an image layer and `nemohermes:local` is safe to `docker save` and copy to
another machine (see `release/`). Compose refuses to start without `.env`
rather than failing minutes later inside onboard.

Onboard uses a host Docker image when it is already present, and pulls from
GHCR when it is missing.

| Interface | Address |
|---|---|
| Hermes API (OpenAI-compatible) | `http://<this-host-ip>:8642/v1` (health at `/health`) |
| Hermes dashboard | `http://<this-host-ip>:18789/` |

Forwards bind `0.0.0.0` by default so another machine on the LAN can reach them.
Set `FORWARD_BIND=127.0.0.1` in `.env` if you want loopback only.

### Connect Open WebUI on another device

1. Wait until logs show the Hermes API URL.
2. On this machine, copy the connection file (base URL + API key):

   ```bash
   docker compose exec nemohermes cat /root/hermes-openai.env
   ```

3. On the other device, open Open WebUI → **Admin → Settings → Connections →
   OpenAI**. Paste the base URL as `http://<this-host-ip>:8642/v1` and the
   `OPENAI_API_KEY`. The Open WebUI **server** (not the browser) must be able to
   reach this host on port `8642`.

The API key is the sandbox Hermes `API_SERVER_KEY`, not your inference provider
key. Do not expose `8642` to the public internet without TLS.

```bash
docker compose logs -f
docker compose down             # stop; host images and nemohermes-home stay
docker compose down -v          # wipe wrapper state (sandbox containers on the host remain)
```

`.env` is gitignored and excluded from the build context, so the inference key
never reaches an image layer or `release/nemohermes-local.tar`. Keep `.env`
itself out of git and off shared drives; `.env.example` is the committed
template.

## How the container works

Worth reading before deploying: the image is not an ordinary sandboxed
container, and three of its requirements look alarming until you know why they
are there.

### systemd runs as PID 1

NemoClaw starts the OpenShell gateway as a **systemd user unit** and refuses to
attach to a gateway it cannot prove is supervised — `gateway-management.ts`
accepts only `systemd-system` and `systemd-user` as supervisor kinds, and the
"standalone fallback" it mentions on a systemd-less host aborts onboarding at
step 2/8. So the image installs systemd, runs it as PID 1, and pre-enables
lingering so root's user manager comes up without a login. The deployment
itself runs as `nemohermes.service`, whose output goes to `docker logs`.

Consequences: `privileged: true` (systemd needs to write cgroups), tmpfs for
`/run` and `/run/lock`, and `STOPSIGNAL SIGRTMIN+3`. The cgroup namespace stays
**private** — this is a cgroup v2 host, so systemd mounts its own cgroup2 tree.
The old `cgroup: host` plus a read-write bind of the host `/sys/fs/cgroup` is a
cgroup v1 recipe and would hand this systemd the host's entire cgroup tree.

`/tmp` is deliberately **not** tmpfs. Docker's tmpfs defaults are `noexec` and
`size=64m`; the OpenShell installer unpacks there and gates installation on
`[ -x $tmpdir/openshell-gateway ]`, which `noexec` makes false — and 64 MB
cannot hold the 67 MB gateway binary anyway.

### Sandboxes are siblings, not children

The container talks to the **host** Docker engine through the mounted socket,
so sandbox containers are created next to this one, not inside it. That is what
makes the image thin, and it is also the source of its sharpest constraint:

> Every absolute path NemoClaw hands to the host daemon is resolved in the
> **host** filesystem, not in this container.

The gateway bind-mounts the sandbox supervisor binary and the guest TLS bundle
into each sandbox. Asked for a path it cannot resolve, the host daemon does not
fail — it silently creates an **empty directory** there. The sandbox then dies
with `exec: "/opt/openshell/bin/openshell-sandbox": is a directory`, and the
empty directory it left behind poisons every later run.

The fix is path identity: `/root` is bind-mounted from the host at the same
path, and `HOME=/root`. It has to be `/root` specifically — systemd carries a
synthesized user record for root with the home directory hardcoded to `/root`
and ignores `/etc/passwd` for it, so its user manager resolves `%h`, `%E`, `%S`
and its unit search path there no matter what `HOME` says. Point `HOME`
anywhere else and the gateway unit lands where systemd will not look, and
onboard fails with `service identity query returned invalid metadata`.

**This means the container writes NemoClaw state into the host's real `/root`.**
Given that it is already privileged and holds the Docker socket, this is not a
meaningful additional concession — but the isolation is weaker than "container"
suggests. On a shared machine, prefer the bare-metal path below.

### The gateway is reachable, not exposed

NemoClaw pins the gateway to `127.0.0.1` and rejects an override outright
(`NEMOCLAW_GATEWAY_BIND_ADDRESS=0.0.0.0 is not supported ... while gateway JWT
auth is active`). Sandbox containers, however, dial it at
`host.openshell.internal`, which Docker resolves to the `openshell-docker`
bridge gateway address — where a loopback-only listener never answers, and
onboard reports it as a host firewall problem no firewall rule can fix.

The entrypoint installs a DNAT from that bridge address to loopback, and
nothing else:

```
iptables -t nat -A PREROUTING -d <bridge-gw> -p tcp --dport 8080 \
  -j DNAT --to-destination 127.0.0.1:8080
```

Binding `0.0.0.0` would have put the gateway on every interface including the
LAN; this exposes it to exactly the one subnet that has to reach it. Because
the container shares the host network namespace, the rule lands in the host's
tables.

### Self-healing on start

A run interrupted partway leaves state that wedges every later run, and
NemoClaw does not clean any of it up. The entrypoint therefore reconciles the
following on each start — all of it idempotent and a no-op on a healthy
deployment:

| Leftover | Symptom it causes | Handling |
|---|---|---|
| Lifecycle locks from a dead container | `Timed out waiting for the sandbox mutation lock (owner pid N)` | Dropped when the PID namespace differs or no process owns the pid; a live owner is left alone |
| Empty directories the host daemon created | `failed to read sandbox token`, `... is a directory` | `rmdir` — which only ever removes an *empty* directory, so real keys and tokens cannot be touched |
| Half-written gateway PKI | `partial PKI state ... some files exist but not all` | Moved aside so the gateway regenerates |
| Sandbox stuck in `Error` phase | Next onboard aborts with `already exists as OpenClaw` | Deleted; `Ready` and `Running` sandboxes are never touched |
| `gateway.env` generated once, never revisited | Stale supervisor path or bind address forever | Reconciled against the declared values |

GPU passthrough is decided from the hardware: without a usable `nvidia-smi`,
`NEMOCLAW_SANDBOX_GPU=0` is set, because the Docker GPU compatibility patch
runs even after preflight reports no GPU and fails the sandbox create. An
explicit value in `.env` always wins.

If the MCP host resolves into `198.18.0.0/15` — a proxy in fake-ip mode —
`--trusted-private-host` is passed for that host only. MCP registration is
never fatal: it is optional, and a failure there must not leave the Hermes API
unreachable when onboard, approvals and the sandbox all succeeded.

## Quick start (Ubuntu host)

Copy the folder to the target Linux host and run it there:

```bash
scp -r deploy/ user@server:~/
ssh user@server
cd ~/deploy
./deploy.sh
```

On a fresh machine the first run stops once and asks you to reboot (see
[Reboot](#reboot-first-run-only)). After rebooting, run `./deploy.sh` again.
This reboot step does not apply to `docker compose up`.

When everything succeeds the last step prints `0 failed`. On Ubuntu, step 3
also prints the local Open WebUI URL. The Docker image skips step 3.

## Configuration wizard

On the Ubuntu host, every prompt shows the current value; press Enter to keep
it. Required items never fall back to a silent default. With Docker, the same
fields live in `.env` and there is no wizard.

| # | Prompt | Notes |
|---|---|---|
| 1 | Inference base URL | Required. OpenAI-compatible, e.g. `https://openrouter.ai/api/v1` |
| 2 | Default model name | Required, e.g. `DeepSeek-V4-Flash` |
| 3 | Inference API key | Visible input; only the first few characters are echoed back |
| 4 | MCP Router URL | Optional. Leave blank to skip MCP entirely |
| 5 | MCP Router token | Only asked when 4 is set. Raw token, no `Bearer ` prefix |
| 6 | Approval mode | `off` (no prompts) / `smart` / `manual` (default) |
| 7 | Sandbox name | Required. Lowercase letters, digits, hyphens |

Answers for 1, 2, 4, 6, 7 are written back to `config.env`. The API key and MCP
token are written to `secrets.env` (gitignored, mode 600) so the **mandatory
first-run reboot** does not ask for them again. After reboot, just run
`./deploy.sh` — items 3 and 5 show the saved prefix; press Enter to keep
them or paste a new value to replace.

To replace a key later, edit `secrets.env` or delete it and re-run the wizard.

Do not point the base URL at `https://inference.local/v1`. That name only exists
inside the sandbox and the onboard probe will fail.

## What the steps do

| Step | Script | Actions |
|---|---|---|
| 1 | `01-infra.sh` | Preflight (DNS, docker group, inference config); `apt-get install git curl binutils zstd lsof`; run the NVIDIA installer when components are missing; `nemoclaw onboard` so the **gateway** creates the sandbox (no `--fresh`, no `docker pull`) |
| 2 | `02-hermes.sh` | Set `approvals.mode`, sync the Hermes config-hash anchor, restart the container to confirm no drift (rolls back on failure) |
| 3 | `03-openwebui.sh` | **Skipped.** Not run by `docker compose` or `./deploy.sh`. Opt-in later with `./deploy.sh 03` |
| 4 | `04-mcp.sh` | `nemoclaw <sandbox> mcp add mcp-router`, then probe credentials and tool discovery. Skipped when the MCP URL is empty |
| 5 | `05-verify.sh` | Read-only checks; exits non-zero if anything failed |

Step 1 is the slow one on first run (NVIDIA CLI + onboard). Step 3 (Ubuntu only)
can take up to an hour on a constrained network while Open WebUI downloads.

## Reboot (first run only)

The NVIDIA installer adds your user to the `docker` group, but the already
running user systemd manager never picks up new groups, so the managed gateway
cannot reach `/var/run/docker.sock`. The script detects this and stops:

```text
[ERR ] User systemd manager (pid ...) lacks the docker group (gid ...)
  Fix: reboot the machine once ... then rerun ./deploy.sh
```

Reboot the host, then run `./deploy.sh` again. The second run skips the
installer, reuses the API key and MCP token from `secrets.env`, and continues at
onboard.

| Environment | How to reboot |
|---|---|
| Plain server | `sudo reboot`, then SSH back in |
| OrbStack | `orbctl restart -m <vm>`, then `orbctl run -m <vm>` |
| Hyper-V | Restart the Ubuntu VM from the manager |

This step does not appear if Docker was already installed and your user already
had working Docker access.

## Create the Open WebUI admin (Ubuntu step 3 only)

Step 3 installs a blank database, so the first visit shows the "create admin"
screen. The script prints the URL and polls for the account:

```text
[INFO]  Open in your browser: http://127.0.0.1:3000
```

| Where your browser runs | How to reach it |
|---|---|
| On the Linux host (desktop) | Open the printed URL directly |
| OrbStack VM, browser on macOS | The printed address usually works (OrbStack maps the port) |
| Remote server, browser elsewhere | `localhost` resolves to the browser's own machine, not the server. Use a tunnel: `ssh -L 127.0.0.1:3000:127.0.0.1:3000 user@server` |

Once the admin exists, the script imports the `hermes_source_files` filter
(v1.3.3) and enables it globally. If no admin appears within `ADMIN_WAIT_SECS`
(default 600), the deployment continues and prints the manual import command.

## File uploads

The filter changes what happens to a file you attach directly to a chat. Instead
of being chunked and embedded for retrieval, it is copied to an ephemeral
per-request directory and handed to Hermes whole, so the agent reads the real
file. The copy and the Open WebUI upload record are removed afterwards.

Knowledge collections are deliberately left alone and keep going through RAG —
only direct chat uploads are diverted.

Hermes reads text-like files itself and analyses images with its vision tool.
PDFs are the exception: Hermes treats them as binary, so `hermes_source_tool.py`
renders the pages to images first (this is why `install.sh` pulls in
`pypdfium2`). All three files live in `/sandbox/open-webui/`.

## Branding

Step 3 applies Johnson Electric branding in two independent places:

| What | Where it comes from | To change it |
|---|---|---|
| Product name in the UI | `WEBUI_NAME` in `resources/start.sh` | Edit `start.sh`, re-run step 3 |
| Favicon, splash, avatars | `resources/company-icon.png` / `company-logo.png`, applied by `apply-webui-branding.sh` | Replace the PNGs, re-run step 3 |

The overlay is best-effort: if the assets are missing or the copy fails, the
deployment continues with stock Open WebUI artwork. It runs after `pip install`,
because it overwrites files that the install creates, and it is idempotent.

## Verification

Step 5 checks, without changing anything:

- sandbox is Ready, `nemoclaw <sandbox> doctor` reports ok, Hermes has a version
- `approvals.mode` matches the configured value (skipped if unset)
- Hermes API forward is up and `http://127.0.0.1:8642/health` returns 200
- Open WebUI checks only if step 3 was installed (`./deploy.sh 03`)
- MCP tool discovery, when an MCP URL is configured

Re-run it any time with `./deploy.sh 05`. Branding is not checked, since it
never blocks the deployment — confirm it by looking at the page.

## Access points

On **Docker**, the Hermes API and dashboard bind `0.0.0.0` so another device can
reach them (see [Connect Open WebUI on another device](#connect-open-webui-on-another-device)).

On **Ubuntu** with `./deploy.sh`, step 3 binds the same ports to loopback and
owns them as systemd units, because onboard's own forwards die with the gateway.

| Interface | Docker | Ubuntu (`./deploy.sh`) |
|---|---|---|
| Open WebUI | not installed | `http://127.0.0.1:3000` |
| Hermes dashboard | `http://<host-ip>:18789/` | `http://127.0.0.1:18789/` |
| Hermes API | `http://<host-ip>:8642/v1` | `http://127.0.0.1:8642/v1` |
| OpenShell TUI | `docker compose exec nemohermes openshell term` | `openshell term` |

To reach Ubuntu loopback ports from another machine, use SSH:

```bash
ssh -L 127.0.0.1:8642:127.0.0.1:8642 -L 127.0.0.1:18789:127.0.0.1:18789 user@server
```

See [OPERATIONS.md](OPERATIONS.md) for what each surface is for.

## Command-line options

```bash
./deploy.sh                  # steps 1, 2, 4, 5 (Open WebUI skipped)
./deploy.sh --skip-approvals # leave the approval mode unchanged
./deploy.sh --skip-mcp       # skip MCP registration
./deploy.sh --skip-config    # no wizard; use the current config.env
./deploy.sh 03               # install Open WebUI later (optional)
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
| `INFERENCE_API_KEY` | from `secrets.env` | Gitignored; not written to `config.env` |
| `APPROVALS_MODE` | `manual` | `off` / `smart` / `manual`; empty skips step 2 |
| `MCP_URL` | empty | Public HTTPS MCP Router; empty skips step 4 |
| `MCP_ENV_VAR` | `MCP_ROUTER_TOKEN` | Name of the credential variable, not the token |
| `WEBUI_PORT` | `3000` | Open WebUI port inside the sandbox. `resources/start.sh` hardcodes 3000, so change both or neither |
| `WEBUI_LOCAL_PORT` | `3000` | Ubuntu only: host port for the Open WebUI forward; empty disables it |
| `FORWARD_BIND` | `127.0.0.1` | Address the host-side forwards bind. Compose defaults to `0.0.0.0` so other devices can reach the Hermes API |
| `SANDBOX_WAIT_SECS` | `120` | How long to wait for the sandbox to be Ready |
| `ADMIN_WAIT_SECS` | `600` | How long to wait for the browser admin |
| `FORWARD_PORTS` | `8642 …` | Reserved; no step reads it — step 3 hardcodes the ports it forwards |
| `DOCKERFILE` | `resources/Dockerfile` | Unused. The compose image is the repo-root `Dockerfile` |

The remaining `OPENWEBUI_*` variables are paths into `resources/`. They exist so
the folder stays relocatable, and are worth touching only to swap an asset:

| Variable | Points at |
|---|---|
| `OPENWEBUI_FRESH_DB` | Blank database installed by step 3 |
| `OPENWEBUI_INSTALL_SH` / `OPENWEBUI_START_SH` | In-sandbox install and launch scripts |
| `OPENWEBUI_FILTER_SRC` / `OPENWEBUI_FILTER_INSTALLER` | Upload filter and its registration script |
| `OPENWEBUI_PDF_TOOL` | PDF-to-image adapter used by the filter |
| `OPENWEBUI_BRAND_ICON` / `OPENWEBUI_BRAND_LOGO` / `OPENWEBUI_BRAND_SH` | Branding assets and the overlay script; unset any of them to keep stock artwork |

Environment variables the scripts honour:

| Variable | Effect |
|---|---|
| `INFERENCE_API_KEY` | Pre-fills wizard item 3, which still prompts; also loaded from `secrets.env` |
| `MCP_ROUTER_TOKEN` | Pre-fills wizard item 5, which still prompts; also loaded from `secrets.env` |
| `IN_CONTAINER` | Set by the image. Skips systemd user units and the docker-group reboot check |
| `FORWARD_BIND` | Address for host-side port forwards (`0.0.0.0` in compose, `127.0.0.1` on the host) |
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
| `Failed to install prerequisites` | `apt-get` could not reach its mirrors; fix networking or install `git curl binutils zstd lsof` by hand, then re-run |
| `docker daemon not usable` | Still failing after a reboot: `newgrp docker`, then re-run. Compose image: `docker compose logs` and `/var/log/gateway.log` inside the container |
| `Still missing after install` | `source ~/.bashrc` or `export PATH="$HOME/.local/bin:$PATH"`, then re-run |
| Compose container restarts / docker.sock denied | The image must mount the host Docker socket. On Linux/OrbStack, `network_mode: host` is required so the gateway can create the sandbox |
| Other device cannot reach `:8642` | Use this machine's LAN IP (not `127.0.0.1`); `FORWARD_BIND` must be `0.0.0.0`; allow the port on the host firewall |
| Open WebUI install produces no output | Ubuntu step 3 only; it is downloading; expect up to an hour on a slow link |
| Container stuck restarting after step 2 | Config drift. Step 2 rolls back automatically; check `nemoclaw <sandbox> logs --tail 50` |
| Open WebUI will not start | `journalctl --user -u je-open-webui -n 40` |
| UI still shows stock Open WebUI artwork | The branding overlay was skipped; see [OPERATIONS.md](OPERATIONS.md#branding) to re-apply it without reinstalling |
| Verification reports failures | Fix the step it points at and re-run that step, then `./deploy.sh 05` |

## Repository layout

| Path | Contents |
|---|---|
| `Dockerfile` | The only Docker definition: packages, systemd as PID 1, and the bootstrap script it runs (onboard, approvals, MCP, forwards, and the reconciliation described above). Holds no configuration and no secrets. Open WebUI is not baked in |
| `docker-compose.yml` | How to run that image: privileged, host network, host Docker socket, and the `/root` bind mount that gives host and container the same paths |
| `.env` / `.env.example` | All runtime configuration for the container path. `.env` is gitignored and excluded from the build context |
| `scripts/package-image.sh` | Builds and saves the image for offline transfer |
| `release/` | The offline bundle: image tar, image-only compose file, `.env.example` |
| `deploy.sh` | Bare-metal Ubuntu entry point: wizard plus step dispatch |
| `01-infra.sh` | Prerequisites, NVIDIA installer, onboard, preflight checks |
| `02-hermes.sh` | Approval mode plus config-hash anchor sync |
| `03-openwebui.sh` | Optional Open WebUI install; not run unless `./deploy.sh 03` |
| `04-mcp.sh` | Optional `nemoclaw mcp add` registration |
| `05-verify.sh` | End-to-end verification |
| `lib.sh` | Shared logging, wizard, sandbox helpers |
| `config.env` | Host configuration; no secrets |
| `secrets.env` | API key and MCP token; created by the wizard, gitignored, mode 600 |
| `resources/` | Blank database, Open WebUI install/start scripts, upload filter and PDF adapter, branding assets, install network policy |

Day-two operations — changing the model or provider, adding MCP servers,
restarting services — are documented in [OPERATIONS.md](OPERATIONS.md).
