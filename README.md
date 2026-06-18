# Codex Usage Meter

一个给 Windows 上 Codex 个人账号使用的小工具：读取本机 Codex session 日志里的 `token_count` 事件，把最关键的剩余额度直接显示在任务栏右下角附近。

```text
Codex 剩余额度
5小时 90%   本周 96%
入 10.18M · 命中 8.92M · 出 184.2K
```

它不是官方个人账号额度 API，只是根据本机 Codex 日志做估算。适合想随时知道 5 小时窗口和本周窗口还剩多少的人。

## 特性

- 中文小浮窗，Codex 打开时显示，Codex 关闭时自动隐藏。
- 直接显示 `5小时剩余` 和 `本周剩余`，不需要把鼠标移上去。
- 小字显示当前线程累计输入、缓存命中和输出 token。
- 颜色提示压力：绿色正常，黄色偏紧，红色接近耗尽。
- 左键拖动可以移动位置，位置会保存到 `%APPDATA%\CodexUsageMeter\settings.json`。
- 右键菜单支持刷新、开关开机启动、打开 ChatGPT/Codex、查看 `/status` 校准说明、退出。
- 发布版可以直接运行单个 `CodexUsageWidget.exe`。
- 无需安装 npm/Python 依赖；源码构建使用 Windows 自带 .NET Framework C# 编译器。

## 快速使用

下载 release 后，双击：

```text
CodexUsageWidget.exe
```

如果你是从源码仓库下载，可以先双击：

```bat
build.bat
```

生成：

```text
dist\CodexUsageWidget.exe
```

然后双击 exe 运行。

兼容启动器也可用：

```bat
Start-CodexUsageTray.bat
```

它会优先启动 `dist\CodexUsageWidget.exe`；如果没有 exe，会回退到 PowerShell 脚本版。Codex 正在运行时，小浮窗会出现在任务栏右下角附近。

## 安装为开机启动

双击：

```bat
install.bat
```

它会创建一个启动文件夹快捷方式，并立即启动小工具。

## 卸载开机启动

双击：

```bat
uninstall.bat
```

它会删除启动文件夹快捷方式，并停止当前运行的小工具实例。

## 数据来源

工具读取：

```text
%USERPROFILE%\.codex\sessions\**\*.jsonl
```

并解析其中的 `event_msg` / `token_count` 事件：

- `rate_limits.primary.used_percent` -> 5 小时窗口已用百分比
- `rate_limits.secondary.used_percent` -> 本周窗口已用百分比
- `total_token_usage.input_tokens` -> 当前线程累计输入 token
- `total_token_usage.cached_input_tokens` -> 当前线程累计缓存命中输入 token
- `total_token_usage.output_tokens` -> 当前线程累计输出 token
- `total_token_usage.reasoning_output_tokens` -> 当前线程累计推理输出 token
- `total_token_usage.total_tokens` -> 当前线程累计总 token

显示时会换算为剩余百分比：

```text
剩余 = 100 - 已用百分比
```

## 校准方式

在 Codex 输入框里输入：

```text
/status
```

可以查看当前线程、上下文用量和 rate limits。CLI/TUI 用户也可以输入：

```text
/usage
```

## 注意

- 这是本地估算工具，不保证和 OpenAI 服务端最终计量完全一致。
- 如果 Codex 日志格式未来变化，可能需要更新解析逻辑。
- 当前只支持 Windows。

## License

MIT
