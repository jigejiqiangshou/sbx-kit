# sbx-kit

> Run Claude Code inside Docker Sandboxes with a private API relay — keep your real API key off the sandbox.

让 Docker Sandbox 沙箱内运行的 Claude Code 通过公司中转站 `cc.honoursoft.cn` 调用模型,真实 API Key 永不进入沙箱。

---

## 项目特点

- **零敏感信息泄露**: 真实 API Key 只在 Windows Credential Manager 里,沙箱内永远是占位符
- **双部署模式**:
  - **Local**: 宿主推 3 文件(base64)进沙箱,适合无外网或要本地调试
  - **GitHub**: 沙箱内 `git clone` 本仓库 + 跑库内 `install.sh`,适合快速分发
- **零非计划性报错**: 4 个 PowerShell 函数全部走 `Invoke-Sbx` 包装,根除 `sbx` 写 stderr 触发的红色伪 ERROR 块
- **scoped network policy**: 每个沙箱独立放行 `cc.honoursoft.cn:443`(+ `github.com:443` 若走 GitHub 模式),不污染全局

---

## 快速开始

### 0. 一次性配置(每台新机器只需做一次)

```bash
# 在宿主 shell 跑,注册占位符到真实 key 的映射
sbx secret set-custom -g \
    --host cc.honoursoft.cn \
    --env ANTHROPIC_API_KEY \
    --placeholder 'sk-ant-pcQNfJEvUIwr4IKQ' \
    --value '<你的真实 Key>'
```

### 1. 加载 PowerShell 函数

把 `docs/` 之外、`Microsoft.PowerShell_profile.ps1` 中的 4 个函数(`Invoke-Sbx` / `New-ClaudeSbx` / `Push-SbxKit` / `Test-ClaudeSbx`)复制到你的 `$PROFILE`,新开 PowerShell 让它自动加载。

### 2. 创建沙箱

```powershell
# Local 模式(默认, 推荐本地调试 / 无外网)
New-ClaudeSbx -Name dev-1

# GitHub 模式(沙箱内 git clone, 推荐快速分发)
New-ClaudeSbx -Name dev-1 -Source GitHub
```

两种模式都看到 `[done] Sandbox 'dev-1' is ready.` 即成功。

### 3. 进 TUI

```powershell
sbx run dev-1
# 进 Claude Code TUI, 发消息, 通过 cc.honoursoft.cn 中转站拿响应
```

### 4. 烟雾测试(可选,无 TUI)

```powershell
Test-ClaudeSbx -Name dev-1
# → claude 真的回 "OK"
```

---

## 两种部署模式

| | `-Source Local`(默认) | `-Source GitHub` |
|---|---|---|
| **网络要求** | 只需 cc.honoursoft.cn | cc.honoursoft.cn + github.com |
| **host 端中间文件** | 无 | 无(全在沙箱内 `/tmp/sbx-kit`) |
| **kit 版本与沙箱** | host 端 `C:\Users\Zhaoji\Desktop\sbx` 决定 | GitHub 库 `main` 分支决定 |
| **失败时回退** | — | 改用 `-Source Local` 走 host push |
| **典型场景** | 本地迭代开发 / 无 GitHub 访问 | 多机器部署 / CI / 团队共享 |

**GitHub 模式内部**:
```
步骤 4: sbx policy allow --sandbox dev-1 github.com:443
步骤 5: 沙箱内 command -v git
       → git clone https://github.com/jigejiqiangshou/sbx-kit.git /tmp/sbx-kit
       → bash /tmp/sbx-kit/install.sh /tmp/sbx-kit
```

---

## 项目结构

```
sbx-kit/
├── relay.py              # HTTP relay, 改写 model 字段, 转发到 cc.honoursoft.cn
├── start-relay.sh        # SessionStart hook, detached 拉起 relay
├── settings.json         # Claude Code 配置 (env + modelOverrides + hooks)
├── install.sh            # 库内置部署脚本 (仅 GitHub 路径使用)
├── .gitignore
├── README.md             # 本文件
└── docs/
    ├── ARCHITECTURE_AND_FLOW.md   # 架构、控制流、技术栈、数据边界
    ├── TROUBLESHOOTING.md         # 9 个真实技术难点
    └── ACTIVE_STATE.md            # 项目快照(稳定态)
```

**`$PROFILE` 中的 PowerShell 函数**(不在本仓库):

| 函数 | 角色 |
|---|---|
| `Invoke-Sbx` | 包装任意 `sbx` 调用,根除 stderr 伪 ERROR 块 |
| `New-ClaudeSbx` | 顶层入口,5 步进度,支持 `-Source {Local, GitHub}` |
| `Push-SbxKit` | Local 路径的部署实现(base64 推 3 文件) |
| `Test-ClaudeSbx` | 烟雾测试,验证 claude 真的能回话 |

---

## 文档

- [docs/ARCHITECTURE_AND_FLOW.md](docs/ARCHITECTURE_AND_FLOW.md) — 系统怎么工作
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — 9 个真实坑(现象 → 根因 → 修复)
- [docs/ACTIVE_STATE.md](docs/ACTIVE_STATE.md) — 项目快照 + 维护指南

---

## 维护

**改 kit 内容**:
1. 改 `relay.py` / `start-relay.sh` / `settings.json`
2. `git commit && git push origin main`
3. 现有沙箱的 kit 文件**不**自动更新(沙箱是 ephemeral),新沙箱用 `New-ClaudeSbx` 重建即可拿新版

**清理 stopped 沙箱**(Windows 上 `sbx rm` 卡 60s+):
```powershell
sbx stop <name>
sbx rm <name>   # 等 60s+, 不要 Ctrl+C
```

**查 relay 健康**:
```powershell
sbx exec <name> bash -lc 'tail -n 20 /tmp/relay.log'
```

---

## 已知问题

- **`Test-ClaudeSbx` 输出含红色 ERROR 块**: `sbx` 的 INFO 写 stderr 触发的已知伪错误(`TROUBLESHOOTING.md` 难点 5),不影响功能,`OK` 输出是真的
- **GitHub 模式无 fallback**: 沙箱无 git 时会直接红字报错,需用 `-Source Local` 重试(fallback 路径下一轮实现)
- **GitHub 模式不支持 private repo**: 当前 `RepoUrl` 是公开库,private repo 需要 token 机制(未实现)

---

## License

Internal use only.
