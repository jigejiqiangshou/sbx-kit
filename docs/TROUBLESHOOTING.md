# 避坑指南

提取开发过程中遇到的 5 个真实技术难点。每个都按"现象 → 根因 → 修复"组织。

---

## 难点 1:沙箱内 `ANTHROPIC_API_KEY` 始终为空,Claude Code 走 OAuth `/login`

**现象**:
- `claude` 启动后立即打印 `Not logged in · Please run /login`
- 沙箱内 `env | grep ANTHROPIC` 输出为空
- 但 `sbx secret ls` 显示占位符已注册

**根因**:
- `sbx run claude-sbx` 启动 `claude` 二进制时,**claude 不通过 bash 启动**,它直接 exec
- 之前写在 `/etc/sandbox-persistent.sh` 和 `~/.bashrc` 里的 `export ANTHROPIC_API_KEY=...` 都没被执行
- 沙箱内的 bash login shell(`bash -lc`)能读到 Key,是因为 `/etc/profile.d/sandbox-persistent.sh` 在 login 时被 source;但 claude 不走 login shell
- `sbx secret set-custom` 的设计是"出网时替换",**不主动注入到沙箱进程 env**

**修复**:
- 把 `ANTHROPIC_API_KEY` 和 `ANTHROPIC_BASE_URL` 写入 `~/.claude/settings.json` 的 `env` 字段
- Claude Code 启动时会**自动**应用 settings 里的 env 到所有子进程

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8765",
    "ANTHROPIC_API_KEY": "sk-ant-pcQNfJEvUIwr4IKQ"
  }
}
```

**注意**:这里的 Key 是**占位符**,真实 Key 在出沙箱时被 sbx 守护进程替换。

---

## 难点 2:Claude Code 拒绝所有非官方模型名"There's an issue with the selected model"

**现象**:
- 沙箱内 `curl` 调中转站 `claude-sonnet-4-6` 返回 200,完全正常
- Claude Code 启动后报 `There's an issue with the selected model (claude-sonnet-4-6). It may not exist or you may not have access to it`
- 试过 `ANTHROPIC_DEFAULT_SONNET_MODEL`、`ANTHROPIC_DEFAULT_OPUS_MODEL`、`modelOverrides`、`ANTHROPIC_CUSTOM_MODEL_OPTION`、命令行 `--model` 参数,**全部被 SDK 拒绝**

**根因**:
- Claude Code 2.1.177 SDK 内部对 `ANTHROPIC_BASE_URL` 指向**非官方域名**时会做严格的模型名校验
- SDK 维护一个白名单(只认 `claude-sonnet-4-5`、`claude-opus-4-7`、`claude-opus-4-8` 等少数 ID)
- 中转站用的 `claude-sonnet-4-6`、`claude-opus-4-7-thinking` 等别名**不在白名单**;SDK 在**发送 HTTP 请求之前**就拒绝
- `modelOverrides` 在 third-party base URL 下**不生效**(官方文档说明)
- `ANTHROPIC_CUSTOM_MODEL_OPTION` 也被拒绝,因为它仍然走 third-party base URL 校验路径

**修复**:
- 把 `ANTHROPIC_BASE_URL` 设为 `http://127.0.0.1:8765` —— **localhost 路径绕开 SDK 校验**
- 写一个本地 HTTP relay,监听 8765,把请求体里的 `model` 字段**重写**为中转站接受的别名
- relay 同时把 `x-api-key` 占位符透传给中转站(占位符替换发生在更下游的 sbx 守护进程)

```python
MODEL_MAP = {
    "claude-sonnet-4-5": "claude-sonnet-4-6",
    "claude-opus-4-7": "claude-opus-4-7",
    # ...
}
```

---

## 难点 3:`sbx rm` 在 Windows 上对 stopped 沙箱卡死 >60 秒

**现象**:
- `sbx stop claude-sbx` 立即返回 `Sandbox 'claude-sbx' stopped`
- 但随后的 `sbx rm claude-sbx` 永远不返回
- 手动测试超时 60 秒
- `sbx ls` 一直显示沙箱处于 `stopped` 状态

**根因** [TODO: 需要人类补充确切报错信息] :
- Docker Sandboxes v0.32.0 在 Windows 上对已 stopped 的 microVM 资源,**后台异步释放**需要 60+ 秒
- `sbx rm` 等待 microVM 完全释放后才返回删除
- 这跟 Linux 上 stop → rm 几秒内完成的行为完全不同

**修复**:
- **不在 `New-ClaudeSbx` 里调用 `sbx rm`**
- 函数在检测到同名沙箱时**直接 `throw`** 退出,让用户手动处理:

```powershell
if ($existingNames -contains $Name) {
    throw @"
Sandbox '$Name' already exists. Refusing to continue.
To reuse this name:
    sbx stop $Name
    sbx rm $Name          # may take >60s on Windows
Or pick a different name:
    New-ClaudeSbx -Name claude-sbx-$(Get-Date -Format 'yyyyMMdd')
"@
}
```

- 用户根据错误提示要么手动 `sbx rm`(接受 60s+ 等待),要么换名字

---

## 难点 4:Claude Code SDK 启动瞬间找不到 relay,ConnectionRefused

**现象**:
- 第一次 `sbx run claude-sbx` 一切正常,claude 通过 relay 返回 OK
- 退出 TUI,执行 `sbx stop` + `sbx run`(重新启动同一个沙箱)
- claude 立刻报 `API Error: Unable to connect to API (ConnectionRefused)`

**根因**:
- `claude` 进程是 `sbx run` 在 microVM 内部 exec 启动的(非 bash)
- `relay.py` 是 `nohup python3 ... &` 启动的,**父进程是 `claude`**
- 当 `claude` 退出时,`nohup` 默认会被 SIGHUP 影响;`setsid` + `disown` 组合是必要的
- 但即便加了 `setsid + nohup + disown`,`sbx stop` 沙箱时整个进程组被 SIGTERM,relay 也死
- 下次 `sbx run` 沙箱时,claude 启动但 relay 没启动,ConnectionRefused

**修复**:
- 在 `~/.claude/settings.json` 注册 `SessionStart` hook,每次 claude 启动都强制拉起 relay
- hook 脚本用 `setsid` 把 relay 父进程变成 init(PID 1),**脱离任何进程组**

```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "/home/agent/start-relay.sh"
      }]
    }]
  }
}
```

`start-relay.sh` 关键逻辑:
```bash
nohup setsid python3 /home/agent/relay.py > /tmp/relay.log 2>&1 < /dev/null &
NEWPID=$!
disown 2>/dev/null
```

`setsid` 创建新会话,relay 父进程变成 init;后续 claude 进程或沙箱 stop 都不影响它。但**沙箱整体被 sbx reset 销毁时,relay 也会死**,这与"沙箱是 ephemeral"的设计相符。

---

## 难点 5:PowerShell 把 `sbx` 的 INFO 输出当 Error,Exit Code 1

**现象**:
- 跑 `sbx run claude-sbx --print "OK"` 实际**成功**,claude 返回 "OK"
- 但 PowerShell 抛出红色 `ERROR` 块:

```
+ CategoryInfo          : NotSpecified: (INFO: Configuring Docker:String)  
   [], RemoteException
+ FullyQualifiedErrorId : NativeCommandError
Command exited with code 1
```

**根因**:
- `sbx` 内部用 Go 写,启动 microVM 时把进度信息 `INFO: Started Docker daemon in 0.6s` 写到 **stderr**
- PowerShell 7+ 默认把 stderr 行包装成 `RemoteException` ErrorRecord
- 实际 Exit Code 1 是**虚假的**:`sbx run` 成功,只是内部 subprocess 退出码非 0 触发了 PowerShell 的 `$?` 失败标志

**修复**:
- 所有 `sbx` 命令后接 `2>&1 | Out-Null`,把 stderr 也吞掉
- 关键命令前用 `if ($LASTEXITCODE -ne 0 ...)` 显式检查,避免被 PowerShell 误判打断后续逻辑

```powershell
sbx create --name $Name claude . 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
    throw "sbx create failed (exit $LASTEXITCODE)"
}
```

**注意**:这条会**同时屏蔽**真实错误。如果 `sbx create` 真的失败,需要手动检查 `sbx ls` 看沙箱是否存在,不能依赖 PowerShell 的 exit code 信号。
