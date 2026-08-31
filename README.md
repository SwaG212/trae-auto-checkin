# TRAE 自动签到

Windows 后台自动完成 TRAE SOLO CN 每日签到。程序直接读取 TRAE 当前用户的本地登录状态，不保存 Token，也不需要启动 TRAE 或浏览器。

## 工作方式

- Windows 用户登录 3 分钟后由任务计划程序静默运行
- 先查询今日签到状态，未签到时再领取 Credits
- 最多尝试 3 次，每次间隔 2 分钟
- 通过 Windows 通知显示成功、已签到或失败结果
- 登录过期后安全退出，需要手动打开 TRAE 重新登录

## 环境要求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1
- 已安装并登录 **TRAE SOLO CN**，账号类型为 `marscode`
- 能访问 `https://api.trae.cn`

脚本从 `%APPDATA%\TRAE SOLO CN` 读取登录状态，因此 TRAE 安装在哪个磁盘都不影响部署。

## 部署

打开 PowerShell，执行：

```powershell
git clone https://github.com/SwaG212/trae-auto-checkin.git
cd trae-auto-checkin
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

安装脚本会：

1. 将主脚本复制到 `%LOCALAPPDATA%\TraeAutoCheckin`。
2. 创建当前用户的 `TRAE Auto Checkin` 计划任务。
3. 设置为登录 Windows 3 分钟后静默运行；已有实例运行时不重复启动。

不需要管理员权限。若希望登录后延迟 5 分钟运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -DelayMinutes 5
```

再次运行安装命令即可覆盖更新脚本和计划任务。

## 验证

安装完成后可立即触发一次：

```powershell
Start-ScheduledTask -TaskName 'TRAE Auto Checkin'
Start-Sleep -Seconds 5
Get-ScheduledTaskInfo -TaskName 'TRAE Auto Checkin' |
    Select-Object LastRunTime, LastTaskResult
```

`LastTaskResult` 为 `0` 表示签到成功或今日已经签到。若脚本正在进行服务繁忙重试，请稍后再查询。

也可以在前台直接运行以查看输出：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TRAE-AutoCheckin.ps1
```

## 卸载

在仓库目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

这会删除计划任务和 `%LOCALAPPDATA%\TraeAutoCheckin` 中的已安装脚本，不会修改 TRAE 的程序或用户数据。

## 安全说明

- 仓库不包含账号、Token、设备 ID 或 Cookie。
- 登录凭据只在脚本运行期间保留在内存中。
- 脚本只读取当前 Windows 用户的 TRAE 本地数据，并请求 TRAE 官方域名。
- 本项目依赖 TRAE 当前的本地存储格式和接口，TRAE 更新后可能失效。
- 仅应用于你自己的账号；使用前请确认符合 TRAE 的服务条款和活动规则。

## 常见问题

### 提示“TRAE 尚未登录”或“登录已过期”

打开 TRAE SOLO CN，重新登录后再运行计划任务。

### 没有收到通知

检查 Windows 的“通知”设置是否允许 TRAE 发送通知，并确认计划任务使用当前登录用户运行。

### 返回业务码 9074

表示参与用户较多、服务繁忙。脚本会按内置策略自动重试，无需重复启动。
