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
- **配置注入(本仓库)**:**五个**核心文件可被任何新沙箱加载

## 仓库文件清单

| 文件 | 角色 | 谁拥有 |
|---|---|---|
| `relay.py` | HTTP relay,监听 127.0.0.1:8765,改写 `model` 字段,转发到中转站 | 沙箱 |
| `start-relay.sh` | SessionStart hook,setsid+nohup+disown 拉起 relay,父进程变 init | 沙箱 |
| `settings.json` | Claude Code 配置:env(指向 relay + 占位符 Key)、modelOverrides、SessionStart hook | 沙箱 |
| `install.sh` | **库内置部署脚本**:校验 3 文件 → `cp` 到 `/home/agent/` → chmod → 启 relay | 沙箱(由 GitHub 路径触发) |
| `docs/*.md` | 架构 / 排错 / 状态存档 | 仓库 |
| `README.md` | 项目入口文档 | 仓库 |
| `Microsoft.PowerShell_profile.ps1`(`$PROFILE`)| 4 个 PowerShell 函数:`Invoke-Sbx` / `New-ClaudeSbx` / `Push-SbxKit` / `Test-ClaudeSbx` | 宿主(`$PROFILE`,**不在**本仓库) |

## PowerShell 包装层(宿主端)

4 个函数全部定义在 `C:\Users\Zhaoji\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` 中(宿主 shell 启动时自动加载)。

### `Invoke-Sbx` — sbx 子命令的统一包装

**目的**:`sbx` Go 二进制把进度 INFO 写 stderr,PowerShell 7+ 自动包装成红色 `RemoteException` ErrorRecord(6 行块),即使命令**真的成功**也报错。`Invoke-Sbx` 用三件套根治:

```powershell
function Invoke-Sbx {
    param([Parameter(Mandatory)][string[]]$Args)
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'   # 1. 抑制 NativeCommandError 渲染
        & sbx @Args *>&1 | Out-Null                   # 2. 吞所有流(不漏 stderr)
        return $LASTEXITCODE                          # 3. 退出码给调用方判分支
    } finally {
        $ErrorActionPreference = $prev                # 4. 还原,只影响一次调用
    }
}
```

`Invoke-Sbx` 是**所有** `sbx` 调用的标准入口(除 `Test-ClaudeSbx` 故意把 `sbx run` 输出透传给用户之外)。

### `New-ClaudeSbx` — 顶层入口

**签名**:
```powershell
New-ClaudeSbx [-Name <string>] [-KitDir <string>] [-Source {Local, GitHub}] [-RepoUrl <string>] [-Ref <string>]
```

**5 步进度**(每步独立 try/fallback,失败用红字 `Write-Host` 不抛):
1. **校验 host 前置**:`sbx secret ls` 含 `cc.honoursoft.cn` 占位符
2. **校验沙箱名**:`sbx ls` 不含目标名
3. **创建沙箱**:`sbx create --name $Name claude .`(`.` = 当前工作区)
4. **加 scoped policy**:`cc.honoursoft.cn:443`;`Source=GitHub` 时多加 `github.com:443`
5. **部署 kit**:
   - `Source=Local` → 调 `Push-SbxKit`(base64 推 3 文件 + chmod + 启 relay)
   - `Source=GitHub` → 沙箱内 `command -v git` → `git clone $RepoUrl /tmp/sbx-kit` → `bash /tmp/sbx-kit/install.sh`

**错误显式化**:用 `Write-Host -ForegroundColor Red` 替代 `throw`,**完全**绕开 PowerShell ErrorRecord 渲染机制,让红色 ERROR 块只出现在**真正**计划性错误时。

### `Push-SbxKit` — Local 路径的部署实现

`Source=Local` 时被 `New-ClaudeSbx` 调用。流程:
- 读 `relay.py` / `start-relay.sh` / `settings.json` 三个本地文件
- 对每个文件:base64 编码 → `sbx exec bash -c "echo $b | base64 -d > '$dst'"` → `chmod +x` start-relay.sh
- 最后调 `start-relay.sh` 让 relay 监听 8765(失败用 `Write-Warning` 黄字,不阻塞)

返回 `$true` / `$false`,**不**抛。

### `Test-ClaudeSbx` — 烟雾测试

```powershell
Test-ClaudeSbx [-Name <string>]
# → sbx run $Name -- --print "respond OK"
# 期望最后一行输出 "OK"
```

走 `sbx run` 模式直接调,不走 `Invoke-Sbx`(用户需要看到 `Workspace:` / `OK` 等 stdout)。红色 ERROR 块是 `TROUBLESHOOTING.md` 难点 5 描述的已知伪错误,不影响 "OK" 输出。

## 控制流

### 1. 一次性配置(新机器,只需一次)

```bash
# 宿主 shell
sbx secret set-custom -g \
    --host cc.honoursoft.cn \
    --env ANTHROPIC_API_KEY \
    --placeholder 'sk-ant-pcQNfJEvUIwr4IKQ' \
    --value '<你的真实 Key>'
```

`New-ClaudeSbx` 启动时**会**检查这一步是否完成,未完成则红字提示用户怎么补。

### 2. 创建沙箱并部署(`New-ClaudeSbx` 5 步)

```
用户: New-ClaudeSbx -Name foo
   │
   ├─ 1. 校验 host: sbx secret ls 含 cc.honoursoft.cn  (占位符已注册?)
   ├─ 2. 校验重名: sbx ls 不含 foo  (重名直接 Write-Host 红字退出)
   ├─ 3. 创建:     sbx create --name foo claude .  (microVM + 绑工作区)
   ├─ 4. policy:   sbx policy allow network --sandbox foo cc.honoursoft.cn:443
   │               (Source=GitHub 时) + sbx policy allow --sandbox foo github.com:443
   └─ 5. 部署:
        Source=Local   → Push-SbxKit(base64 推 3 文件 + chmod + 启 relay)
        Source=GitHub  → 沙箱内 command -v git → git clone $RepoUrl /tmp/sbx-kit
                        → bash /tmp/sbx-kit/install.sh
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

### 4. 云端拉取路径(`-Source GitHub`)详细分解

**前置**:步骤 4 已为该沙箱加 `github.com:443` scoped policy。

**步骤 5 内部**:
```
[5/5] Deploying kit (GitHub)...
       git detected                                          ← 沙箱内 command -v git
       cloned https://github.com/jigejiqiangshou/sbx-kit.git @ main
       install.sh ok                                         ← bash /tmp/sbx-kit/install.sh /tmp/sbx-kit
```

**install.sh 内部**(`/tmp/sbx-kit/install.sh`):
1. 校验 SRC 目录(`/tmp/sbx-kit`)含 `relay.py` / `start-relay.sh` / `settings.json`
2. 决定部署目标:`/home/agent` 优先(标准 claude 镜像),缺失则回退 `/root`
3. `mkdir -p /home/agent{,/.claude}`
4. `cp -f` 三个文件到目标位置
5. `chmod +x /home/agent/start-relay.sh`
6. 调 `/home/agent/start-relay.sh` 启 relay(idempotent,失败不阻塞)

**关键不变量**:
- 全程**无** host 端中间文件 — clone / install 都在沙箱里跑
- `install.sh` 是库内版本,跟 `relay.py` / `start-relay.sh` / `settings.json` **同源**(同一 commit 哈希)
- 失败时红字报错并提示用 `-Source Local` 走 host push fallback(下一轮实现)

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
| 沙箱内安装脚本 | POSIX bash + `set -u`(不用 `-e`,让错误可见) | 兼容最小化容器镜像,避免依赖 GNU `install` 命令 |
| 沙箱内 git 部署 | `git clone --depth 1` | 沙箱内直连 GitHub,host 端零中间文件 |
| 配置分发(L) | PowerShell `New-ClaudeSbx` + `Push-SbxKit` + base64 推 | 绕开 Windows 下 `sbx cp` 的不稳定行为 |
| 配置分发(G) | GitHub 库内置 `install.sh` | 库和安装脚本同源,版本自动同步 |
| PowerShell 包装 | `Invoke-Sbx`(`*>&1` + 临时 `ErrorActionPreference` + return exit code) | 根除 sbx 写 stderr 触发的伪 ERROR 块 |
| 凭证隔离 | scoped `--sandbox` 维度 | 单沙箱 network policy,横向不传染 |
| 错误显式化 | `Write-Host -ForegroundColor Red`(不用 `throw`) | 完全绕开 PowerShell ErrorRecord 渲染机制 |

## 数据流中需要关注的边界

| 边界 | 流向 | 检查点 |
|---|---|---|
| 沙箱 → relay | HTTP loopback | 端口 8765 必须只 listen 在 127.0.0.1,不能 0.0.0.0 |
| relay → 中转站 | HTTPS 出网 | x-api-key 字段是占位符,出沙箱前被替换 |
| sbx 守护进程 → 真实 Key | 内存 | 仅在出网拦截那一瞬间被读,沙箱内无副本 |
| 宿主 → 沙箱配置文件(L) | base64 over sbx exec | settings.json 里只有占位符 Key,永远不是真实 Key |
| 宿主 → 沙箱配置文件(G) | 沙箱内 git clone(无 host 中转) | clone URL 公开,settings.json 仍是占位符 |
| 仓库 → GitHub 库 | git push origin main | 推送前检查 .gitignore,无临时文件意外提交 |
