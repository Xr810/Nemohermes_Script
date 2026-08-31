# NemoHermes Deploy

Ubuntu 24.04 上的 Hermes 沙箱部署脚本（NVIDIA OpenShell + NemoClaw）。

整包入口是 `./deploy.sh`。五个步骤各自是独立脚本，可以单独再跑，也可以只拿走某一个（连同它依赖的文件）用在别的机器上。

| 你想做的事 | 跑这个 |
|---|---|
| 全新机器，一次装完（不含 Open WebUI） | `./deploy.sh` |
| 只装基础设施 + 沙箱 + Hermes API | `./01-infra.sh` |
| 只改审批模式 | `./02-hermes.sh` |
| 只装 Open WebUI | `./03-openwebui.sh` |
| 只接 MCP Router | `./04-mcp.sh` |
| 只做检查，不改任何东西 | `./05-verify.sh` |

Open WebUI 默认不装。需要时再跑步骤 3。

## Requirements

| Item | Requirement |
|---|---|
| OS | Ubuntu 24.04 |
| Privileges | `sudo`（步骤 1 装系统包时用） |
| Commands | `bash`。步骤 1 自己会装 `git`、`curl`、`binutils`、`zstd`、`lsof` |
| Network | `nvidia.com`、GitHub/GHCR，以及推理接口；跑步骤 3 时还要 PyPI |
| Inference | OpenAI 兼容的 base URL + 模型名 + API key |
| MCP（可选） | 公网 HTTPS 的 MCP Router URL + token |

推理地址必须走真实 DNS。本机代理的 fake-ip（Surge/Clash，`198.18.x.x`）会让 onboard 探测失败，脚本会直接停并说明原因。

## Quick start

把整个文件夹拷到目标 Linux 上再跑：

```bash
scp -r Nemohermes_Script/ user@server:~/
ssh user@server
cd ~/Nemohermes_Script
./deploy.sh
```

全新机器第一次会停下来让你 reboot（见 [Reboot](#reboot-first-run-only)）。重启后再跑一次 `./deploy.sh`。

成功时最后一步打印 `0 failed`。Hermes API 在 `http://127.0.0.1:8642/v1`。之后若要装 Open WebUI：

```bash
./deploy.sh 03
# 或直接
./03-openwebui.sh
```

---

## 单独跑某一个脚本

每个 `0N-*.sh` 都会 `source lib.sh` 再读 `config.env` / `secrets.env`。**不能只拷一个编号脚本过去。**

无论跑哪一步，同目录至少要有：

| 文件 | 为什么 |
|---|---|
| `lib.sh` | 日志、向导辅助函数、沙箱操作、systemd 转发 |
| `config.env` | 沙箱名、推理地址、模型、MCP URL、端口 |
| `secrets.env` | API key 和 MCP token（向导会写；也可手写，mode 600） |

步骤 3 另外需要整个 `resources/` 目录。

`./deploy.sh` 会先跑配置向导。直接跑 `./01-infra.sh` 等**不会**弹向导，所以单独跑之前先填好 `config.env` 和 `secrets.env`，或先跑一次：

```bash
./deploy.sh --skip-config 01    # 向导跳过，只跑步骤 1
./deploy.sh --skip-config 04    # 只跑步骤 4
./01-infra.sh                   # 等价：直接调脚本
./04-mcp.sh
```

`deploy.sh` 带步骤号时，**只跑你列出的那些**，不会自动补跑前后步骤。例如 `./deploy.sh 04` 不会先跑 01。

---

## 每个文件做什么

### `deploy.sh` — 向导 + 按顺序调度

默认跑 1 → 2 → 4 → 5，**跳过 3**。

```bash
./deploy.sh                  # 1, 2, 4, 5
./deploy.sh --skip-approvals # 不跑步骤 2
./deploy.sh --skip-mcp       # 不跑步骤 4
./deploy.sh --skip-config    # 不弹向导，用当前 config.env
./deploy.sh 01               # 只跑步骤 1
./deploy.sh 01 04            # 只跑 1 和 4
./deploy.sh 03               # 只跑 Open WebUI
./deploy.sh --help
```

向导问 7 项（推理 URL / 模型 / API key / MCP URL / MCP token / 审批模式 / 沙箱名）。1、2、4、6、7 写回 `config.env`；API key 和 MCP token 写到 `secrets.env`（gitignore，mode 600），这样强制 reboot 之后不用再贴一遍。

不要把 base URL 指到 `https://inference.local/v1`，那个名字只存在于沙箱内部。

### `01-infra.sh` — 装 Docker / OpenShell / NemoClaw，创建沙箱，露出 Hermes API

**做什么**

1. 检查推理 DNS（拒绝 fake-ip）和 URL / 模型 / API key 是否齐全
2. 缺组件时用 `sudo apt-get` 装 `git curl binutils zstd lsof`
3. 缺 `docker` / `openshell` / `nemoclaw` 时跑 NVIDIA 官方安装器（`https://www.nvidia.com/nemoclaw.sh`）
4. 沙箱还不是 Ready 时执行 `nemoclaw onboard`（默认不 `--fresh`，本地已有镜像就复用）
5. 装 systemd user unit：Hermes API `:8642`、dashboard `:18789`

**单独怎么用**

```bash
# config.env 里要有 SANDBOX_NAME、INFERENCE_BASE_URL、INFERENCE_MODEL
# secrets.env 里要有 INFERENCE_API_KEY
./01-infra.sh
```

第一次装 Docker 后，用户 systemd 还拿不到新的 `docker` 组，脚本会停下来让你 reboot，然后再跑一次。第二次会跳过安装器，从 onboard 继续。

跑完之后：Hermes API `http://127.0.0.1:8642/v1`，dashboard `http://127.0.0.1:18789/`。其它设备要访问，用 SSH 转发，见 [Access points](#access-points)。

这是最慢的一步。可以单独拿到一台空 Ubuntu 上当「最小 Hermes」。

### `02-hermes.sh` — 改 `approvals.mode` 并重锚 config hash

**做什么**

把 Hermes 的 `approvals.mode` 设成 `config.env` 里的 `APPROVALS_MODE`（`off` / `smart` / `manual`）。改 `config.yaml` 后必须同步 `/sandbox/.hermes/.config-hash`，否则容器会 `HERMES_MCP_CONFIG_DRIFT` 重启循环。脚本会备份、写入、重锚、重启验证，失败则回滚。

`APPROVALS_MODE` 为空则直接跳过。

**单独怎么用**

```bash
# 前提：步骤 1 已完成，沙箱 Ready
# 改 config.env 里的 APPROVALS_MODE，然后：
./02-hermes.sh
```

以后只想改审批、不想重装，就只跑这一份。手改沙箱里的 `config.yaml` 是错的，用这个脚本或 `openshell inference set`。细节见 [OPERATIONS.md](OPERATIONS.md#approval-mode)。

### `03-openwebui.sh` — 在沙箱里装 Open WebUI（可选）

**做什么**

把 Open WebUI 0.9.5 装进**同一个沙箱**（聊天上传和 Hermes 读的是同一块盘）：拷 `resources/`、装依赖、品牌资源、systemd unit（`:3000`）、等管理员账号、导入 `hermes_source_files` 过滤器。

再跑一遍**不会清库**。要空白实例就自己删 `/sandbox/open-webui/data/webui.db`（以及 WAL/SHM）。

**单独怎么用**

```bash
# 前提：步骤 1 已完成
# 同目录必须有 resources/
./03-openwebui.sh
```

无头建管理员：环境变量或 `secrets.env` 里设 `WEBUI_ADMIN_EMAIL` + `WEBUI_ADMIN_PASSWORD`。没设则第一次打开是「创建管理员」页，脚本最多等 `ADMIN_WAIT_SECS`（默认 600 秒）。

浏览器不在这台 Linux 上时：

```bash
ssh -L 127.0.0.1:3000:127.0.0.1:3000 user@server
```

这一步在差网络上可能要一个小时，期间几乎没输出，是在下 Open WebUI。上传行为和品牌见下面两节。

### `04-mcp.sh` — 给沙箱接 MCP Router

**做什么**

用 `nemoclaw <sandbox> mcp add mcp-router` 注册公网 HTTPS MCP。token 留在宿主机 OpenShell，不写进沙箱 `config.yaml`（否则会 drift，也会绕过网关的凭据注入）。已注册则跳过 add，但仍做 probe / tool discovery。

`MCP_URL` 为空则直接退出 0。

**单独怎么用**

```bash
# 前提：步骤 1 已完成
# config.env: MCP_URL=https://.../mcp
# secrets.env 或环境变量: MCP_ROUTER_TOKEN（原始 token，不要 Bearer 前缀）
./04-mcp.sh
```

token 缺失时脚本会现场问一次。已经有 Hermes、只是后来才要接 MCP 时，只跑这一份即可。

### `05-verify.sh` — 只读检查

**做什么**

不改任何状态。检查：沙箱 Ready、`nemoclaw doctor`、Hermes 版本、`approvals.mode`、API `/health`。若装过 Open WebUI 再查它的 unit / 管理员 / 过滤器。配了 MCP 再查 tool discovery。有失败则非零退出。

**单独怎么用**

```bash
./05-verify.sh
# 或
./deploy.sh --skip-config 05
```

随时可跑。品牌是否贴上不在检查范围内，看页面即可。

### 其它文件（编号脚本都依赖它们）

| 文件 | 作用 |
|---|---|
| `lib.sh` | 被上面所有脚本 `source`。不要单独执行 |
| `config.env` | 非密钥配置。向导会改；单独跑脚本前也可以手改 |
| `secrets.env` | `INFERENCE_API_KEY`、`MCP_ROUTER_TOKEN`；gitignore |
| `resources/` | 步骤 3 用：空白库、install/start、过滤器、品牌图、沙箱 Dockerfile（host 脚本不用它，镜像来自 NVIDIA 安装器） |
| `OPERATIONS.md` | 装完之后：换模型、MCP、日志、排障 |

---

## Reboot（仅第一次）

NVIDIA 安装器会把用户加进 `docker` 组，但已经在跑的 user systemd 不会拿到新组，网关就访问不了 `/var/run/docker.sock`。脚本会停在：

```text
[ERR ] User systemd manager (pid ...) lacks the docker group (gid ...)
  Fix: reboot the machine once ... then rerun ./deploy.sh
```

重启后再跑 `./deploy.sh` 或 `./01-infra.sh`。第二次跳过安装器，复用 `secrets.env` 里的 key。

| 环境 | 怎么 reboot |
|---|---|
| 普通服务器 | `sudo reboot`，再 SSH 进去 |
| OrbStack | `orbctl restart -m <vm>`，然后 `orbctl run -m <vm>` |
| Hyper-V | 在管理器里重启 Ubuntu VM |

机器上本来就能用 Docker 时不会出现这一步。

## File uploads（步骤 3 装上的过滤器）

**用户 → Hermes。** 聊天里直接附的文件会拷到一次性目录，整份交给 Hermes，而不是切成 RAG 切片。之后拷贝和 Open WebUI 上传记录会删掉。知识库仍走 RAG。

**Hermes → 用户。** 需要可下载文件时，Hermes 必须写到过滤器放进 system prompt 的目录（`/tmp/je-hermes-outgoing/...`）。过滤器登记后可通过 `/api/v1/files/{id}/content?attachment=true` 下载。`data/uploads` 里每个用户最多留 20 个或 3 天。不要只打印沙箱路径。

Open WebUI **0.9.5** 新对话第一轮可能不跑 filter outlet，刷新后回复链接也可能消失。文件仍在 Workspace → Files。本包固定 0.9.5。

文本 Hermes 自己读，图片走 vision。PDF 被当成二进制，所以 `hermes_source_tool.py` 先渲成图（`install.sh` 会装 `pypdfium2`）。三个文件都在 `/sandbox/open-webui/`。

## Branding

步骤 3 在两处贴 Johnson Electric 品牌：

| 什么 | 来源 | 怎么换 |
|---|---|---|
| 界面产品名 | `resources/start.sh` 里的 `WEBUI_NAME` | 改 `start.sh`，再跑步骤 3 |
| 图标 / 启动图 / 头像 | `company-icon.png` / `company-logo.png`，由 `apply-webui-branding.sh` 覆盖 | 换 PNG，再跑步骤 3 |

资源缺失或拷贝失败不会让部署失败，界面会保持 Open WebUI 原样。覆盖发生在 `pip install` 之后。不重装、只换图：见 [OPERATIONS.md](OPERATIONS.md#branding)。

## Access points

都绑在部署机的 loopback。步骤 1 用 systemd 接管 Hermes 的两个转发（onboard 自带的转发会随网关一起死）。Open WebUI 由步骤 3 加上。

| 界面 | 地址 |
|---|---|
| Hermes API | `http://127.0.0.1:8642/v1`，健康检查 `/health` |
| Hermes dashboard | `http://127.0.0.1:18789/` |
| Open WebUI | `http://127.0.0.1:3000`（跑过步骤 3 之后） |
| OpenShell TUI | `openshell term` |

从别的机器访问：

```bash
ssh -L 127.0.0.1:8642:127.0.0.1:8642 -L 127.0.0.1:18789:127.0.0.1:18789 user@server
```

各界面干什么见 [OPERATIONS.md](OPERATIONS.md)。

## Configuration reference

`config.env` 只放非密钥。

| Variable | Default | Purpose |
|---|---|---|
| `SANDBOX_NAME` | — | onboard 创建的沙箱名；必填 |
| `AGENT` | `hermes` | 运行时；保持即可 |
| `INFERENCE_BASE_URL` | — | OpenAI 兼容地址；必填 |
| `INFERENCE_MODEL` | — | 默认模型；必填 |
| `INFERENCE_API_KEY` | 来自 `secrets.env` | 不写进 `config.env` |
| `APPROVALS_MODE` | `manual` | `off` / `smart` / `manual`；空则跳过步骤 2 |
| `MCP_URL` | 空 | 公网 HTTPS MCP；空则跳过步骤 4 |
| `MCP_ENV_VAR` | `MCP_ROUTER_TOKEN` | 凭据**变量名**，不是 token 本身 |
| `WEBUI_PORT` | `3000` | 沙箱内 Open WebUI 端口。`resources/start.sh` 写死了 3000，要改就两处一起改 |
| `WEBUI_LOCAL_PORT` | `3000` | 宿主机转发端口；空则不转发 |
| `FORWARD_BIND` | `127.0.0.1` | 宿主机转发监听地址 |
| `SANDBOX_WAIT_SECS` | `120` | 等沙箱 Ready |
| `ADMIN_WAIT_SECS` | `600` | 等浏览器创建管理员 |
| `FORWARD_PORTS` | `8642 …` | 预留；没有步骤读它 |
| `DOCKERFILE` | `resources/Dockerfile` | 预留；沙箱镜像来自安装器 |

`OPENWEBUI_*` 是指向 `resources/` 的路径，换资源时才需要动。

脚本还会认这些环境变量：

| Variable | Effect |
|---|---|
| `INFERENCE_API_KEY` | 向导第 3 项预填；也从 `secrets.env` 读 |
| `MCP_ROUTER_TOKEN` | 向导第 5 项预填；也从 `secrets.env` 读 |
| `WEBUI_ADMIN_EMAIL` / `WEBUI_ADMIN_PASSWORD` | 步骤 3 无头建管理员 |
| `FORWARD_BIND` | 覆盖转发监听地址 |
| `ONBOARD_FRESH=1` | 步骤 1 的 onboard 加 `--fresh` |
| `REMOTE_HOST` | 命令改走 SSH 打到那台机器 |
| `UNIT_DIR` / `LIBEXEC_DIR` | 覆盖 systemd unit 和 helper 目录 |

在目标机上直接跑脚本（不设 `REMOTE_HOST`）是支持的用法。

## Troubleshooting

| 现象 | 怎么办 |
|---|---|
| 要 sudo 密码 | 正常；步骤 1 装包 |
| `User systemd manager ... lacks the docker group` | 全新机预期行为。reboot 后再跑 `./01-infra.sh` 或 `./deploy.sh` |
| `resolves to fake-ip 198.18.x.x` | 本机代理劫持了 DNS。断开或给这个域名开直连 |
| `does not resolve` | 地址写错，或到不了那个主机 |
| `Missing required inference config` | URL、模型、API key 都要有 |
| `Failed to install prerequisites` | `apt-get` 到不了源；修好网络或手装 `git curl binutils zstd lsof` 再跑 |
| `docker daemon not usable` | reboot 后仍不行：`newgrp docker` 再跑 |
| `Still missing after install` | `source ~/.bashrc` 或 `export PATH="$HOME/.local/bin:$PATH"` 再跑 |
| Open WebUI 没输出 | 在下载；慢网络可能要一小时 |
| 步骤 2 后容器一直 restart | config drift。脚本会自动回滚；看 `nemoclaw <sandbox> logs --tail 50` |
| Open WebUI 起不来 | `journalctl --user -u je-open-webui -n 40` |
| 界面还是原版 Open WebUI 图 | 品牌覆盖被跳过；见 [OPERATIONS.md](OPERATIONS.md#branding) |
| 验证失败 | 对着失败项重跑对应脚本，再 `./05-verify.sh` |

装完之后换模型、改 MCP、看日志：[OPERATIONS.md](OPERATIONS.md)。
