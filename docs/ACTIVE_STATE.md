# 活跃状态与未竟目标

> 给未来接手这个项目的 Agent 或开发者阅读的"进度存档"。
> 读完这一份,你应该知道:做完了什么、卡在哪里、下一步必须先做什么。

## 未竟目标(Pending Goals)

### 1. 清理全局冗余 network policy 规则 [TODO: 需要人类决策]

`sbx policy ls` 当前有**两条** `cc.honoursoft.cn:443` 规则:
- `local / all` — 早先全局注册的(无作用域)
- `local / sandbox:claude-sbx3` — 上一轮 `New-ClaudeSbx` 注册的(本沙箱 scoped)

全局那条是冗余的(已被 scoped 那条覆盖),但删除 `local / all` 会**影响其他可能存在但已 stopped 的沙箱**的复活动作。需要人类确认是否清掉:

```bash
sbx policy rm <rule-id-of-the-global-one>
```

规则 ID 可通过 `sbx policy ls` 第一列查到。

### 2. 清理历史 stopped 沙箱 [TODO: 需要人类手动操作]

`sbx ls` 当前:
```
claude-sbx    stopped   (被 New-ClaudeSbx 重名拒绝保护)
claude-sbx2   stopped   (同上,首次功能测试遗留)
claude-sbx3   running   (当前可用)
```

`claude-sbx` 和 `claude-sbx2` 是调试过程产生的 stopped 沙箱,占着 microVM 资源但没在用。
清理方法:

```bash
sbx stop claude-sbx
sbx rm claude-sbx      # 在 Windows 上需 60s+
```

由于本项目函数刻意**不**自动 rm,这两个沙箱必须手动清。

### 3. GitHub 化和 install.sh(下一轮)

按用户上一轮指示,本轮**不上传云端**,只本地 git。但完整计划里:
- 在 GitHub 创建 `sbx-kit` repo
- 添加 `install.sh`:沙箱内 git clone repo → 拷贝文件 → 注册 hook → 启动 relay
- `New-ClaudeSbx` 增加 `-Source GitHub` 参数
- 双路径测试(Local + GitHub)

### 4. 修复 `Test-ClaudeSbx` 函数的隐藏 bug

`Test-ClaudeSbx` 第一行有 `sbx stop $Name 2>$null`,在测试前 stop 沙箱——但本项目设计**严格禁止**对 stopped 沙箱 rm,这条 stop 也是不必要的。Stop 之后 relay 可能因沙箱生命周期被回收。**建议直接删掉这行**。

### 5. `settings.json` 末尾缺少换行符

`git diff` 显示 `\ No newline at end of file`。下次提交时运行 `Add-Content settings.json ""` 或编辑器设"保存末尾换行"修复。

## 进度快照(Context Snapshot)

### 当前任务推进位置

**第 N 轮 — 本地封装已完成**。Git 仓库已初始化,本地路径端到端验证通过:

- ✅ 4 个核心文件已 commit(commit `ac0b487` "Initial commit: sbx Claude relay kit")
- ✅ `New-ClaudeSbx` 已加载到 `$PROFILE`
- ✅ 三种场景都跑通了:
  - 新建(默认名):报错并提示
  - 新建(新名):完整流程成功,claude 输出 "OK"
  - 同名拒绝:正确抛错

### 已创建/修改的核心文件

| 路径 | 说明 |
|---|---|
| `C:\Users\Zhaoji\Desktop\sbx\relay.py` | 4825 字节,HTTP relay,model name 改写 |
| `C:\Users\Zhaoji\Desktop\sbx\start-relay.sh` | 910 字节,SessionStart hook |
| `C:\Users\Zhaoji\Desktop\sbx\settings.json` | 940 字节,Claude Code 配置 |
| `C:\Users\Zhaoji\Desktop\sbx\.gitignore` | 324 字节,排除 .vscode/、临时探针 |
| `C:\Users\Zhaoji\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` | 含 `New-ClaudeSbx`、`Push-SbxKit`、`Test-ClaudeSbx` 三个函数 |
| `C:\Users\Zhaoji\Desktop\sbx\docs\ARCHITECTURE_AND_FLOW.md` | 本次生成的架构文档 |
| `C:\Users\Zhaoji\Desktop\sbx\docs\TROUBLESHOOTING.md` | 本次生成的避坑指南 |
| `C:\Users\Zhaoji\Desktop\sbx\docs\ACTIVE_STATE.md` | 本文档 |

### 当前可工作状态(端到端)

`New-ClaudeSbx -Name <new-name>` 在以下前提满足时**保证可用**:
1. 宿主已注册 `cc.honoursoft.cn` 的 custom secret(只需一次)
2. 选定名字在 `sbx ls` 中不存在(否则函数抛错)

跑通后:`sbx run <new-name>` → Claude Code TUI → 通过中转站回复。

## 下一步行动指令(Next Actionable Steps)

如果你是下一个 Agent,读到这份文件,**第一步是**:

### 1. 读取三个文件(按顺序)

```
docs/ARCHITECTURE_AND_FLOW.md   ← 理解系统怎么工作
docs/TROUBLESHOOTING.md          ← 理解 5 个坑
docs/ACTIVE_STATE.md             ← 你正在读的就是这个
```

### 2. 验证当前环境健康(可一键执行)

在 PowerShell 跑:

```powershell
# 验证 profile 加载
. $PROFILE
Get-Command New-ClaudeSbx -Syntax

# 验证沙箱
sbx ls

# 验证沙箱内 relay 在跑(替换成当前 running 的沙箱名)
sbx exec <running-sandbox> bash -lc 'cat /tmp/relay.log'
```

如果 relay.log 末尾有 `POST /v1/messages?beta=true HTTP/1.1 200 -` 的最新记录,说明链路健康。

### 3. 决定下一步动作(根据用户指令)

| 用户指令 | 你要做的 |
|---|---|
| "清理 stopped 沙箱" | 跑 `sbx stop <name>; sbx rm <name>`(每个 60s+),逐个清理 |
| "清掉全局 network policy" | 跑 `sbx policy rm <id>` 删掉 `local/all` 那条 |
| "做 GitHub 化" | 参见下方"GitHub 化清单" |
| "直接修 `Test-ClaudeSbx` bug" | 删 `sbx stop` 那行,改 `Test-ClaudeSbx` 函数 |
| "重新跑一遍完整测试" | 用新名 `claude-sbx4` 跑 `New-ClaudeSbx`,然后 `sbx run` 进 TUI |

### GitHub 化清单(下一轮预期要做)

1. 在 GitHub 创建 repo `sbx-kit`
2. 添加 `install.sh`:git clone → 部署 3 文件 + 注册 hook
3. `New-ClaudeSbx` 增加 `-Source {Local, GitHub}` 参数
4. 加 `Update-SbxKit` 轻量函数(只跑 `install.sh`,不重建沙箱)
5. 双路径测试:
   - Local:从 `C:\Users\Zhaoji\Desktop\sbx` 推文件
   - GitHub:沙箱内 git clone → install.sh
   - 两条路径的最终态必须等价
