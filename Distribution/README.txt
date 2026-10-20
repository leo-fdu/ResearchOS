Research OS 2.0.17 — Shared edition
Apple Silicon (M-series) Mac • macOS 14 or later

安装 / Installation
1. 把 Research OS.app 拖到 Applications，然后弹出此磁盘映像。
   Drag Research OS.app into Applications, then eject this disk image.
2. 从 Applications 打开 Research OS。
   Open Research OS from Applications.
3. 按首次启动引导安装 Codex、登录自己的 ChatGPT 账号、选择自己的资料目录。
   Follow setup to install Codex, sign in with your own account and connect folders.

Python 与 PDF 处理依赖已内置，无需安装 Python、Homebrew 或 Xcode。
Python and PDF processing are included. No Python, Homebrew or Xcode installation needed.
Codex 可在引导页按需下载（约 133 MB，需要联网），无需管理员权限。
Codex is an optional download from OpenAI (~133 MB). No administrator access required.
已有 /opt/homebrew/bin 或 /usr/local/bin 中的 Codex 会优先使用。
An existing Codex in /opt/homebrew/bin or /usr/local/bin takes priority.
应用安装的 Codex 固定为 0.163.0；不自动升级。外部安装由其包管理器更新。
The app-managed Codex is pinned to 0.163.0 and does not auto-update.

首次打开被 macOS 拦截 / First-open security prompt
此私下分享版使用 ad hoc 签名，尚未经过 Apple Developer ID 签名和公证。
This private sharing build is ad hoc signed, not Developer ID signed or notarized.
确认应用来自你信任的朋友后，按 Apple 官方说明处理：
After confirming you trust the sender, follow Apple's instructions:
https://support.apple.com/en-us/102445
无需关闭 Gatekeeper 或系统安全保护。
Do not disable Gatekeeper or other system protections.

资料 / Your files
• 选择自己的 papers、notes、repositories、datasets 目录，文件保留原位置。
• Organize 需要选择包含 pdf 子目录的文献库；会重命名 PDF 并生成 markdown 阅读副本。
• 仓库和数据集只建立顶层入口；不会逐文件索引代码仓库或数据集。
• 没有预置私人路径、研究数据库、论文、聊天记录或账号凭据。
• 新建数据保存在 ~/Library/Application Support/Research OS 2/。
• 助手按需读取的内容会发送给模型服务。模型与额度由你自己的账号决定。
• 关闭窗口后，点击 Dock 图标可重新打开；Cmd+Q 完全退出。

可选 / Optional
扫描 PDF 的 OCR 需要自行安装 Tesseract；普通 PDF 阅读不需要。
Scanned-page OCR requires a separate Tesseract installation.
WidgetKit 扩展未包含在本分享版中；应用内桌面研究卡片保留。
This build excludes the WidgetKit extension; the desktop research card remains available.

源码与许可 / Source and licensing
Source/ResearchOS2-source.zip 包含本版应用源码和构建脚本。
Source/Dependency sources 包含所内置 PyMuPDF、PyMuPDF4LLM 的对应源码。
Source archives and original license notices are provided alongside the app.
See Source/LICENSE-NOTICE.txt for terms and upstream provenance.
本包不包括你的任何工作区导出或 Codex 登录信息。
No workspace export or Codex login information is included.
