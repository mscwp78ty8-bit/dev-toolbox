# dev-toolbox

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![VS Code](https://img.shields.io/badge/VS%20Code-%5E1.80-007ACC.svg)](https://code.visualstudio.com/)
[![Ollama](https://img.shields.io/badge/Ollama-local%20LLM-000000.svg)](https://ollama.com/)

我的个人工具集仓库。所有工具都以**本地运行、完全离线**为原则：不依赖第三方在线服务，不把你的文本发到任何外部服务器。

## 工具列表

| 工具 | 类型 | 说明 | 状态 |
|---|---|---|---|
| [md-translate-preview](./extensions/md-translate-preview) | VS Code 扩展 | 用本地 Ollama 模型把当前 Markdown 翻译成中文，并在侧边打开只读预览 | 可用 |
| [editor-title-actions](./extensions/editor-title-actions) | VS Code 扩展 | 在编辑器标题栏加一个 Toggle Panel 按钮，顶替原生的「分栏」按钮 | 可用 |
| [patch-vscode.js](./scripts/patch-vscode.js) | 补丁脚本 | 隐藏编辑器标题栏原生的「分栏」按钮（含备份 / 校验和 / 还原） | 可用 |

---

## md-translate-preview

一个约 200 行的本地小扩展：打开 `README.md`，一条命令把它翻成中文，译文在**右侧标签页流式出现**，不写入磁盘、不调用任何在线翻译接口。

### 特性

- **完全离线**：只请求本机 Ollama 的 OpenAI 兼容接口（`http://127.0.0.1:11434/v1`）
- **侧边预览**：译文以虚拟文档（`mdtrans://` scheme）在编辑器旁打开，标题为 `README.zh.md`
- **流式输出**：边翻译边显示，约 250ms 刷新一次，自动滚动跟随
- **不落盘**：虚拟文档无法保存，因此不会在仓库里多出一个 `.zh.md` 文件
- **保留 Markdown 结构**：标题层级、表格、链接、代码围栏、文件路径、URL、shell 命令都保持原样
- **可取消**：翻译进度通知上的取消按钮会立即中断请求

### 实测效果

以一份 8126 字符 / 210 行的英文 README 为例（模型 `hy-mt`，Apple Silicon GPU）：

| 指标 | 结果 |
|---|---|
| 耗时 | 约 39 秒 |
| 输出 | 5074 字符 / 209 行（与原文逐行对齐） |
| 代码围栏 | 输入 12 个 → 输出 12 个（完全一致） |
| 命令保留 | `git clone`、`export MT_MODEL=...` 等原样保留，仅代码块内注释被翻译 |

### 前置条件

1. **VS Code 1.80 及以上**
2. **Ollama 已安装并在运行**（`ollama ps` 能正常输出即可）
3. 一个可用的翻译模型，推荐 Hunyuan-MT 1.8B：

```bash
# 1) 准备 GGUF 文件，例如 ~/llm-models/HY-MT1.5-1.8B-Q4_K_M.gguf

# 2) 写 Modelfile（num_ctx 必须调大，否则长文档会被截断）
cat > /tmp/Modelfile.hy <<'EOF'
FROM /Users/you/llm-models/HY-MT1.5-1.8B-Q4_K_M.gguf
PARAMETER temperature 0.7
PARAMETER top_k 20
PARAMETER top_p 0.6
PARAMETER repeat_penalty 1.05
PARAMETER num_ctx 16384
PARAMETER num_predict 8192
EOF

# 3) 导入
ollama create hy-mt -f /tmp/Modelfile.hy
```

> 也可以用任何其他模型（如 `qwen2.5:14b`），只要通过 `mdTranslate.model` 配置项改掉模型名即可。

### 安装

```bash
git clone <this-repo> && cd dev-toolbox
code --install-extension extensions/md-translate-preview/md-translate-preview-0.1.0.vsix
```

若提示 `zsh: command not found: code`，说明 VS Code 的命令行工具没进 PATH，可以这样补上（macOS，无需 sudo）：

```bash
ln -sf "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" /opt/homebrew/bin/code
```

或在 VS Code 内按 `Cmd+Shift+P` → 输入 `Shell Command: Install 'code' command in PATH`。

安装后**重载窗口**（`Cmd+Shift+P` → `Developer: Reload Window`）让扩展生效。

### 使用

1. 打开任意 Markdown 文件（例如英文 README）；
2. `Cmd+Shift+P` → **`Translate README (Side Preview)`**；也可以右键编辑器，在菜单里点同名项；
3. 右侧会打开 `README.zh.md` 只读预览，译文流式写入，完成后状态栏提示耗时。

命令面板里另有一个通用命令 **`Translate Markdown (Side Preview)`**，行为完全相同，适合翻译非 README 的 Markdown。

### 配置项

在 `settings.json` 中配置，全部有默认值：

```json
{
  "mdTranslate.baseUrl": "http://127.0.0.1:11434/v1",
  "mdTranslate.model": "hy-mt",
  "mdTranslate.targetLanguage": "zh-CN",
  "mdTranslate.maxChars": 12000
}
```

| 配置 | 默认值 | 说明 |
|---|---|---|
| `mdTranslate.baseUrl` | `http://127.0.0.1:11434/v1` | 任意 OpenAI 兼容接口地址（Ollama、LM Studio、llama.cpp server 等） |
| `mdTranslate.model` | `hy-mt` | 模型名 |
| `mdTranslate.targetLanguage` | `zh-CN` | 目标语言，HY-MT 支持 33 种语言（如 `ja`、`ko`、`en`） |
| `mdTranslate.maxChars` | `12000` | 单次请求最大字符数；超过则按标题分块翻译 |

### 工作原理

- **虚拟文档 + 内容提供者**：扩展注册 `mdtrans` scheme 的 `TextDocumentContentProvider`，译文只存在内存 Map 里，通过 `EventEmitter` 通知编辑器刷新。
- **SSE 流式解析**：请求 `stream: true`，逐行解析 `data: {...}` 增量，累积到缓冲后再节流推给编辑器（250ms），避免每个 token 都重绘。
- **分块策略**：文本不超过 `maxChars` 时**整篇一次请求**（质量最好）；超过时按 `#` / `##` / `###` 标题边界切块，保证不在标题与正文之间断开。
- **提示词刻意保持简短**：HY-MT 是句段级翻译模型，过长的英文约束反而会让它输出顺序错乱或复读原文。

### 常见问题

**Q：提示「无法连接 http://127.0.0.1:11434/v1」**
Ollama 没在运行。执行 `ollama serve`，或用 `ollama ps` 确认服务状态。

**Q：翻译到一半就断了 / 只翻了前半部分**
Ollama 的 `num_ctx` 太小。按上面的 Modelfile 用 `PARAMETER num_ctx 16384` 重新 `ollama create`。

**Q：译文顺序错乱、出现大量重复、代码围栏数量暴涨**
分块切点落在了悬空标题上，模型开始复读输入。把 `mdTranslate.maxChars` 调大（例如 `20000`）让它整篇一次翻译。

**Q：想翻成日文 / 韩文**
把 `mdTranslate.targetLanguage` 改成 `ja` / `ko`，其余不变。

### 开发

```bash
cd extensions/md-translate-preview
npm run package     # 打包成 md-translate-preview-0.1.0.vsix
npm run reinstall   # 重新安装到本地 VS Code（--force 覆盖旧版本）
```

扩展没有任何运行时依赖，只有 `extension.js` + `package.json` 两个源文件。

---

## editor-title-actions

一个十来行逻辑的小扩展，把编辑器标题栏右侧那个占地方的**原生「分栏」按钮**换成一个 **Toggle Panel** 按钮。

背景：分栏按钮（`workbench.action.splitEditorRight`）是 VS Code 内核直接注册到 `editor/title` 菜单里的，扩展 API 只能新增菜单项、**没有删除他人菜单项的能力**。所以这件事必须拆成两半：

| 目标 | 手段 |
|---|---|
| 加一个 Toggle Panel 按钮 | 本扩展（官方支持的菜单贡献） |
| 去掉原生分栏按钮 | [patch-vscode.js](#scriptspatch-vscodejs)（CSS 补丁） |

### 特性

- 标题栏右上角出现一个 `$(layout-panel)` 图标按钮，点击即收起 / 展开底部面板（终端、问题、输出、调试控制台）
- 菜单排序用 `navigation@100001`，正好落在原生分栏按钮（内核里 `order: 1e5`）之后一位，视觉上就是"原位替换"
- 只转发 `workbench.action.togglePanel`，没有任何额外逻辑，也不会拖慢启动
- 分栏能力本身**不受影响**：`Cmd+\` 快捷键、`...` 下拉菜单里的分栏项都照常可用

### 安装

```bash
cd extensions/editor-title-actions
npm run package     # 打包成 editor-title-actions-0.1.0.vsix
npm run reinstall   # 打包并安装到本地 VS Code（--force 覆盖旧版本）
```

安装后重载窗口（`Cmd+Shift+P` → `Developer: Reload Window`）。

### 实现要点

- `"icon": "$(layout-panel)"` 用的是 codicon 内置图标，不需要附带任何图片资源
- `"group": "navigation"` 决定它渲染成标题栏上的**图标按钮**，而不是收进 `...` 下拉菜单
- 没有写 `when` 条件，因此任何编辑器（含 webview、notebook、diff）都会显示这个按钮；若只想在文本编辑器显示，加 `"when": "activeEditor"` 即可

---

## scripts/patch-vscode.js

把原生「分栏」按钮从编辑器标题栏彻底隐藏掉。因为改的是 VS Code 安装目录里的文件，脚本把**备份、校验和、还原**都做全了，可以随时回滚。

### 用法

```bash
node scripts/patch-vscode.js --dry-run     # 只打印将要做的改动，不写文件
node scripts/patch-vscode.js               # 应用（幂等，可重复执行）
node scripts/patch-vscode.js --revert      # 还原到打补丁前的原始文件
node scripts/patch-vscode.js --app <path>  # 指定其他安装路径（默认 /Applications/Visual Studio Code.app）
```

改完在 VS Code 里执行 `Developer: Reload Window` 生效。

### 它改了什么

1. 备份 `Contents/Resources/app/out/vs/workbench/workbench.desktop.main.css` 到 `scripts/.backup/`（已 gitignore）
2. 在 CSS 末尾追加一段带起止标记的样式，用 `:has()` 精准匹配分栏图标：

```css
.monaco-workbench .part.editor > .content .editor-group-container > .title
  .editor-toolbars .action-item:has(.codicon-split-horizontal),
.monaco-workbench .part.editor > .content .editor-group-container > .title
  .editor-toolbars .action-item:has(.codicon-split-vertical) {
  display: none !important;
}
```

3. 重算该文件的 SHA-256 并写回 `product.json` 的 `checksums`，避免启动时弹出「安装已在磁盘上被修改」

### 几个踩过的坑

- **校验和格式**：`product.json` 里的值是**去掉 `=` 填充**的 base64（对比 `preload.js`、`extensionHostProcess.js` 等条目即可验证）。写成带填充的版本会导致启动时弹警告。
- **为什么匹配图标类名而不是 `aria-label`**：`aria-label` 随界面语言变化，`codicon-split-horizontal` / `codicon-split-vertical` 是稳定类名，中英文界面都能命中。
- **`--revert` 有保护**：若 CSS 里找不到补丁标记、且内容与备份不一致（典型情况是已被升级覆盖），脚本会中止而不是强行覆盖，避免误伤新版本文件。
- **按钮图标不随面板开合变色**：`vscode` API 没有暴露面板可见性的上下文键，只能做成静态图标。

### 维护

- **VS Code 升级会覆盖 CSS**，升级后重跑一次 `node scripts/patch-vscode.js` 即可。脚本会检测版本变化，以当前文件为新基线重建备份，不会拿旧备份覆盖新版本。
- **改了 CSS 选择器**：直接重跑，脚本会比对标记块内容并就地替换，不会重复追加。

---

## 目录结构

```
dev-toolbox/
├── README.md
├── LICENSE
├── .gitignore
├── scripts/
│   └── patch-vscode.js          # 隐藏标题栏分栏按钮（备份 / 校验和 / 还原）
└── extensions/
    ├── md-translate-preview/
    │   ├── extension.js         # 全部逻辑
    │   ├── package.json         # 扩展清单（命令 / 配置项）
    │   ├── .vscodeignore        # 打包排除规则
    │   └── README.md            # 扩展市场展示用说明
    └── editor-title-actions/
        ├── extension.js         # 转发 workbench.action.togglePanel
        ├── package.json         # 命令 + editor/title 菜单贡献
        └── .vscodeignore
```

约定：

- `extensions/` 放 VS Code 扩展，每个子目录一个独立扩展；
- `scripts/` 放本机环境相关的补丁 / 运维脚本，需要改系统文件的脚本必须自带备份与还原；
- 以后若有纯工具类脚本，放在 `tools/` 下。

## Roadmap

- [ ] 支持「打开 Markdown 即自动翻译」的可选开关
- [ ] 译文缓存，重复翻译同一文件时秒开
- [ ] 发布到 VS Code Marketplace（需替换 `package.json` 里的 `publisher` 为自己的 ID）
- [ ] Toggle Panel 图标随面板开合状态切换（需监听面板 DOM，当前 API 未暴露可见性上下文键）

## License

[MIT](./LICENSE)

---

## English Summary

`dev-toolbox` is a personal toolbox repo for fully offline tools. It currently ships three things:

- **md-translate-preview** — a ~200-line VS Code extension that translates the current Markdown file with a local Ollama model and opens a read-only side preview — no cloud services, no files written to disk.
- **editor-title-actions** — a tiny VS Code extension that puts a **Toggle Panel** button (`$(layout-panel)`) into the editor title bar, at the exact slot where the built-in *Split Editor* button used to be.
- **scripts/patch-vscode.js** — a patch script that hides the built-in *Split Editor* button. VS Code registers it in `editor/title` from the core, and extension APIs cannot remove other extensions' menu items, so hiding it has to be done at the CSS level. The script backs up the original stylesheet, appends a `:has()`-scoped rule, and rewrites the `product.json` checksum so VS Code does not warn about a modified installation.

```bash
# extension 1: translate
code --install-extension extensions/md-translate-preview/md-translate-preview-0.1.0.vsix

# extension 2: toggle panel button
code --install-extension extensions/editor-title-actions/editor-title-actions-0.1.0.vsix

# hide the native split button (idempotent, revertable)
node scripts/patch-vscode.js
node scripts/patch-vscode.js --revert
```

After installing, run **Developer: Reload Window**. The translation command is **`Translate README (Side Preview)`**; its default endpoint is `http://127.0.0.1:11434/v1` and default model is `hy-mt`. See the Chinese sections above for configuration and troubleshooting.