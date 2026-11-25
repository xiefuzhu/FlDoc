# flDoc

flDoc 是一款支持离线阅读、全文与符号检索以及本地 RAG 问答的 Markdown 文档阅读器。它最初面向 Windows 10/11 打造悬浮置顶的编码伴侣体验，同时提供 macOS（Apple Silicon `arm64` / Intel `x86_64` 分架构包）与 Android（`arm64-v8a` 精简包）版本。

配合 AI Agent 预先将在线文档站点抓取并翻译为本地 Markdown 文档库，写代码时无需反复切换浏览器，即可在本地完成阅读、中英双语切换、极速检索与基于文档片段的 AI 提问。

## 下载与安装

前往 [GitHub Releases](https://github.com/xiefuzhu/FlDoc/releases) 下载对应平台安装包，并可通过 `SHA256SUMS.txt` 校验文件完整性：

| 平台与架构 | 发布产物 | 说明 |
|---|---|---|
| Windows 10/11 (x64) | `flDoc-Setup-<version>.exe` | Inno Setup 6 安装包，内置 `rg.exe`（ripgrep） |
| macOS 12+ (Apple Silicon / M 系列) | `flDoc-<version>-macos-arm64.zip` | 仅包含 `arm64` 架构的 `flDoc.app`，减小体积 |
| macOS 12+ (Intel) | `flDoc-<version>-macos-x86_64.zip` | 仅包含 `x86_64` 架构的 `flDoc.app`，减小体积 |
| Android (64 位 ARM / v8) | `flDoc-<version>-android-arm64-v8a.apk` | 仅包含 `arm64-v8a` 原生库，减小安装包体积 |
| 全平台校验和 | `SHA256SUMS.txt` | 所有发布产物的 SHA-256 校验值 |

### 安装注意事项

- **Windows**：离线 Mermaid 图表渲染依赖系统内置的 Microsoft Edge WebView2 Runtime；若系统未安装，Mermaid 代码块会自动降级为源码展示，不影响其他功能。
- **macOS**：`arm64` 与 `x86_64` 已拆分为独立架构包。当前构建采用临时签名（ad-hoc signing），尚未经过 Apple 公证；解压并将 `flDoc.app` 拖入「应用程序」后，如首次打开提示无法验证开发者或文件已损坏，可执行：
  ```bash
  xattr -cr /Applications/flDoc.app
  ```
  或在「系统设置 → 隐私与安全性」中点击允许打开。
- **Android**：仅支持 `arm64-v8a`（ARMv8 64 位）设备，不再打包 `armeabi-v7a` 与 `x86_64` 以显著缩小 APK 体积。CI 构建的 APK 使用调试密钥签名，不同构建之间覆盖安装若出现签名冲突，请先卸载旧版再安装。

[跨平台交互预览](doc/platform-preview.html) · [界面预览图](doc/platform-preview.png) · [Android 模拟器截图](doc/android-emulator-preview.png)

## 核心特性

- **双形态离线文档库**
  - 完整支持 `fldoc.library/1` 契约库：多版本切换、中英双语页面、自定义目录树、符号索引（`symbols.json`）、来源 URL 映射。
  - 原生兼容任意本地纯 Markdown 文件夹：自动按目录结构自然排序生成目录，并支持通过命令一键生成平铺版本 `manifest.json`（不改动原有 `.md` 文件）。
  - 支持配置多个文档库根目录；桌面端自动监听目录变更并增量刷新。
- **高性能 Markdown 阅读器**
  - 块级懒加载渲染，万行长文档流畅滚动。
  - 支持代码语法高亮与一键复制、GFM 表格、GitHub Alerts 提示块、任务列表、本地图片与 SVG、LaTeX 行内/块级公式、离线 Mermaid 图表渲染（Windows）。
  - 支持中/英文原文即时切换并保持当前阅读锚点，自动按标题锚点记忆阅读位置。
  - 站内与外链智能解析：点击原站点链接时优先跳转到本地已抓取的对应页面，未命中时再调用系统浏览器打开。
- **命令面板与离线检索**
  - `Ctrl+Shift+P` 唤起全局命令面板，支持拼音首字母模糊匹配（例如输入 `qjss` 匹配「全局搜索」），集中聚合导航、搜索、AI、阅读、窗口、文档库与首选项等全部命令并与设置页双向同步。
  - 支持基于 `ripgrep` 的极速全文搜索（支持大小写策略、全词、正则、当前库/全部库切换与上下文预览，回车跳转并高亮）。
  - 支持符号/函数搜索：优先检索 `symbols.json`（支持驼峰缩写与模糊匹配），缺失时自动使用代码块正则兜底。
- **AI 智能搜索与 RAG 问答**
  - 对话模型与嵌入模型独立配置：对话模型支持任意 OpenAI 兼容接口（OpenAI、DeepSeek、OpenRouter、硅基流动、Ollama 等）；嵌入模型默认预设硅基流动 `BAAI/bge-m3`（支持中英跨语言语义检索）。
  - 混合召回检索：查询关键词改写 + `ripgrep` 关键词召回 + SQLite 本地向量语义召回 + 符号索引，经 RRF 融合重排后输出块级结果。
  - 右侧可收起 AI 面板流式输出回答，支持可点击 `[n]` 引用角标直达对应段落、就当前页提问、多轮追问改写及本地 SQLite 会话历史。
- **导入工作流与契约校验**
  - 内置导入表单，根据来源 URL 自动推导抓取范围与库 ID，一键生成 Agent 抓取提示词并复制到剪贴板。
  - 内置 V01–V20 文档库契约校验器，快速定位目录结构、front matter、链接、图片与翻译缺失等问题。
- **桌面悬浮与 Fluent 体验（Windows）**
  - 无边框极简标题栏、窗口置顶开关与透明度调节（30%–100%）、窗口位置与大小记忆、关闭最小化到托盘、单实例激活、开机自启、亮/暗/跟随系统主题与自定义强调色/字体/行宽。

## 平台能力说明

| 能力 | Windows (x64) | macOS (`arm64` / `x86_64`) | Android (`arm64-v8a`) |
|---|---|---|---|
| Markdown 阅读、双形态库、中英切换、目录/符号检索 | 支持 | 支持 | 支持 |
| AI 智能搜索、向量索引与 RAG 流式问答 | 支持 | 支持 | 支持 |
| 无边框悬浮置顶、透明度、系统托盘、单实例、开机自启 | 支持 | 暂未启用 | 不适用 |
| 离线 Mermaid 渲染（WebView2） | 支持 | 降级显示源码 | 降级显示源码 |
| 全文搜索 | 内置 `rg.exe` | 内置离线搜索，可配置 `rg` | 内置离线搜索 |
| API Key 安全存储 | Windows 凭据管理器（DPAPI 兜底） | macOS 钥匙串（本地加密库兜底） | 应用私有安全存储 |
| 默认文档库根目录 | `%USERPROFILE%\flDocLibrary` | 应用沙盒 `Documents/flDocLibrary` | 应用外部存储 `flDocLibrary` |

## 快速开始

### 1. 首次启动

首次启动会弹出初始引导（OOBE），可直接确认或添加文档库根目录，并按需配置 AI 对话模型与嵌入模型；所有步骤均可跳过，之后随时在「设置」或命令面板中修改。

### 2. 跨平台分享文档库

1. 在 Windows、macOS 或 Android 的文档库列表打开目标库的操作菜单。选择「导出资料包」保存 `.fldoc.zip`，或选择「分享资料包」打开系统分享面板。
2. 在接收设备的 flDoc 首页选择「导入资料包」，打开收到的文件。导入后即可离线阅读和检索。

每个资料包保存一个文档库，包含 Markdown、原文与译文、版本目录、符号索引和本地资源。重复导入同一个资料包会复用已有副本，导入更新后的包会创建独立副本。

### 3. 从网站制作文档库（配合 AI Agent）

1. 从首页或命令面板选择「从网站制作文档库」。
2. 填写来源 URL（自动推导抓取范围 `scope` 与库 ID）、库名、版本、目标根目录及是否翻译为中文，点击「生成提示词并复制到剪贴板」。
3. 将提示词粘贴给具备网页抓取与本地文件写入能力的 AI Agent（如 Claude Code、Cursor、Codex、Pi 等）。
4. 抓取完成后，flDoc 会自动监听并刷新显示该文档库（移动端或手动变更可执行 **文档库: 重新加载全部文档库**）；可通过 **文档库: 校验文档库** 复核 V01–V20 规则。

### 4. 导入已有纯 Markdown 文件夹

1. 桌面端可在「设置 → 文档库」添加存放 Markdown 文件夹的上级根目录。Android 可在首页选择「导入文件夹」，选取一个 Markdown 文档库。
2. 任意包含 `.md` 文件的子目录都会自动识别为纯 Markdown 文档库。
3. 如需自定义目录树或升级为标准契约库，可执行 **文档库: 为此文件夹生成 manifest**（不会修改或移动任何 `.md` 文件）。

### 文档库标准目录结构（`fldoc.library/1`）

```text
<库根目录>/
└── <libId>/
    ├── manifest.json              # 库清单（schema: fldoc.library/1）
    ├── icon.png                   # 可选库图标
    └── <versionId>/               # 版本目录（如 3.x、latest）
        ├── pages/
        │   ├── index.md           # 中文/主显示页
        │   ├── index.en.md        # 原文页（翻译模式可选）
        │   └── getting-started.md
        ├── assets/                # 本地图片等静态资源（中英页面共用）
        ├── symbols.json           # API 符号索引（可选，推荐）
        ├── crawl-state.json       # 增量抓取状态（Agent 使用）
        └── crawl-report.md        # 抓取报告（校验中可查看）
```

完整契约规范详见 [`doc/03-文档库契约.md`](doc/03-文档库契约.md) 与 [`doc/04-导入提示词.md`](doc/04-导入提示词.md)。

## AI 与 RAG 配置

在「设置 → AI」或命令面板（`首选项: 配置对话模型` / `首选项: 配置嵌入模型`）中配置两类独立模型：

- **对话模型（Chat）**：兼容 OpenAI `/chat/completions` 与 `/models` 协议，可填写任意服务商的 `Base URL`、API Key 与模型名，并支持一键测试连接与拉取可用模型列表。
- **嵌入模型（Embedding）**：默认指向硅基流动 `https://api.siliconflow.cn/v1` 与 `BAAI/bge-m3`，也可切换为其他兼容 `/embeddings` 的接口。开启自动索引后，flDoc 会按标题边界切块并在后台增量构建本地 SQLite 向量索引。

## 基础快捷键

除以下固定基础快捷键外，其余全部功能均通过命令面板（`Ctrl+Shift+P`）统一触发：

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

完整命令清单见 [`doc/05-命令面板与快捷键.md`](doc/05-命令面板与快捷键.md)。

## 本地数据与隐私

- **文档库只读**：flDoc 仅读取文档库目录内容（显式执行「生成 manifest」除外），卸载应用或清理应用数据不会删除你的本地文档库文件。
- **应用数据目录**（可通过设置页「关于 flDoc」查看，也支持通过环境变量 `FLDOC_SUPPORT_DIR` 覆盖）：
  - `settings.json`：用户设置（不含 API Key）
  - `state.json`：窗口状态、侧边栏宽度、最近使用命令与最近位置
  - `fldoc.db`：SQLite 数据库（阅读位置、AI 会话历史、本地向量索引）
  - `cache/mermaid/`：按内容哈希与主题缓存的 Mermaid PNG 渲染图
  - `logs/`：本地运行日志（不记录 API Key 与请求正文）
- **密钥隔离**：API Key 存储在系统凭据存储（Windows 凭据管理器 / macOS 钥匙串 / Android 应用私有安全存储），不会明文写入 `settings.json`。

## 本地构建与打包

CI 环境基线：**Flutter 3.50.1 (stable)** / **Dart 3.14.0**。

### 通用检查与测试

```bash
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
```

### Windows (x64)

```powershell
# 构建 Windows Release（CMake 会自动将 third_party/ripgrep/rg.exe 复制到 exe 同目录）
flutter build windows --release

# 使用 Inno Setup 6 生成安装包（输出至 build/installer/flDoc-Setup-0.1.7.exe）
iscc /DAppVersion=0.1.7 installer\flDoc.iss
```

### macOS（拆分 `arm64` 与 `x86_64`）

```bash
# 仅构建 Apple Silicon (arm64)
FLUTTER_XCODE_ARCHS=arm64 FLUTTER_XCODE_ONLY_ACTIVE_ARCH=NO flutter build macos --release
ditto -c -k --sequesterRsrc --keepParent build/macos/Build/Products/Release/flDoc.app build/flDoc-macos-arm64.zip

# 清理中间产物后仅构建 Intel (x86_64)
rm -rf build/macos
FLUTTER_XCODE_ARCHS=x86_64 FLUTTER_XCODE_ONLY_ACTIVE_ARCH=NO flutter build macos --release
ditto -c -k --sequesterRsrc --keepParent build/macos/Build/Products/Release/flDoc.app build/flDoc-macos-x86_64.zip
```

### Android（仅 `arm64-v8a`）

[`android/app/build.gradle.kts`](android/app/build.gradle.kts) 已通过 `defaultConfig.ndk.abiFilters` 限定仅打包 `arm64-v8a`；构建时建议同时传入 `--target-platform android-arm64` 以跳过其他架构的 AOT 编译：

```bash
flutter build apk --release --target-platform android-arm64
# 输出：build/app/outputs/flutter-apk/app-release.apk
```

## GitHub Actions 与发版流程

工作流定义见 [`.github/workflows/build.yml`](.github/workflows/build.yml)：

- **持续集成**：推送到 `main`、向 `main` 发起 PR 或手动触发 `Build and Release` 时，会自动执行：
  1. Windows x64：版本校验、`flutter analyze`、`flutter test`、Release 构建与 Inno Setup 打包。
  2. Android `arm64-v8a`：单 ABI Release APK 构建，并校验 APK 内 `lib/` 仅包含 `arm64-v8a`。
  3. macOS `arm64` 与 `x86_64`：矩阵并行构建两个独立单架构包，校验包内全部 Mach-O 二进制为目标单架构并通过 `codesign --verify --deep --strict`。
- **Tag 自动发布**：发版前同步更新以下版本信息，提交并推送 `vX.Y.Z` 标签（标签须与 `pubspec.yaml` 中 `+` 前版本号一致）：
  - [`pubspec.yaml`](pubspec.yaml)（`version: X.Y.Z+BUILD`）
  - [`installer/flDoc.iss`](installer/flDoc.iss)（默认 `AppVersion`）
  - [`lib/features/palette/palette_overlay.dart`](lib/features/palette/palette_overlay.dart) 与 [`lib/features/settings/ui/settings_page.dart`](lib/features/settings/ui/settings_page.dart)（应用内版本显示）
  - [`README.md`](README.md)（如构建示例版本需同步）

  全部构建任务通过后，工作流会自动创建对应的 GitHub Release，附带 Windows 安装包、macOS `arm64` / `x86_64` ZIP、Android `arm64-v8a` APK 以及合并后的 `SHA256SUMS.txt`。

## 项目结构

```text
.
├── .github/workflows/build.yml   # Windows / macOS(arm64, x86_64) / Android(arm64-v8a) CI 与发布
├── lib/
│   ├── main.dart                 # 入口、路径、数据库、凭据存储与窗口服务初始化
│   ├── app/                      # FluentApp、主题、三栏 Shell、全局快捷键
│   ├── core/                     # 路径、SQLite、原子文件、日志、URL/Slug 工具
│   └── features/
│       ├── library/              # 文档库扫描监听、manifest/front matter 解析、V01-V20 校验
│       ├── reader/               # Markdown 解析、块级渲染、代码高亮、Mermaid、页内查找与导航
│       ├── sidebar/              # 目录树与版本切换侧边栏
│       ├── home/                 # 文档库卡片首页
│       ├── palette/              # 命令面板、拼音模糊匹配与命令注册表
│       ├── search/               # ripgrep 全文搜索与符号索引
│       ├── ai/                   # OpenAI 客户端、切块、向量索引、混合召回与 RAG 面板
│       ├── importer/             # 文档库导入表单与 Agent 提示词生成
│       ├── settings/             # 设置模型/持久化、跨平台凭据存储、设置页与 OOBE
│       └── window/               # Windows 悬浮窗、托盘、开机自启与 UI 状态记忆
├── assets/                       # 应用图标、导入提示词模板、离线 Mermaid 资源
├── third_party/ripgrep/          # Windows 打包内置 rg.exe 及 MIT 许可
├── installer/flDoc.iss           # Windows Inno Setup 6 安装脚本
├── windows/ macos/ android/      # 各平台原生工程配置
├── test/                         # 单元测试、Widget 测试、性能测试与样例库
└── doc/                          # 需求规格、架构设计与契约文档
```

## 设计文档

完整需求、架构设计与文档库契约见 [`doc/`](doc/README.md)：

- [需求规格](doc/01-需求规格.md)
- [架构设计](doc/02-架构设计.md)
- [文档库契约](doc/03-文档库契约.md)
- [导入提示词](doc/04-导入提示词.md)
- [命令面板与快捷键](doc/05-命令面板与快捷键.md)
- [AI 检索与 RAG](doc/06-AI检索与RAG.md)
- [开发计划与验收](doc/07-开发计划与验收.md)
