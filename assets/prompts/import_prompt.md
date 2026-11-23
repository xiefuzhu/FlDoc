# 任务：把在线文档站点抓取为 flDoc 本地文档库

你需要把一个在线文档站点抓取并转换为本地 Markdown 文档库，供离线阅读器 flDoc 使用。请严格遵守下面的目录与格式契约（fldoc.library/1），完成后执行自检并输出报告。

## 参数

- 来源 URL：{{SOURCE_URL}}
- 抓取范围：只抓取 URL 以 {{SCOPE}} 开头的页面
- 库 ID：{{LIB_ID}}
- 库名：{{LIB_NAME}}
- 版本：id={{VERSION_ID}}，显示名={{VERSION_LABEL}}
- 输出目录：{{LIB_DIR}}
- 版本目录：{{LIB_DIR}}/{{VERSION_ID}}
- 最大页数：{{MAX_PAGES}}
- 英文自动翻译为简体中文：{{TRANSLATE}}
- 模式：{{MODE}}
- 当前时间：{{NOW}}

## 一、抓取范围与顺序

1. 从来源 URL 所在站点的文档导航（侧边栏/目录）获取页面列表与层级顺序；导航不可得时从来源页起按链接广度优先发现页面。
2. 只抓取范围前缀内的页面，跳过：搜索页、标签页、博客/新闻列表、变更日志归档、站内重复的打印版、其他语言版本。
3. 遵守站点 robots.txt；请求间隔不少于 1 秒；页面数达到最大页数后停止，并在报告中注明未抓取的剩余页面。
4. 页面由 JavaScript 渲染、直接请求拿不到正文时，改用你可用的浏览器渲染抓取方式；仍不可得的记录为失败。

## 二、目录结构

```
{{LIB_DIR}}/
  manifest.json
  {{VERSION_ID}}/
    pages/                 页面，路径由 URL 推导
      index.md
      index.en.md
      <段>/<段>.md
      <段>/<段>.en.md
    assets/                图片等资源
    symbols.json
    crawl-state.json
    crawl-report.md
```

- 页面路径：去掉范围前缀后的 URL 路径段；路径段转为小写 kebab（仅 a-z 0-9 . _ -）；空路径或以 / 结尾映射为 index.md；去掉 .html 扩展名。
- 文件统一 UTF-8 无 BOM、LF 换行。

## 三、页面格式

每个页面产出两个文件（原文为中文或未开启翻译时只产出 xxx.md，translated 设为 false）：

中文页 xxx.md：

```markdown
---
title: <中文标题>
source_url: <原始 URL>
source_lang: en
lang: zh-CN
translated: true
original: <同名>.en.md
fetched_at: <抓取时间 ISO 8601 带时区>
source_sha256: <原文页正文的 SHA-256>
---

<正文，从 ## 级标题开始，不要重复写 # 标题>
```

原文页 xxx.en.md：

```markdown
---
title: <原文标题>
source_url: <原始 URL>
lang: en
fetched_at: <同上>
source_sha256: <同上>
---

<原文正文>
```

source_sha256 的计算对象：原文页 front matter 之后的正文全文（UTF-8 字节）。

### 正文转换规则

1. 只保留正文内容；删除导航栏、页脚、侧边栏、面包屑、广告、Cookie 提示、「编辑此页」、上一页/下一页、版本横幅、反馈组件。
2. 标题从 ## 开始，层级与原文一致；每个标题末尾加显式锚点 {#id}：id 由英文原标题转小写 kebab（仅 a-z 0-9 -），同页唯一，重复加 -2、-3。中文页与原文页对应标题使用完全相同的 id。示例：`## 安装依赖 {#install-dependencies}`。
3. 代码块一律使用围栏代码块并标注语言；代码内容、代码注释、命令行、配置项、文件名保持原样不翻译。
4. 提示块统一转换为 GitHub Alerts，类型限 NOTE / TIP / IMPORTANT / WARNING / CAUTION：
   > [!TIP]
   > 内容
5. 表格用 GFM 表格；合并单元格等复杂表格降级为列表。
6. 公式：行内 $...$，块级 $$...$$ 独占行。原站 Mermaid 源码保留为 mermaid 代码块。
7. 选项卡（Tabs）展开为依次排列的内容，每个选项卡前用 **选项卡名** 标注。
8. 内联 HTML 只允许 kbd、sub、sup、br、details、summary，其余转为 Markdown 或纯文本。

### 翻译规则（翻译开启时）

1. 翻译为自然、准确的简体中文技术文档风格，不增删信息，不加译注以外的解释。
2. 不翻译：代码块、行内代码、API/类/函数/参数名、包名、命令、文件路径、URL、front matter 的键、锚点 id。
3. 专有名词与术语保留英文（如 Provider、Widget、BuildContext）；通用术语首次出现时可写为「中文（English）」。
4. 链接文字与图片 alt 文本翻译，链接目标不变。
5. 同一术语全库译法保持一致；开始翻译前先列一份术语表，翻译时遵循。

### 链接与图片

1. 指向已抓取页面的链接改写为相对当前文件的路径，并带锚点：中文页指向 xxx.md，原文页指向 xxx.en.md。
2. 指向未抓取页面或站外的链接保留绝对 URL。
3. 图片下载到 {{VERSION_ID}}/assets/，文件名为「内容 SHA-256 前 8 位-原文件名小写 kebab.扩展名」，正文用相对当前文件的路径引用；中文页与原文页共用同一资源。超过 10 MB 的资源不下载，保留远程链接并在报告中记录。

## 四、manifest.json（最后写入）

```json
{
  "schema": "fldoc.library/1",
  "id": "{{LIB_ID}}",
  "name": "{{LIB_NAME}}",
  "description": "<一句话中文描述>",
  "homepage": "<站点首页>",
  "sourceLanguage": "<原文语言，如 en>",
  "displayLanguage": "zh-CN",
  "defaultVersion": "{{VERSION_ID}}",
  "updatedAt": "<写入时间>",
  "generator": "<你的名字或工具名>",
  "versions": [
    {
      "id": "{{VERSION_ID}}",
      "label": "{{VERSION_LABEL}}",
      "dir": "{{VERSION_ID}}",
      "sourceUrl": "{{SOURCE_URL}}",
      "scope": "{{SCOPE}}",
      "crawledAt": "<本次完成时间>",
      "pageCount": <中文页数量>,
      "translated": <是否存在 .en.md>,
      "toc": [
        { "title": "<中文标题>", "page": "pages/index.md" },
        { "title": "<中文章节名>", "children": [
          { "title": "<中文页面标题>", "page": "pages/<路径>.md" }
        ]}
      ]
    }
  ]
}
```

- toc 顺序与原站导航一致；章节可同时带 page；每个页面在 toc 中只出现一次；toc 只引用中文页（xxx.md）。
- 若 manifest.json 已存在且包含其他版本：只替换或追加 id 为 {{VERSION_ID}} 的版本条目，保留其他版本与库级字段（更新 updatedAt）。

## 五、symbols.json

收录文档中有专门讲解或代码示例的公开 API：

```json
{
  "schema": "fldoc.symbols/1",
  "symbols": [
    {
      "name": "<短名>",
      "qualifiedName": "<所属类型.短名，可选>",
      "kind": "class|function|method|property|constructor|enum|typedef|extension|mixin|widget|annotation|cli|config|other",
      "signature": "<签名原文，可选>",
      "page": "pages/<讲解该符号的中文页>.md",
      "anchor": "<页内锚点 id，可选>",
      "summary": "<一句话中文说明，可选>",
      "aliases": ["<常见写法，可选>"]
    }
  ]
}
```

## 六、crawl-state.json 与增量更新

```json
{
  "schema": "fldoc.crawlstate/1",
  "scope": "{{SCOPE}}",
  "pages": {
    "<规范化 URL>": {
      "page": "pages/<路径>.md",
      "sourceSha256": "<原文正文 SHA-256>",
      "etag": "<可选>",
      "lastModified": "<可选>",
      "fetchedAt": "<时间>",
      "status": "ok|removed|failed"
    }
  },
  "assets": { "<资源 URL>": "assets/<文件名>" }
}
```

URL 规范化：https、主机名小写去 www.、去 fragment、去 query（除非 query 决定内容）、去末尾 / 与 index.html、去 .html。

模式为「增量更新」时：

1. 读取已有 crawl-state.json 与 manifest.json。
2. 对每个页面重新抓取并转换原文，计算 source_sha256；与记录相同则跳过（不重新翻译），不同则重写原文页、重新翻译中文页、更新该页相关的 symbols 条目。
3. 新出现的页面按首次抓取处理并插入 toc 中对应位置。
4. 源站已不存在的页面：从 toc 移除，文件保留，status 记为 removed，并在报告中列出。
5. 已下载的资源按 URL 复用，不重复下载。
6. 保留未变化页面的文件不动（不要改写其 fetched_at）。

## 七、写入顺序

资源 → 原文页 → 中文页 → symbols.json → crawl-state.json → crawl-report.md → manifest.json。

## 八、完成前自检（全部通过后才算完成）

逐项检查并在报告中给出结果：

1. manifest.json 是合法 JSON，schema、id、defaultVersion、versions 字段齐全，id 等于目录名。
2. toc 引用的每个 page 文件存在，没有重复引用；pages/ 下没有未被 toc 引用的中文页（如有，说明原因或补入 toc）。
3. 每个页面 front matter 可解析，必填字段齐全；translated 为 true 时 original 文件存在且 source_url 一致。
4. 每个标题都有 {#id}，同页 id 唯一；中文页与原文页的 id 集合一致。
5. 所有相对链接指向的文件存在、锚点存在；所有本地图片存在。
6. 所有代码块已标注语言；代码块内容与原文逐字一致。
7. 中文页中不存在大段未翻译的英文正文（代码与术语除外）。
8. symbols.json 合法，每条的 page 存在、anchor 存在。
9. 没有使用白名单以外的 HTML 标签；文件均为 UTF-8 无 BOM。
10. 没有两个页面对应同一个规范化 URL。

发现问题先修复再复查；无法修复的写入报告。

## 九、crawl-report.md 与最终回复

在 {{VERSION_ID}}/crawl-report.md 写入并在最终回复中输出：

- 模式、开始/结束时间、范围
- 页面统计：新增 / 更新 / 未变化 / 移除 / 失败（失败附 URL 与原因）
- 资源统计：下载数、跳过的大文件
- 符号数量
- 术语表
- 自检结果（10 项逐条通过/未通过）
- 未抓取的剩余页面（达到最大页数时）

完成后提示用户：在 flDoc 中会自动刷新出现该库，可运行命令「文档库: 校验文档库」复核。
