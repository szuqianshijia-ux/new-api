# Windows 原生部署与校园网 SSH 接入

本分支 `feat/windows-native-loopback` 增加 `BIND_ADDRESS` 环境变量。使用这里的启动脚本时，New API 只监听 `127.0.0.1:3000`，不需要公网 IP、域名、路由器端口映射，也不需要修改 Windows 防火墙。校园网必须允许成员电脑连接主机的 SSH 端口。

```text
成员电脑 127.0.0.1:18300
  -> SSH 到主机:22
  -> 主机 New API 127.0.0.1:3000
  -> 主机 CLIProxyAPI 127.0.0.1:8317
  -> Codex 账号池
```

## 构建

需要 PowerShell 7、Go 1.26.8、Bun 1.4.2（本机验证版本）。这套工具仅部署主机需要，成员电脑不需要。

```powershell
git clone --branch feat/windows-native-loopback https://github.com/szuqianshijia-ux/new-api.git
cd new-api
pwsh -File .\scripts\windows\Build-Native.ps1
```

Go 或 Bun 未在 PATH 中时，使用 `-GoPath` 和 `-BunPath` 指定可执行文件路径。本机已安装的工具位于 `D:\cc_token\build-tools\go\bin\go.exe` 和 `D:\cc_token\build-tools\bun-windows-x64\bun.exe`。

如果校园网无法连接 Go 默认依赖服务器，可配置可访问的模块镜像，例如 `go env -w GOPROXY=https://goproxy.cn,direct`。构建仍使用仓库的依赖版本锁定文件。

默认输出目录是源码目录旁的 `new-api-runtime`，可用 `-RuntimeDirectory` 改变。生成程序名为 `new-api-loopback.exe`；不要用官方未修改的 exe 替代，它不支持本分支的绑定配置。

## 启动与重启

先启动 CLIProxyAPI，再执行：

```powershell
cd D:\cc_token\new-api
pwsh -File .\scripts\windows\Start-Native.ps1
```

脚本在后台启动 New API，等待健康检查成功，并验证它没有监听非本机地址。关闭执行脚本的窗口不会停止服务。当前方案是手动启动，重启电脑后需要重新执行，不包含开机自启。

主机管理页面：<http://127.0.0.1:3000>。

查看监听：

```powershell
Get-NetTCPConnection -State Listen -LocalPort 3000
```

`LocalAddress` 必须为 `127.0.0.1`。停止 New API 后再启动可以使用：

```powershell
Get-Process new-api-loopback -ErrorAction SilentlyContinue | Stop-Process
pwsh -File .\scripts\windows\Start-Native.ps1
```

停止前结束成员调用，避免中断正在生成的回复。启动脚本发现端口占用时会报错，不会结束其他进程。

## 首次配置

新部署在网页初始化管理员账号。已有数据库不要重复初始化。

1. 关闭公开注册，由管理员创建成员。
2. 新建 OpenAI 渠道，API 地址为 `http://127.0.0.1:8317`，不要追加 `/v1`；密钥填 CLIProxyAPI 内部 API Key，分组为 `default`。
3. 初始模型使用已确认可用的 `gpt-5.5`。新增模型时必须检查上游可用性、渠道模型、成员令牌模型限制和定价。
4. 在用户管理中创建普通成员并分配额度。每位成员用自己的账号登录，在令牌管理中创建自己的有限额度令牌。
5. 用户总额度与令牌额度都会限制调用；关闭“无限额度”。New API 的计费额度不是 Codex 订阅的官方剩余额度，也不是原始 token 数。

本机部署使用 `localadmin` 管理员和 `member01` 测试成员。随机密码及令牌保存在 `D:\cc_token\new-api-runtime\credentials.json`；仅属于测试成员的信息另存在 `member01.json`。这些文件不在 Git 中，仅向测试成员提供 `member01.json` 中的信息，不要发送管理员凭证。

## 另一台电脑验证

在成员电脑的本地终端运行，不能在已经 SSH 登录的远程 shell 中运行：

```powershell
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:18300:127.0.0.1:3000 <SSH用户名>@<主机校园网IP>
```

窗口保持打开。无输出通常表示隧道在等待连接。成员浏览器打开 <http://127.0.0.1:18300>，使用自己的 New API 账号登录。主机 IP 变化后，需要修改 SSH 命令中的 IP。

PowerShell 7 中使用成员令牌进行实际请求：

```powershell
$secureKey = Read-Host '输入自己的 New API Key' -AsSecureString
$key = [Net.NetworkCredential]::new('', $secureKey).Password
$headers = @{ Authorization = "Bearer $key" }
Invoke-RestMethod http://127.0.0.1:18300/v1/models -Headers $headers
$body = @{ model = 'gpt-5.5'; input = 'Reply with exactly OK.'; max_output_tokens = 64 } | ConvertTo-Json
Invoke-RestMethod http://127.0.0.1:18300/v1/responses -Method Post -Headers $headers -ContentType 'application/json' -Body $body
Remove-Variable key, secureKey, headers
```

模型列表成功不代表生成已成功。必须看到生成回复，并在 New API 的使用日志和成员额度中确认扣减。

## 数据与迁移

- SQLite 数据库：`new-api-runtime/data/new-api.db`，保存账号、渠道、令牌和额度。备份前先停止服务，完整备份 `data` 目录。
- 日志：`new-api-runtime/logs`，启动失败时查看 `stderr.log` 和 `stdout.log`。
- 固定会话与加密密钥：`session-secret.xml`。它由 Windows DPAPI 加密，只能在原电脑的原 Windows 账户下解密。
- 迁移不能直接复制该 XML 后启动。先在原电脑、原账户中解密并安全转移原始密钥，在新电脑使用 `ConvertTo-SecureString ... -AsPlainText -Force | Export-Clixml` 重新生成同名文件，随后再启动。保持原密钥可保留依赖它的加密数据；不要把密钥粘贴到聊天或写进 Git。
- CLIProxyAPI 的 `auths` 和内部配置需要单独安全备份，与 New API 数据库不是同一份数据。

## 配置兼容性

只修改了 HTTP 监听地址的组装方式。未设置 `BIND_ADDRESS` 时仍兼容原项目的所有网卡监听；设置 `127.0.0.1` 时仅允许本机；IPv6 地址可设置为 `::1`（不加方括号）。安全部署应始终使用本分支启动脚本。

## 本机验收记录

2026-09-27，Windows 原生 New API + CLIProxyAPI，以 `gpt-5.5` 实际调用验证：

- 前端和 Windows 后端源码构建成功，管理首页 HTTP 200，浏览器正常渲染。
- 成员令牌模型列表、Responses 非流式、Chat Completions、Responses 流式均成功，生成内容为 `OK`。
- 最近一轮三次生成，用户额度与令牌额度均扣减 2529 个内部计费单位。
- 零额度测试令牌返回 HTTP 401，令牌状态变为额度耗尽；测试后已删除该临时令牌。此版本对耗尽令牌返回通用令牌无效错误，不能仅凭 401 判断密钥输入错误。
- 重启 New API 后，成员登录、原令牌、用户额度和令牌额度保持不变。
- New API 实际仅监听 `127.0.0.1:3000`，使用本机校园网地址连接 3000 被拒绝；Windows 防火墙保持原状。
- 另一台电脑通过 SSH 的最终验收由成员执行以上步骤；本机测试不替代远端验证。未通过耗尽真实 Codex 账号来测试上游账号切换。
