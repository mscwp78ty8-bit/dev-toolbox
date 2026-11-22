# Markdown Translate Preview (Local Ollama)

用**本地 Ollama 模型**翻译当前 Markdown 文件，并在侧边打开只读预览。完全离线，不调用任何在线翻译服务，不向磁盘写入译文。

## 功能

- 命令 **`Translate README (Side Preview)`** / **`Translate Markdown (Side Preview)`**
- 译文以虚拟文档在编辑器右侧打开，标题为 `README.zh.md`，流式输出
- 保留 Markdown 结构：标题、表格、链接、代码围栏、路径、URL、shell 命令
- 可随时取消

## 前置条件

- VS Code 1.80+
- Ollama 运行中，且已有翻译模型（默认 `hy-mt`）

导入 Hunyuan-MT 1.8B 的示例：先把下面的内容保存为 `/tmp/Modelfile.hy`，再执行 `ollama create hy-mt -f /tmp/Modelfile.hy`。

```text
FROM /Users/you/llm-models/HY-MT1.5-1.8B-Q4_K_M.gguf
PARAMETER temperature 0.7
PARAMETER top_k 20
PARAMETER top_p 0.6
PARAMETER repeat_penalty 1.05
PARAMETER num_ctx 16384
PARAMETER num_predict 8192
```

## 使用

1. 打开任意 Markdown 文件；
2. `Cmd+Shift+P` → `Translate README (Side Preview)`（或右键编辑器选择同名菜单项）；
3. 右侧出现译文预览，完成后状态栏显示耗时。

## 配置

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
| `mdTranslate.baseUrl` | `http://127.0.0.1:11434/v1` | 任意 OpenAI 兼容接口 |
| `mdTranslate.model` | `hy-mt` | 模型名 |
| `mdTranslate.targetLanguage` | `zh-CN` | 目标语言 |
| `mdTranslate.maxChars` | `12000` | 超过该字符数则按标题分块翻译 |

## 打包

```bash
npm run package    # 生成 md-translate-preview-0.1.0.vsix
npm run reinstall  # 打包并安装到本地 VS Code
```

## License

MIT