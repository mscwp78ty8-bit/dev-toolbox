const vscode = require('vscode');
const path = require('path');

const SCHEME = 'mdtrans';
const store = new Map();
const emitter = new vscode.EventEmitter();

const contentProvider = {
  onDidChange: emitter.event,
  provideTextDocumentContent(uri) {
    return store.get(uri.toString()) ?? '';
  },
};

function config() {
  const c = vscode.workspace.getConfiguration('mdTranslate');
  return {
    baseUrl: String(c.get('baseUrl', 'http://127.0.0.1:11434/v1')).replace(/\/+$/, ''),
    model: c.get('model', 'hy-mt'),
    target: c.get('targetLanguage', 'zh-CN'),
    maxChars: Math.max(1000, Number(c.get('maxChars', 12000))),
  };
}

function systemPrompt(target) {
  return (
    `You are a professional translator. Translate the user's text into ${target}. ` +
    'Output ONLY the translated text. Do NOT add explanations, notes, alternatives, or any other content. ' +
    'Preserve the original formatting, line breaks, and paragraph structure as much as possible.'
  );
}

function splitAtHeadings(text, size) {
  const lines = text.split('\n');
  const sections = [];
  let cur = [];
  let inFence = false;
  for (const line of lines) {
    if (/^\s*(```|~~~)/.test(line)) inFence = !inFence;
    if (!inFence && /^#{1,3} /.test(line) && cur.length) {
      sections.push(cur.join('\n'));
      cur = [];
    }
    cur.push(line);
  }
  if (cur.length) sections.push(cur.join('\n'));

  const chunks = [];
  let group = [];
  let len = 0;
  for (const section of sections) {
    if (len + section.length > size && group.length) {
      chunks.push(group.join('\n\n'));
      group = [];
      len = 0;
    }
    group.push(section);
    len += section.length + 2;
  }
  if (group.length) chunks.push(group.join('\n\n'));
  return chunks;
}

function planChunks(text, maxChars) {
  if (text.length <= maxChars) return [text];
  return splitAtHeadings(text, maxChars);
}

async function streamChunk(text, onDelta, signal) {
  const { baseUrl, model, target } = config();
  let res;
  try {
    res = await fetch(`${baseUrl}/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ollama' },
      body: JSON.stringify({
        model,
        stream: true,
        temperature: 0.2,
        messages: [
          { role: 'system', content: systemPrompt(target) },
          { role: 'user', content: text },
        ],
      }),
      signal,
    });
  } catch (err) {
    throw new Error(`无法连接 ${baseUrl}：${err.message}（确认 ollama 已运行且模型 ${model} 存在）`);
  }
  if (!res.ok) throw new Error(`HTTP ${res.status} ${res.statusText}: ${(await res.text()).slice(0, 300)}`);
  if (!res.body) throw new Error('当前 Ollama 不支持流式响应');

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buf = '';
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    const lines = buf.split('\n');
    buf = lines.pop() ?? '';
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      const payload = trimmed.slice(5).trim();
      if (!payload || payload === '[DONE]') continue;
      try {
        const delta = JSON.parse(payload).choices?.[0]?.delta?.content;
        if (delta) onDelta(delta);
      } catch {
        /* 忽略心跳等非 JSON 行 */
      }
    }
  }
}

async function translateToSidePreview() {
  const source = vscode.window.activeTextEditor;
  if (!source) {
    vscode.window.showWarningMessage('请先打开一个 Markdown 文件。');
    return;
  }
  const doc = source.document;
  const base = path.basename(doc.fileName || 'untitled.md');
  const outName = base.replace(/\.(md|markdown|mdx)$/i, '') + '.zh.md';
  const outUri = vscode.Uri.parse(
    `${SCHEME}:/${path.join(path.dirname(doc.fileName || outName), outName)}`
  );

  const cfg = config();
  const text = doc.getText();
  const chunks = planChunks(text, cfg.maxChars);
  if (!chunks.length) {
    vscode.window.showWarningMessage('当前文件没有可翻译的内容。');
    return;
  }

  store.set(outUri.toString(), `> 正在翻译 ${base} …（0/${chunks.length}）\n`);
  emitter.fire(outUri);
  const outEditor = await vscode.window.showTextDocument(outUri, {
    viewColumn: vscode.ViewColumn.Beside,
    preview: true,
    preserveFocus: false,
  });

  let acc = '';
  let timer;
  const flush = () => {
    store.set(outUri.toString(), acc);
    emitter.fire(outUri);
    setTimeout(() => {
      const last = Math.max(0, outEditor.document.lineCount - 1);
      outEditor.revealRange(new vscode.Range(last, 0, last, 0), vscode.TextEditorRevealType.Default);
    }, 80);
  };

  const cts = new vscode.CancellationTokenSource();
  const ac = new AbortController();
  cts.token.onCancellationRequested(() => ac.abort());
  const started = Date.now();

  try {
    await vscode.window.withProgress(
      {
        location: vscode.ProgressLocation.Notification,
        title: `翻译 ${outName}`,
        cancellable: true,
      },
      async (progress, token) => {
        token.onCancellationRequested(() => cts.cancel());
        for (let i = 0; i < chunks.length; i++) {
          progress.report({ message: `${i + 1}/${chunks.length}`, increment: 100 / chunks.length });
          if (i > 0) acc = acc.replace(/\n*$/, '\n\n');
          await streamChunk(
            chunks[i],
            (delta) => {
              acc += delta;
              if (!timer) {
                timer = setTimeout(() => {
                  timer = undefined;
                  flush();
                }, 250);
              }
            },
            ac.signal
          );
          flush();
        }
      }
    );
    flush();
    vscode.window.setStatusBarMessage(`翻译完成 · ${Math.round((Date.now() - started) / 1000)}s`, 4000);
  } catch (err) {
    if (ac.signal.aborted) {
      vscode.window.setStatusBarMessage('翻译已取消', 3000);
      return;
    }
    throw err;
  } finally {
    cts.dispose();
  }
}

function activate(context) {
  const run = () =>
    translateToSidePreview().catch((e) => vscode.window.showErrorMessage(`翻译失败: ${e.message}`));
  context.subscriptions.push(
    vscode.workspace.registerTextDocumentContentProvider(SCHEME, contentProvider),
    emitter,
    vscode.commands.registerCommand('mdTranslate.translateReadme', run),
    vscode.commands.registerCommand('mdTranslate.translateMarkdown', run)
  );
}

function deactivate() {}

module.exports = { activate, deactivate };