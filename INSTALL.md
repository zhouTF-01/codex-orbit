# 安装与基本使用

当前版本 1.0.1，仅适用 Apple 芯片（M 系列）Mac、macOS 26.0 及以上。以下两种方式任选一种。

## 下载安装包

下载本仓库中的 `Codex-Orbit-1.0.1-macos-arm64.zip`。SHA-256：

```text
8d23a46dc4c677f357e19395fdfad724a8d6c5549a3cabb3b126b1f5be397a4e
```

## 方式 A：手动安装

1. 先安装并登录 Codex 桌面应用和 Codex CLI。CLI 安装参考 [官方说明](https://learn.chatgpt.com/docs/codex/cli)，登录可运行 `codex login`。
2. 解压 ZIP，将 `Codex Orbit.app` 拖入“应用程序”。
3. 先打开 Codex，再打开 Codex Orbit。桌面出现悬浮窗并显示额度后即可使用。

首次打开如提示无法验证开发者，确认安装包来自分享人且校验一致后，可在“系统设置 → 隐私与安全性 → 仍要打开”中对该应用放行。公司设备受策略限制时联系 IT；提示已损坏或将损坏电脑时先停止安装。参考 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

## 方式 B：交给自己的 Codex 安装

在本机 Codex 新建会话，把 ZIP 发给它；不能添加 ZIP 时，提供文件的本地完整路径。再复制以下话术：

```text
请帮我在这台 Mac 上安装并启动附件中的 Codex Orbit，直接完成可执行的步骤，直到桌面出现可用的悬浮窗。若附件不可读取，请先让我提供 ZIP 的本地完整路径。

1. 确认电脑是 Apple 芯片、macOS 26.0 或以上；不符合就停止并说明。
2. 核对 ZIP 的 SHA-256：
8d23a46dc4c677f357e19395fdfad724a8d6c5549a3cabb3b126b1f5be397a4e
不一致就停止，不要执行里面的程序。
3. 安全解压，将 Codex Orbit.app 安装到 /Applications；没有写入权限则使用 ~/Applications。若有同名旧版，先退出并备份再替换。不要覆盖 Codex 主应用或修改我的会话数据。
4. 检查并使用 ~/.local/bin/codex、/opt/homebrew/bin/codex 或 /usr/local/bin/codex 中的 Codex CLI。若没有 CLI，按官方指引 https://learn.chatgpt.com/docs/codex/cli 安装，并确保位于上述可识别位置。若未登录，引导我用自己的账号完成登录；不要读取或显示我的登录凭据。
5. 打开本机 Codex 桌面应用，再启动刚安装的 Codex Orbit。若窗口已隐藏，用菜单栏显示窗口或重新打开应用。
6. 核对安装位置、进程运行情况，并运行安装后 App 内的 Contents/MacOS/CodexOrbit --check 和 --check-activity，检查额度读取和会话监听；若工具支持读取悬浮窗界面，也确认窗口已显示。
7. 最终告诉我：安装位置、是否已启动、额度与会话连接是否正常。不要只完成解压就报告安装成功；检查失败就继续排查，无法解决时如实说明。

遇到 macOS 拦截或需要本人登录时，告诉我具体要点哪里，等我操作后继续。不要关闭系统安全保护、移除隔离属性，或代替我批准其他会话的操作。
```

正常环境下，完成后桌面会出现悬浮窗。账号登录和系统放行可能仍需本人点击。

## 基本使用

双击 Shift 隐藏 / 显示；拖动空白处移动；右上角三个点打开设置。红灯代表人工待办，黄灯代表进行中，绿灯代表未查看的完成记录。点击圆点清单并逐个打开会话，可清除对应红 / 绿提醒。

若提示未找到 CLI，检查 `codex --version` 和 `codex login status`。工具会在 `~/.local/bin/codex`、`/opt/homebrew/bin/codex`、`/usr/local/bin/codex` 查找 CLI。保持 Codex 桌面应用运行；仅支持本机根会话。

当前没有应用内升级；新版需要退出旧版后手动替换。卸载时退出并移除 App 即可，不会删除 Codex 会话。
