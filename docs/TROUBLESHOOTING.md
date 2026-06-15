# 避坑指南

提取开发过程中遇到的 9 个真实技术难点。每个都按"现象 → 根因 → 修复"组织。

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

**根因**:
- Docker Sandboxes v0.32.0 在 Windows 上对已 stopped 的 microVM 资源,**后台异步释放**需要 60+ 秒
- `sbx rm` 等待 microVM 完全释放后才返回删除
- 这跟 Linux 上 stop → rm 几秒内完成的行为完全不同

**修复**:
- **不在 `New-ClaudeSbx` 里调用 `sbx rm`**
- 函数在检测到同名沙箱时**直接**红字 `Write-Host` 退出,让用户手动处理

```powershell
if ($existing -contains $Name) {
    Write-Host "[ERROR] Sandbox '$Name' already exists. ..." -ForegroundColor Red
    return
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

**修复**(部分):
- 所有 `sbx` 命令后接 `2>&1 | Out-Null`,把 stderr 也吞掉
- 关键命令前用 `if ($LASTEXITCODE -ne 0 ...)` 显式检查,避免被 PowerShell 误判打断后续逻辑

```powershell
sbx create --name $Name claude . 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
    throw "sbx create failed (exit $LASTEXITCODE)"
}
```

**注意**:这条**只**部分解决问题。完整修复见难点 6(用 `*>&1` + `Invoke-Sbx`)。

---

## 难点 6:`2>&1 | Out-Null` 不够,要用 `*>&1` + `Invoke-Sbx`

**现象**:
- 写了 `$secretOut = sbx secret ls 2>&1 | Out-String`,PowerShell 仍然渲染红色 ERROR 块
- 用 `2>&1 | Out-Null` 吞 stderr 之后,`$LASTEXITCODE` 经常**不是预期值**(显示 1,实际 0)
- `New-ClaudeSbx` 步骤 3 `sbx create` 每次都"失败",但 `sbx ls` 显示沙箱真的创建了

**根因**:
- PowerShell 7+ 渲染 `NativeCommandError` 走 **ErrorRecord 通道**,**不**只是 stderr 重定向能解决的
- 即便你 `2>&1` 把 stderr 合并到 stdout 进管道,`$LASTEXITCODE` 是**最后一个** native 命令的退出码,不是 `sbx` 整体的
- `2>&1 | Out-Null` 把**整条管道**的退出码吞了,后续 `if ($LASTEXITCODE -ne 0)` 拿到的是 `Out-Null` 的退出码(永远 0),判断失真
- 必须 `*>&1` 把**所有**流(成功 + 错误 + 警告 + 信息 + 调试 + verbose)统一重定向,才能彻底切断 ErrorRecord 渲染

**修复**:
- 用专用 helper `Invoke-Sbx` 包装,三件套:

```powershell
function Invoke-Sbx {
    param([Parameter(Mandatory)][string[]]$Args)
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'   # 1. 抑制 NativeCommandError 渲染
        & sbx @Args *>&1 | Out-Null                   # 2. *>&1 吞所有流(不漏 stderr)
        return $LASTEXITCODE                          # 3. 直接拿 sbx 退出码
    } finally {
        $ErrorActionPreference = $prev                # 4. 还原,只影响一次调用
    }
}
```

- `*>&1` 是 PowerShell 5+ 的"all streams"重定向
- 临时切 `ErrorActionPreference = 'SilentlyContinue'` 是关键 — 这会让 PowerShell **不**把 stderr 写动作包装成 ErrorRecord
- `finally` 块保证还原 — 只在**这次**调用内生效,不污染其他命令

**`New-ClaudeSbx` 内的标准用法**:
```powershell
$rc = Invoke-Sbx -Args @('create', '--name', $Name, 'claude', '.')
if ($rc -ne 0) {
    Write-Host "[ERROR] sbx create failed (exit $rc)" -ForegroundColor Red
    return
}
```

**注意**:
- `Test-ClaudeSbx` **故意**不走 `Invoke-Sbx`,因为 `sbx run` 需要把 `Workspace:` / `OK` 等 stdout 透传给用户看
- 红色 ERROR 块在 `Test-ClaudeSbx` 输出里**是已知**的(`sbx` INFO 写 stderr),不影响 `OK` 输出

---

## 难点 7:`sbx exec` 里的命令含 `//` 被 PowerShell 解析成 drive 路径

**现象**:
- 跑 `sbx exec sandbox bash -c 'curl http://127.0.0.1:8765/v1/models'`
- PowerShell 报:
  ```
  curl: (2) no URL specified
  curl: try 'curl --help' or 'curl --manual' for more information
  ```
- 在沙箱外直接 `curl http://127.0.0.1:8765/v1/models` 完全正常

**根因**:
- PowerShell 解析单引号字符串时,把 `//` 当作 UNC 路径前缀(`\\server\share`)
- 引号内的 `//` 被切分,curl 收到一个不含 URL 的空参数
- 跟 `curl` 本身无关,跟 PowerShell **字符串解析**有关

**修复**:
- **不能**直接在 PowerShell 命令行里写含 `//` 的 URL
- 改用**两步法**:把命令写到本地文件 → base64 推沙箱 → 沙箱内 `bash <file>`

```powershell
# 1. 写命令到本地文件 (含 ://, Windows 不解析,纯字节)
Set-Content -Path C:\Users\Zhaoji\Desktop\sbx\probe.sh -Value "curl http://127.0.0.1:8765/v1/models" -Encoding ASCII

# 2. 编码成 LF + base64
$bytes = [IO.File]::ReadAllBytes("C:\Users\Zhaoji\Desktop\sbx\probe.sh")
$lf = $bytes -ne [byte]13    # 去 CR
$b = [Convert]::ToBase64String($lf)

# 3. 推入沙箱并执行
sbx exec sandbox bash -c "echo $b | base64 -d > /tmp/probe.sh && bash /tmp/probe.sh"
```

**注意**:
- PowerShell 命令行用 `[char]58 + [char]47 + [char]47` 拼 `://` 的方案**不可靠**(单引号转义在不同 PS 版本行为不一致)
- 写文件 → base64 → 沙箱解码的"通道法"是**唯一**可靠的方案

---

## 难点 8:Windows `create_file` 写 CRLF,沙箱内 bash 把 `\r` 当命令

**现象**:
- 用 `create_file` 写一个 bash 脚本,内容里只有 `echo hello`
- base64 推到沙箱,沙箱内 `bash /tmp/script.sh`
- 报:
  ```
  /tmp/script.sh: line 2: $'echo\r': command not found
  ```

**根因**:
- `create_file`(和很多 Windows 编辑器)默认写 **CRLF (0D 0A)** 行尾
- Linux bash 解释器把 `\r`(0D)当**一个独立的字符**,直接当命令字符
- 整行 `echo hello\r` 解析成 `echo` + ` ` + `hello` + 0x0D → 报命令 not found

**修复**(PowerShell 端,写之前过滤):
```powershell
$path = "C:\path\to\script.sh"
$bytes = [IO.File]::ReadAllBytes($path)
$lf = $bytes -ne [byte]13    # 把 0D 全去掉,只留 0A
[IO.File]::WriteAllBytes($path, $lf)
```

**修复**(写时显式 LF,如果工具支持):
- `Set-Content -Encoding UTF8` 在 PowerShell 7+ 默认 LF(不带 BOM)
- `Set-Content -Encoding Ascii` 在 PowerShell 5+ 是 UTF-16(更糟)
- **最稳**的还是上面那种 "read 字节 → 过滤 0D → write 字节"

**沙箱端修复**(在 install.sh 里加 `sed -i 's/\r$//'`):
- 如果你**不能**在 host 端过滤(比如命令是临时拼的),在沙箱内跑:
  ```bash
  sed -i 's/\r$//' /tmp/script.sh && bash /tmp/script.sh
  ```
- 这条作为**fallback**保留,host 端过滤仍是首选

---

## 难点 9:沙箱冷启动后立即 `curl` 报 ConnectionRefused

**现象**:
- 沙箱刚 `sbx create` 完,`sbx ls` 显示 running
- 立刻 `sbx exec sandbox bash -lc 'curl http://127.0.0.1:8765/v1/models'`
- 报: `Failed to connect to 127.0.0.1 port 8765 ... Connection refused`
- 沙箱内 `/tmp/relay.log` 是空的,relay 根本没启动

**根因**:
- `sbx exec` **会**触发沙箱冷启动(若沙箱未启动)
- 但 `SessionStart` hook **只**在 `claude` 启动时触发(`sbx run <name>`)
- `sbx exec bash -c ...` **不**触发 hook,relay **不**会自启
- 这是设计:`SessionStart` 跟 Claude Code 生命周期绑定,不是跟 microVM

**修复**(临时探针用):
```powershell
# 先手动拉起 relay
sbx exec sandbox bash -lc '/home/agent/start-relay.sh'

# 再发请求
sbx exec sandbox bash -lc 'curl http://127.0.0.1:8765/v1/models'
```

**修复**(生产用,推荐):
- 永远用 `sbx run <name>` 进 Claude Code TUI,让 hook 自然触发
- `Test-ClaudeSbx -Name <name>`(走 `--print "respond OK"`)也会触发 hook
- 真正需要"无 claude 启动,只要 relay"的场景,显式 `sbx exec ... start-relay.sh`

**注意**:
- 这个"ConnectionRefused"**不是** relay 配置错误
- 不是占位符替换问题
- 不是 `cc.honoursoft.cn` 网络问题
- 是测试探针流程不完整 — 缺少"启 relay"这一步

---

## 难点 10:`-Source GitHub` 时 `New-ClaudeSbx` 误报"KitDir missing relay.py"

**现象**:
- 在 `C:\Users\Zhaoji\Desktop\sbx\test` 下跑 `New-ClaudeSbx -Name async-claude -Source GitHub`
- 立刻红字:
  ```
  [ERROR] KitDir 'C:\Users\Zhaoji\Desktop\sbx\test' is missing relay.py
  ```
- 沙箱**没**创建,GitHub 流程**没**机会跑

**根因**:
- 早期 `New-ClaudeSbx` 把 KitDir 校验放在函数最顶部,**不**分 `-Source` 都跑
- 校验逻辑:
  1. 若 `$KitDir` 没传,fallback 到 `$PSScriptRoot`(profile 自身目录,**不**含 kit)→ `Get-Location`(用户 CWD)
  2. 校验 `relay.py` / `start-relay.sh` / `settings.json` 是否在 `$KitDir` 下
- 表面上看起来"合理",实际上**只有 `-Source Local` 才需要** KitDir
- 历史上在 `C:\Users\Zhaoji\Desktop\sbx`(恰好有 3 文件)下跑 GitHub 模式,`Get-Location` 兜底**碰巧**通过校验,掩盖了 bug
- 一旦用户 cd 到子目录(如 `sbx\test`),bug 暴露

**修复**:
- 把整个 KitDir 解析 + 3 文件校验包到 `if ($Source -eq 'Local')` 里
- `-Source GitHub` 完全跳过这段,直接走步骤 2(host 前置校验)

```powershell
# 1. Resolve paths (only needed for -Source Local; -Source GitHub
#    pulls the kit from a git clone inside the sandbox, so KitDir
#    is irrelevant and we MUST NOT require it on disk).
if ($Source -eq 'Local') {
    if (-not $KitDir) {
        if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'relay.py'))) {
            $KitDir = $PSScriptRoot
        }
        else {
            $KitDir = (Get-Location).Path
        }
    }
    foreach ($f in "relay.py", "start-relay.sh", "settings.json") {
        if (-not (Test-Path (Join-Path $KitDir $f))) {
            Write-Host "[ERROR] KitDir '$KitDir' is missing $f" -ForegroundColor Red
            return
        }
    }
}
```

**注意**:
- 这个 bug **只有在用户 cd 到非 kit 目录**时才会暴露
- 历史上 5/14 在 `C:\Users\Zhaoji\Desktop\sbx` 直接跑 GitHub 模式,`Get-Location` 兜底,3 文件就在 CWD,**没**踩到
- 5/15 用户 cd 到 `sbx\test` 才暴露
- **教训**:任何**只在某些 CWD 下成立**的"自动探测"逻辑都是隐藏 bug,需要按参数意图(`-Source`)显式分支

---

## 难点 11:`-Source GitHub` 在 cold-start microVM 上 git clone 偶发 exit 1

**现象**:
- 第一次跑 `New-ClaudeSbx -Name foo -Source GitHub` 报:
  ```
  [5/5] Deploying kit (GitHub)...
         git detected

  [ERROR] sandbox-direct `git clone` failed (exit 1).
  ```
- 几分钟后**重试** 同一个命令(`New-ClaudeSbx -Name bar -Source GitHub`)就成功了
- 沙箱内 `getent hosts github.com` ✅,`</dev/tcp/github.com/443` ✅,DNS 没问题
- `sbx policy ls` 也有 `sandbox:<name>` 的 `github.com:443` scoped 规则
- 手动跑 `sbx exec <name> bash -lc 'git clone ...'` 单独测试也成功

**根因**:
- `sbx create` 返回成功的瞬间, microVM 还在**后台异步初始化**一些子系统
- 立刻发 `bash -lc 'git clone ...'`,某些关键路径还没就绪:
  - `/tmp` 目录权限初始化
  - `~/.gitconfig` 加载
  - `git` 二进制(可能来自 lazy-mount)就绪
  - DNS resolver 缓存
- `bash -lc` 看到 `git` 存在于 PATH(检测通过),但实际 `git clone` 内部 syscall 时某些子资源未就绪 → 退出码 **1**(generic error)或 **128**(fatal)
- 这是 **microVM cold-start race**,**不是** 网络 / DNS / branch 问题

**修复**(`New-ClaudeSbx` 内 retry loop):

```powershell
$cloneCmd = "git clone --depth 1 --branch '$Ref' '$RepoUrl' /tmp/sbx-kit"
$rc = 1
for ($attempt = 1; $attempt -le 3; $attempt++) {
    # `rm -rf` 在沙箱内跑,清理上次残留
    $rc = Invoke-Sbx -Args @('exec', $Name, 'bash', '-lc', "rm -rf /tmp/sbx-kit && $cloneCmd")
    if ($rc -eq 0) { break }
    if ($attempt -lt 3) {
        Start-Sleep -Seconds 3
    }
}
if ($rc -ne 0) {
    Write-Host "[ERROR] git clone failed (exit $rc) after 3 attempts. ..."
    return
}
```

**为什么 3 次够了**:
- cold-start race 通常 < 1s
- `Start-Sleep -Seconds 3` 给 microVM 充足时间初始化
- 3 次 × 3s = **9s** 总开销,绝大多数情况 1 次成功

**用户**:
- 报错信息升级: `after 3 attempts` + 明确说"cold-start race, 重试或用 `-Source Local`"
- 不再让用户**猜** 3 个无关的可能原因

**注意**:
- 这是 `Source=GitHub` 模式特有的(`Source=Local` 走 base64 推,**不**需要 microVM 启动到稳定态)
- `Source=Local` 第一次 `sbx exec` 也是 cold-start,但只是 `mkdir` + `base64 -d > file` 三个 syscalls,出错概率极低
