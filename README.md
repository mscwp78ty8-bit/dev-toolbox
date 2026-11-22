# dev-toolbox

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![VS Code](https://img.shields.io/badge/VS%20Code-%5E1.80-007ACC.svg)](https://code.visualstudio.com/)
[![Ollama](https://img.shields.io/badge/Ollama-local%20LLM-000000.svg)](https://ollama.com/)

我的个人工具集仓库。所有工具都以**本地运行、完全离线**为原则：不依赖第三方在线服务，不把你的文本发到任何外部服务器。

## 工具列表

| 工具 | 类型 | 说明 | 状态 |
|---|---|---|---|
| [md-translate-preview](./extensions/md-translate-preview) | VS Code 扩展 | 用本地 Ollama 模型把当前 Markdown 翻译成中文，并在侧边打开只读预览 | 可用 |

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

## 目录结构

```
dev-toolbox/
├── README.md
├── LICENSE
├── .gitignore
└── extensions/
    └── md-translate-preview/
        ├── extension.js       # 全部逻辑
        ├── package.json       # 扩展清单（命令 / 配置项）
        ├── .vscodeignore      # 打包排除规则
        └── README.md          # 扩展市场展示用说明
```

约定：

- `extensions/` 放 VS Code 扩展，每个子目录一个独立扩展；
- 以后若有纯脚本类工具，放在 `tools/` 下。

## Roadmap

- [ ] 支持「打开 Markdown 即自动翻译」的可选开关
- [ ] 译文缓存，重复翻译同一文件时秒开
- [ ] 发布到 VS Code Marketplace（需替换 `package.json` 里的 `publisher` 为自己的 ID）

## License

[MIT](./LICENSE)

---

## English Summary

`dev-toolbox` is a personal toolbox repo for fully offline tools. The first tool, **md-translate-preview**, is a ~200-line VS Code extension that translates the current Markdown file with a local Ollama model and opens a read-only side preview — no cloud services, no files written to disk.

```bash
code --install-extension extensions/md-translate-preview/md-translate-preview-0.1.0.vsix
```

Then run the command **`Translate README (Side Preview)`** from the Command Palette. The default endpoint is `http://127.0.0.1:11434/v1` and the default model is `hy-mt`. See the Chinese sections above for configuration and troubleshooting.
