# flDoc

flDoc 是一款面向 Windows 10/11 的桌面悬浮离线文档阅读器：由 AI Agent 预先将在线文档站点抓取、翻译为本地 Markdown 文档库，写代码时将 flDoc 置顶在屏幕一角，无需打开浏览器即可阅读、全文检索、查找 API 符号并基于本地文档向 AI 提问。

## 核心特性

- **Fluent Win11 桌面体验**：无边框极简标题栏、Mica 背景（Win10 自动退化）、窗口置顶与透明度（30%–100%）、记住位置与大小、最小化到托盘、单实例激活、开机自启。
- **双形态文档库**：完整支持契约格式（`fldoc.library/1`，多版本、中英双语、自定义目录树、符号索引）与任意纯 Markdown 文件夹；监听目录变化自动增量刷新；支持一键为纯 Markdown 库生成 `manifest.json`。
- **高性能阅读器**：块级懒加载渲染（万行长文不卡顿）、语法高亮与一键复制、GitHub Alerts、GFM 表格、任务列表、本地图片与 SVG、LaTeX 公式、离线 Mermaid 图表渲染、中/英即时切换并保持锚点、按标题锚点记忆阅读位置。
- **命令面板与离线检索**：`Ctrl+Shift+P` 打开命令面板（支持拼音首字母模糊匹配，如 `qjss` 匹配「全局搜索」）；内置 `ripgrep` 极速全文搜索、符号索引 + 代码块正则兜底、全部 60 项命令与设置页实时同步。
- **AI 智能搜索与 RAG 问答**：OpenAI 兼容对话模型 + 嵌入模型（默认硅基流动 `BAAI/bge-m3`），API Key 存储在 Windows 凭据管理器；支持关键词改写 + ripgrep + 向量语义 + 符号 RRF 混合召回、右侧可收起 AI 面板流式输出、可点击 `[n]` 引用角标、多轮追问与本地会话历史。
- **导入与契约校验**：内置导入表单自动生成 Agent 爬取提示词并复制到剪贴板；内置 V01–V20 契约校验器定位格式与翻译问题。

## 导入文档库流程

1. 按 `Ctrl+Shift+P` 执行 **文档库: 导入文档库**（或在 Home 末尾点击「导入文档库」卡片）。
2. 填写来源 URL（自动推导抓取范围与库 ID）、库名、版本、目标根目录与是否翻译，点击「生成提示词并复制到剪贴板」。
3. 将提示词粘贴给具备网页抓取与文件写入能力的 AI Agent（如 Claude Code、Cursor、Pi 等）。
4. 抓取完成后 flDoc 会自动监听并刷新显示该文档库，可通过 **文档库: 校验文档库** 复核 V01–V20 规则。

## 基础快捷键

全部功能均可通过命令面板（`Ctrl+Shift+P`）访问，仅保留以下固定基础快捷键：

| 快捷键 | 作用 | 作用域 |
|---|---|---|
| `Ctrl+Shift+P` | 打开 / 关闭命令面板 | 全局 |
| `Ctrl+F` | 本页查找 | 阅读页 |
| `Enter` / `Shift+Enter` | 下一个 / 上一个匹配 | 查找条 |
| `Ctrl+B` | 收起 / 展开侧边栏 | 全局（非输入框） |
| `Alt+←` / `Alt+→` | 后退 / 前进 | 全局（非输入框） |
| `Ctrl+=` / `Ctrl+-` / `Ctrl+0` | 放大 / 缩小 / 重置字号 | 全局 |
| `Esc` | 关闭命令面板 / 查找条 / 对话框 | 当前浮层 |
| `Enter` / `Shift+Enter` | 发送 / 换行 | AI 面板输入框 |

## 构建与打包

GitHub Actions 使用 Flutter 3.50.1 和 Dart 3.14.0。

```powershell
# 静态检查与测试
flutter analyze
flutter test

# 构建 Windows Release（自动将 third_party/ripgrep/rg.exe 复制到 exe 同目录）
flutter build windows --release

# 使用 Inno Setup 6 生成安装包（输出至 build/installer/flDoc-Setup-0.1.5.exe）
iscc /DAppVersion=0.1.5 installer\flDoc.iss
```

### GitHub Actions 发布

推送到 `main`、向 `main` 发起 PR，或手动运行 Build and Release，会执行静态分析、测试，并构建 Windows x64 安装程序、Android APK 和 macOS 通用应用 ZIP。各平台产物可从对应的 Actions 任务下载。

发布时先更新 `pubspec.yaml` 的版本和构建号、应用内版本显示和安装脚本的默认版本，再提交并推送 `vX.Y.Z` 标签。标签必须与 `pubspec.yaml` 中 `+` 前的版本一致。三个平台通过后，工作流会在同一个 GitHub Release 发布所有产物和 `SHA256SUMS.txt`。

Android APK 使用 CI 的调试密钥签名，不同构建的 APK 可能需要卸载旧版再安装。macOS ZIP 包含适用于 Apple Silicon 和 Intel 的 `flDoc.app`，采用临时签名，未经过 Apple 公证。

## 设计文档

完整需求与架构设计见 [`doc/`](doc/README.md)。
