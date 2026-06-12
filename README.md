# Codex Usage Ball

Windows 桌面悬浮球，用来查看 Codex 的 5 小时与一周用量。

![Codex Usage Ball 桌面效果](assets/codex-usage-ball.png)

## 使用

双击 `Start-CodexUsageBall.vbs` 启动。

- 悬浮球上的百分比是 5 小时窗口剩余量。
- 拖动悬浮球可改变位置。
- 双击悬浮球展开或收起 5 小时和一周详情。
- 详情面板标题栏右侧可手动刷新。
- 右键可立即刷新或退出。
- 数据每 60 秒自动刷新。
- 可拖动到任意显示器。
- 右键可选择“全屏时自动隐藏”；该功能默认关闭。
- 面板打开后，点击桌面或其他应用会自动收起。

数据来自 `%USERPROFILE%\.codex\sessions` 中 Codex 自己记录的
`token_count.rate_limits`，不会上传账号信息，也不读取 `auth.json`。

如果显示 `--%`，先在 Codex 中发送一条消息，再右键选择“立即刷新”。

## 调试

在 PowerShell 中查看当前解析结果：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CodexUsageBall.ps1 -PrintUsage
```
