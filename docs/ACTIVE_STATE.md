# 活跃状态

> 给未来接手这个项目的 Agent 或开发者阅读的"项目快照"。
> 读完这一份,你应该知道:项目处于什么状态、有哪些文件、各组件的角色。

## 项目状态

**稳定态**。所有计划性任务已全部完成,本仓库可被任何新机器克隆即用。

- ✅ 核心三件套(`relay.py` / `start-relay.sh` / `settings.json`)稳定运行
- ✅ `New-ClaudeSbx` 双路径(`-Source Local` / `-Source GitHub`)端到端验证通过
- ✅ `install.sh` 已 push 到 GitHub,沙箱内自部署
- ✅ 全局冗余 policy 已清理,所有 network rule 均 scoped
- ✅ 4 个 PowerShell 函数(`Invoke-Sbx` / `New-ClaudeSbx` / `Push-SbxKit` / `Test-ClaudeSbx`)零非计划性报错

**当前没有未竟目标**。`docs/ACTIVE_STATE.md` 历史上记录的"未竟目标"清单(全局 policy 清理、stopped 沙箱清理、Test-ClaudeSbx bug 修复、settings.json 尾换行、GitHub 化)已在 2026-06-14 全部完成。

## 已交付清单

### 仓库文件(本仓库 `jigejiqiangshou/sbx-kit`)

| 路径 | 大小 | 角色 |
|---|---|---|
| `relay.py` | 4825 字节 | HTTP relay,监听 127.0.0.1:8765,改写 `model` 字段,转发到中转站 |
| `start-relay.sh` | 910 字节 | SessionStart hook,setsid+nohup+disown 拉起 relay,父进程变 init |
| `settings.json` | 940 字节 | Claude Code 配置:env + modelOverrides + SessionStart hook |
| `install.sh` | ~2.8 KB | 库内置部署脚本,沙箱内 git clone 后由它把 3 文件拷到 `/home/agent/` |
| `docs/ARCHITECTURE_AND_FLOW.md` | — | 架构、控制流、技术栈、4 个边界检查点 |
| `docs/TROUBLESHOOTING.md` | — | 9 个真实技术难点,按"现象 → 根因 → 修复"组织 |
| `docs/ACTIVE_STATE.md` | — | 本文件 |
| `README.md` | — | 项目入口:快速开始、双路径、文件清单、文档链 |
| `.gitignore` | 324 字节 | 排除 `.vscode/`、临时探针脚本、CRLF 备份 |

### 宿主端(不在本仓库)

| 路径 | 角色 |
|---|---|
| `C:\Users\Zhaoji\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` | 4 个 PowerShell 函数定义,shell 启动时自动加载 |

### 一次性宿主配置(在 Windows Credential Manager)

```bash
sbx secret set-custom -g \
    --host cc.honoursoft.cn \
    --env ANTHROPIC_API_KEY \
    --placeholder 'sk-ant-pcQNfJEvUIwr4IKQ' \
    --value '<你的真实 Key>'
```

> 真实 Key **永远**不出现在沙箱内、不出现在仓库内、不出现在 git history 中。

## 端到端工作流

`New-ClaudeSbx -Name <新名>` 在以下前提满足时**保证可用**:

1. 宿主已注册 `cc.honoursoft.cn` 的 custom secret(只需一次,见上)
2. 选定名字在 `sbx ls` 中不存在(否则函数红字提示手动 rm 或换名)

跑通后(任一 Source):

- `Local`:`New-ClaudeSbx -Name foo` → 5 进度 + ok + [done]
- `GitHub`:`New-ClaudeSbx -Name foo -Source GitHub` → 5 进度 + 3 子步 + [done]

接着:

```powershell
sbx run foo
# 进 Claude Code TUI
# 发任意消息, 期待通过 cc.honoursoft.cn 中转站拿到 Claude 响应
```

## 维护指南

### 场景 1:修改 kit 内容并推 GitHub

1. 改 `relay.py` / `start-relay.sh` / `settings.json` 任一(在 `C:\Users\Zhaoji\Desktop\sbx`)
2. `git add` + `git commit -m "..."` + `git push origin main`
3. 库内 `install.sh` 引用的是**库内版本**的 3 文件,**不需要**单独改 install.sh
4. 现有沙箱:重跑 `sbx run <name>` 会通过 SessionStart hook **不**重读新文件(已经在沙箱内了);想更新沙箱内文件,跑 `Push-SbxKit` 或重建沙箱

### 场景 2:加一个新沙箱

```powershell
# Local 模式(默认, 走 base64 推 3 文件)
New-ClaudeSbx -Name dev-1

# GitHub 模式(走沙箱内 git clone, 库和 install.sh 同源)
New-ClaudeSbx -Name dev-1 -Source GitHub
```

### 场景 3:查 relay 健康

```powershell
sbx exec <name> bash -lc 'cat /tmp/relay.log | tail -n 20'
sbx exec <name> bash -lc 'ls -la /home/agent/'
```

如果 relay.log 末尾有 `POST /v1/messages?beta=true HTTP/1.1 200 -`,说明链路健康。

### 场景 4:清理 stopped 沙箱

Windows 上 `sbx rm` 对 stopped 沙箱**卡 60s+**,这是已知行为(`TROUBLESHOOTING.md` 难点 3):

```powershell
sbx stop <name>
sbx rm <name>      # 等 60s+, 不要 Ctrl+C
```

### 场景 5:加新 host(在新机器上跑这个项目)

1. `git clone https://github.com/jigejiqiangshou/sbx-kit.git C:\path\to\sbx`
2. 注册 secret(见上)
3. 把 `$PROFILE` 中 4 个函数复制过去
4. `New-ClaudeSbx -Name test-1` 跑通即可

## 历史

| 日期 | 事件 |
|---|---|
| 2026-06-14 上午 | 本地封装完成,3 文件 commit,`New-ClaudeSbx` / `Test-ClaudeSbx` 端到端验证 |
| 2026-06-14 下午 | `New-ClaudeSbx` 零非计划性报错改造(加 `Invoke-Sbx` + 改用 `Write-Host` 红字) |
| 2026-06-14 晚 | `Test-ClaudeSbx` bug 修复;GitHub 库 `jigejiqiangshou/sbx-kit` 创建 + `install.sh` push |
| 2026-06-14 深夜 | `New-ClaudeSbx -Source {Local, GitHub}` 双路径实现,TUI 验证通过 |
| 2026-06-15 | 文档完善,`README.md` 新建,4 个文件 commit + push |
| 2026-06-15 | 修 `New-ClaudeSbx` KitDir 校验 bug(只在 `-Source Local` 校验);补 ARCHITECTURE + TROUBLESHOOTING 文档 |

## 下一步行动指令(已废弃)

历史上 `ACTIVE_STATE.md` 含此节,列了 5 条 TODO 指令。**所有 TODO 已完成**,本节保留仅为向后兼容:

> ~~如果你是下一个 Agent,读到这份文件,第一步是:~~(已不适用,见"项目状态"段)
