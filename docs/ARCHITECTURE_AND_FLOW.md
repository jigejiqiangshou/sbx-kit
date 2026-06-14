# 架构与流程

## 项目目标

让 Docker Sandbox 沙箱内运行的 Claude Code 通过公司中转站 `cc.honoursoft.cn`
而非官方 `api.anthropic.com` 调用模型,真实 API Key 永不进入沙箱。

## 核心架构理念:宿主机-沙箱解耦

整个系统严格遵守"**沙箱内零敏感信息**"原则,分两层:

```
┌────────────────────────────────────────────┐
│  宿主(Windows)                              │
│                                            │
│  ┌─────────────────────────────────────┐   │
│  │ sbx 守护进程(Docker Sandboxes)        │   │
│  │ • 启动 microVM 容器                    │   │
│  │ • 拦截出网流量,做 MITM 凭证替换        │   │
│  │ • 存储 占位符 → 真实 Key 的映射        │   │
│  │   (Windows Credential Manager)        │   │
│  └─────────────────────────────────────┘   │
│              │                              │
│              │  (出网时被替换)               │
│              ▼                              │
└────────────────────────────────────────────┘
               │
┌────────────────────────────────────────────┐
│  沙箱(Linux microVM)                       │
│                                            │
│  Claude Code ──► 127.0.0.1:8765(relay.py)  │
│                       │                    │
│                       ▼                    │
│              改写 model 字段                │
│                       │                    │
│                       ▼                    │
│              cc.honoursoft.cn ──► 上游模型   │
│                                            │
│  沙箱内永远只见占位符 `sk-ant-pcQNfJEvUIwr4IKQ`│
│  真实 Key 永远不出现在沙箱文件系统或 env    │
└────────────────────────────────────────────┘
```

### 关键解耦

- **执行容器(沙箱)**:可销毁,stop 之后任何进程都消失,只保留文件系统镜像
- **凭证存储(宿主)**:永久,由 `sbx secret ls` 管理,跨沙箱共享
- **配置注入(本仓库)**:三个核心文件可被任何新沙箱加载

## 三件套职责

| 文件 | 大小 | 作用 |
|---|---|---|
| `relay.py` | 4825 字节 | HTTP relay,监听 127.0.0.1:8765,改写 model 字段,转发到中转站 |
| `start-relay.sh` | 910 字节 | SessionStart hook,detached 启动 relay,保证每次 claude 启动时 relay 都活着 |
| `settings.json` | 940 字节 | Claude Code 配置:env(指向 relay + 占位符 Key)、modelOverrides、SessionStart hook |

## 控制流

### 1. 一次性配置(新机器)

```bash
# 宿主 shell
sbx secret set-custom -g \
    --host cc.honoursoft.cn \
    --env ANTHROPIC_API_KEY \
    --placeholder 'sk-ant-pcQNfJEvUIwr4IKQ' \
    --value '<你的真实 Key>'

sbx policy allow network --sandbox <sandbox-name> cc.honoursoft.cn:443
```

第二条 **必须带 `--sandbox`**:只对指定沙箱放行,其他沙箱拿不到这个网络权限。

### 2. 创建沙箱并部署(`New-ClaudeSbx`)

```
用户: New-ClaudeSbx -Name foo
   │
   ├─ 1. 校验 sbx secret ls 含 cc.honoursoft.cn  (占位符已注册?)
   ├─ 2. 校验 sbx ls 不含 foo  (重名直接 throw)
   ├─ 3. sbx create --name foo claude .  (创建 microVM)
   ├─ 4. sbx policy allow network --sandbox foo cc.honoursoft.cn:443
   └─ 5. Push-SbxKit:推 3 文件到 /home/agent/
          ├─ base64 编码 → sbx exec base64 -d 写入
          ├─ chmod +x start-relay.sh
          └─ 立即跑一次 start-relay.sh 让 relay 监听端口
```

### 3. Claude Code 实际调用(运行时)

```
Claude Code 启动
   │
   ├─ SessionStart hook 触发: /home/agent/start-relay.sh
   │     ├─ 杀掉旧 relay (若有)
   │     ├─ setsid + nohup + disown 启动 python3 relay.py
   │     └─ 父进程变成 init,claude 退出不影响 relay
   │
   └─ Claude 发请求: POST http://127.0.0.1:8765/v1/messages
         │  Body: {"model": "claude-sonnet-4-5", ...}
         │  Header: x-api-key: sk-ant-pcQNfJEvUIwr4IKQ  (占位符)
         │
         ▼
      relay.py
         ├─ 解析 JSON,把 "claude-sonnet-4-5" 改写为 "claude-sonnet-4-6"
         │  (Claude Code 默认模型名,中转站不认)
         ├─ 转发到 https://cc.honoursoft.cn/v1/messages
         │  x-api-key 占位符保持不变
         │
         ▼  (出沙箱)
      sbx 守护进程 MITM
         ├─ 检测到占位符,内存里替换为真实 Key
         └─ 转发到 cc.honoursoft.cn
         │
         ▼
      cc.honoursoft.cn
         ├─ 验证 Key,通过
         ├─ 找 claude-sonnet-4-6,转发上游
         └─ 返回 200 + Claude 响应
         │
         ▼ (反向同理)
      Claude Code 拿到回复,渲染 TUI
```

## 为什么需要 relay(而不是直接 ANTHROPIC_BASE_URL 指中转站)

Claude Code 2.1.177 SDK 内部有**两个阻碍**:

1. **拒绝第三方 base URL** — 任何非 `api.anthropic.com` 的 base URL 都会触发 SDK 校验逻辑
2. **模型名白名单** — 只认几个固定的 Anthropic 官方 ID,中转站的别名 `claude-sonnet-4-6` 不在白名单

绕开办法:让 Claude Code 以为自己跟 `127.0.0.1` 通信,跳过这两个校验;model name 的真实改写在 relay 完成。

## 技术栈

| 组件 | 选型 | 理由 |
|---|---|---|
| HTTP relay | Python 3 stdlib `http.server` | 沙箱内 Python 3.14 自带,零依赖 |
| 占位符机制 | Docker Sandboxes v0.32.0 原生 | 真实 Key 走 Windows Credential Manager,沙箱内永远不见 |
| Hook 机制 | Claude Code 原生 SessionStart hook | 每次启动都自动重启 relay,无需手动运维 |
| 配置分发 | PowerShell `New-ClaudeSbx` 函数 | base64 推文件,绕开 Windows 下 `sbx cp` 的不稳定行为 |
| 凭证隔离 | scoped `--sandbox` 维度 | 单沙箱 network policy,横向不传染 |

## 数据流中需要关注的边界

| 边界 | 流向 | 检查点 |
|---|---|---|
| 沙箱 → relay | HTTP loopback | 端口 8765 必须只 listen 在 127.0.0.1,不能 0.0.0.0 |
| relay → 中转站 | HTTPS 出网 | x-api-key 字段是占位符,出沙箱前被替换 |
| sbx 守护进程 → 真实 Key | 内存 | 仅在出网拦截那一瞬间被读,沙箱内无副本 |
| 宿主 → 沙箱配置文件 | base64 over sbx exec | settings.json 里只有占位符 Key,永远不是真实 Key |
