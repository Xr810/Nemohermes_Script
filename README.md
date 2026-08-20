# NemoHermes 一键部署指南

## 一、部署前准备

| 要求 | 说明 |
|---|:--|
| 系统 | Ubuntu 24.04 |
| 网络 | 能访问 `nvidia.com`、GitHub/GHCR、PyPI，以及API Endpoint |
| 推理 | OpenAI 兼容地址 + API key + 模型名 |
| 权限 | sudo |
| MCP (Optional) | 公网 HTTPS 的 MCP Router 地址 + MCP verify token |

---

## 二、把本文件夹拷到目标 Linux

请在Windows上执行：

```bash
scp -r deploy/ 用户名@服务器:~/
```

随后在Linux上执行：

```bash
ssh 用户名@服务器
cd ~/deploy
```

---

## 三、第一次运行

```bash
./deploy.sh
```

中途若提示 sudo 密码，输入即可。

向导会依次提问：

| # | 问题 | 怎么填 |
|---|---|---|
| 1 | Inference base URL | OpenAI 兼容地址，如 `https://openrouter.ai/api/v1`。必填 |
| 2 | Default model name | 模型名，如 `deepseek/deepseek-v4-flash-0731`。必填 |
| 3 | Inference API key | API key (输入可见，只显示开头几位) |
| 4 | MCP Router URL | 公网 HTTPS (如 `https://intern.eastasia.cloudapp.azure.com/mcp`), Optional |
| 5 | MCP Router token | **仅当填了第 4 题才出现。** MCP verify token |
| 6 | Approval mode | `off`（免审批）/ `smart` / `manual`（默认） |
| 7 | Sandbox name | 小写字母、数字、连字符，如 `main` |

示例：

```
━━━ Deployment Config (Enter = keep current value) ━━━
1) Inference base URL ...
   > https://openrouter.ai/api/v1
2) Default model name ...
   > deepseek/deepseek-v4-flash-0731
3) Inference API key ...
   > sk-xxxxxxxxxxxx
4) MCP Router URL ...
   >                    （回车 = 跳过 MCP）
6) Approval mode ...
   > off
7) Sandbox name ...
   > main
```

答完后脚本会：装依赖 → 跑 NVIDIA 官方安装器（Docker + OpenShell + NemoClaw）→ 尝试 onboard。

---

## 四、重启

官方安装器会把你加入 docker 组, 脚本会在这里停住并提示重启以刷新权限，例如：

```text
[ERR ] User systemd manager ... lacks the docker group ...
  Fix: reboot the machine once ... then rerun ./deploy.sh
```

**请重启这台 Linux**（物理机或虚机都可以）。不要跳过。

- 普通服务器：`sudo reboot`，再 SSH 回去
- OrbStack：在 Mac 上执行 `orbctl restart -m <虚机名>`，再 `orbctl run -m <虚机名>`
- Hyper-V：在管理器里重启那台 Ubuntu

重启后：

```bash
cd ~/deploy
./deploy.sh
```

第二次会**跳过已经装好的官方安装器**，从 onboard 继续。向导里地址/模型/沙箱名直接回车即可。**API key 要再贴一次**（安全原因未保存）；若启用了 MCP，token 也要再贴一次。

> 如果运行此脚本之前这台 Linux 就已经装好 Docker，且用户有Docker权限,此步骤不会出现.

---

## 五、等待安装完成

第二次运行会继续：

1. 创建 Hermes 沙箱（onboard）
2. 按向导设置审批模式（此处脚本会同步Hermes的配置至Openshell gateway,防止重启后Sandbox进入死循环）
3. 在沙箱内安装 Open WebUI 0.9.5 (体积较大,等待时间较长)
4. 脚本放入一份空白数据库（防止沿用之前安装失败时产生的旧库）

---

## 六、浏览器创建管理员

脚本提示类似：

```text
Please open the browser at: http://127.0.0.1:3000
```

打开后创建管理员（邮箱 + 密码）。脚本检测到账号后会自动导入附件 filter。

| 你的浏览器在哪 | 怎么打开 |
|---|---|
| 就在这台 Linux 上（有桌面） | 直接打开脚本打印的地址 |
| OrbStack 虚机，浏览器在 Mac 上 | 一般可用脚本打印的本机地址（OrbStack 会做端口映射） |
| 远程服务器 / Hyper-V，浏览器在 Windows 上 | 笔记本上的 `localhost` **不是**服务器。请用 SSH 隧道：`ssh -L 127.0.0.1:3000:127.0.0.1:3000 用户@服务器`，再打开 `http://127.0.0.1:3000` |

若 10 分钟内没建好管理员，脚本会提示稍后手动导入 filter，照提示执行即可。

Note: 此Filter的作用是上传文件直接传递给Hermes, 而非切块后传递

---

## 七、验证

最后会自动检查。看到 `0 failed` 即成功。之后：

- 聊天：浏览器打开 Open WebUI（访问方式同上）
- 换模型、加 MCP：见 `OPERATIONS.md`

---

## 八、常见问题

| 现象 | 处理 |
|---|---|
| 提示 sudo 密码 | 正常，输入部署账号密码 |
| `User systemd manager lacks the docker group` | **正常。** 按第四节重启后再跑 `./deploy.sh` |
| `git: command not found` | `sudo apt-get install -y git` 后重跑 |
| `docker daemon not usable` | 若已重启仍如此：`newgrp docker` 后重跑 |
| `Missing: openshell/nemoclaw` | `source ~/.bashrc` 或 `export PATH="$HOME/.local/bin:$PATH"` 后重跑 |
| Open WebUI 安装很久没输出 | 多半在下载，请等；连接内网时下载时长可高达一小时 |
| 想跳过某步 | `./deploy.sh --skip-approvals` 或 `--skip-mcp` |
| 只重做某一步 | `./deploy.sh 04`（Open WebUI）、`./deploy.sh 05`（MCP）等 |

---

## 附：脚本分工（可选阅读）

| 文件 | 作用 |
|---|---|
| `deploy.sh` | 入口：向导 + 按顺序调用下面各步 |
| `01-infra.sh` | 依赖、官方安装器、onboard；docker 组预检 |
| `03-hermes.sh` | 审批模式 + 配置锁 |
| `04-openwebui.sh` | Open WebUI + filter |
| `05-mcp.sh` | `nemoclaw mcp add`（可选） |
| `06-verify.sh` | 验证 |
| `lib.sh` | 共用函数 |
| `config.env` | 本机配置（不含密钥） |
| `resources/` | 干净数据库、filter、Dockerfile 等 |

某步失败时，修好后可只重跑那一步（例如 `./deploy.sh 04`），不必从头装官方安装器。
