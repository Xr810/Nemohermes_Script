# Open WebUI + Hermes 部署后运维指南（网关优先版）

> 适用：部署完成后，日常需要**改/增 MCP 连接**、**改/增 Provider（模型来源）**。
> **管理面 = OpenShell 网关**（`openshell` / `nemoclaw` 命令，在 **VM 宿主机**上执行，
> 即 `orb -m je-accept sh -c '...'`）。沙箱里的 Hermes 只是执行者，
> 配置源头在网关——不要直接去沙箱里改 Hermes 配置（会被网关配置覆盖/不同步）。

---

## 0. 架构速览（谁管什么）

```
浏览器 → Open WebUI(3000) → Hermes 网关(沙箱内 18642) → inference.local(沙箱内)
                                                              └→ OpenShell 网关推理层
                                                                   ├ Provider: compatible-endpoint (openai)
                                                                   └ Model: DeepSeek-V4-Flash
管理命令位置：
  Provider/模型  → openshell provider ... / openshell inference ...   （VM 宿主机）
  MCP(HTTPS)    → nemoclaw <沙箱> mcp ...                            （VM 宿主机）
  MCP(本地stdio) → hermes mcp ...（沙箱内，网关不支持本地 MCP）
```

- Open WebUI 里永远只有一个模型 `hermes-agent`。**换模型 = 改网关推理配置**。
- 已注册 provider：`compatible-endpoint`（openai 类型）。网关内置 provider 档案
  （profiles）：deepinfra / nvidia / google-vertex-ai / aws-bedrock / claude-code /
  codex / copilot 等。

---

## 1. 改/增 Provider

### 1.0 先看现状（VM 宿主机）

```bash
openshell inference get          # 当前推理 provider + 模型
openshell provider list          # 已注册 provider
openshell provider list-profiles # 可用的 provider 档案（含各家的 endpoints 数）
```

### 1.1 换模型（同一个 provider 内切换）—— 最常用

```bash
openshell inference set --provider compatible-endpoint --model <新模型名>
# 例：openshell inference set --provider compatible-endpoint --model DeepSeek-V3
# 可选：--timeout <秒>；--no-verify 跳过验证
```

### 1.2 改 provider 的凭据/配置（换 API Key、换 base_url）

```bash
openshell provider update compatible-endpoint \
  --credential <KEY=新值> \
  --config <KEY=新值>
# 凭据自动过期：--credential-expires-at KEY=TIMESTAMP
```

### 1.3 增加新 provider

```bash
# a) 有现成档案（deepinfra / nvidia / vertex 等）：按档案导入/实例化
openshell provider profile import <档案文件或目录>   # 自定义档案
openshell provider list-profiles                     # 看内置档案名

# b) 实例化后填入凭据（凭据先登记为 OpenShell provider credential）
openshell provider update <新provider名> --credential KEY=VALUE --config KEY=VALUE

# c) 切到新 provider
openshell inference set --provider <新provider名> --model <模型>
```

### 1.4 删除 provider

```bash
openshell provider delete <provider名>
```

### 1.5 生效方式

- 网关推理层按请求转发，**改完一般立即生效**。发条消息验证即可。
- 若沙箱侧没变化：重启沙箱或网关服务
  （`systemctl --user restart nemoclaw-openshell-gateway.service`，在 VM 宿主机）。

---

## 2. 改/增 MCP 连接

### 2.1 OpenShell 网关托管 MCP（**公网 HTTPS 地址**，VM 宿主机）

```bash
# 凭据先登记为 OpenShell provider credential（只存 host 侧，沙箱内只见占位符）
# 添加：
nemoclaw je-test-channel mcp add <服务器名> --url https://<公网HTTPS>/mcp --env <KEY>
# 管理：
nemoclaw je-test-channel mcp list
nemoclaw je-test-channel mcp status <服务器名> --probe
nemoclaw je-test-channel mcp status <服务器名> --tools
nemoclaw je-test-channel mcp remove <服务器名>
```

- 安全模型：凭据以 `openshell:resolve:env:KEY` 占位符进沙箱，出网时由 OpenShell 解析
  并强制 mcp 策略。
- 部署脚本 05-mcp.sh 注册的 `mcp-router` 就是这个路径（MCP_URL 留空 = 未启用）。

### 2.2 本地/stdio MCP（**不走网关**，沙箱内执行）

```bash
nemoclaw je-test-channel exec -- hermes mcp add <名称> --command npx --args -y @modelcontextprotocol/server-filesystem /sandbox/data
nemoclaw je-test-channel exec -- hermes mcp list / test <名称> / remove <名称>
```

- 网关托管 MCP 只支持 HTTPS `--url`；本地进程型 MCP 用这条。
- 可加任意多个；加完下一次 agent 请求即生效。

---

## 3. 低层备选（不推荐日常使用）

沙箱内直接改 Hermes 配置可绕开网关，但**下次网关 `inference set` 会覆盖**：

```bash
nemoclaw je-test-channel exec -- hermes config set model.default <模型>
nemoclaw je-test-channel exec -- hermes config edit
```
仅用于临时/调试；正式变更请走第 1 节网关命令。

---

## 4. 常见问题速查

| 现象 | 处理 |
|---|---|
| 换了模型没生效 | 确认 `openshell inference get` 已变；发新消息验证；仍不行重启网关服务 |
| 找不到想要的新 provider | `openshell provider list-profiles` 看档案；没有就 `profile import` 自定义档案 |
| 想加本地 MCP（npx 等） | 网关不支持，走 2.2 `hermes mcp add --command` |
| MCP 报凭据解析失败 | `nemoclaw mcp status <名> --probe`；确认 `--env` 的 KEY 已在 OpenShell 登记凭据 |
| 误改了沙箱内 hermes 配置 | 用 `openshell inference set` 重设一次即可恢复网关一致状态 |
