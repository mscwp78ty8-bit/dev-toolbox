#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DEFAULT_APP = '/Applications/Visual Studio Code.app';
const CSS_REL = ['Contents', 'Resources', 'app', 'out', 'vs', 'workbench', 'workbench.desktop.main.css'];
const PRODUCT_REL = ['Contents', 'Resources', 'app', 'product.json'];
const CSS_KEY = 'vs/workbench/workbench.desktop.main.css';
const BACKUP_DIR = path.join(__dirname, '.backup');
const BACKUP_CSS = path.join(BACKUP_DIR, 'workbench.desktop.main.css.orig');
const BACKUP_META = path.join(BACKUP_DIR, 'meta.json');

const MARK_BEGIN = '/* === dev-toolbox: hide editor split buttons (start) === */';
const MARK_END = '/* === dev-toolbox: hide editor split buttons (end) === */';

const CSS_BLOCK = [
  MARK_BEGIN,
  '.monaco-workbench .part.editor > .content .editor-group-container > .title .editor-toolbars .action-item:has(.codicon-split-horizontal),',
  '.monaco-workbench .part.editor > .content .editor-group-container > .title .editor-toolbars .action-item:has(.codicon-split-vertical) {',
  '\tdisplay: none !important;',
  '}',
  MARK_END,
  '',
].join('\n');

function parseArgs(argv) {
  const opts = { app: DEFAULT_APP, revert: false, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--revert') opts.revert = true;
    else if (a === '--dry-run') opts.dryRun = true;
    else if (a === '--app') opts.app = path.resolve(argv[++i]);
    else if (a.startsWith('--app=')) opts.app = path.resolve(a.slice(6));
    else if (a === '--help' || a === '-h') opts.help = true;
    else throw new Error(`未知参数：${a}`);
  }
  return opts;
}

function usage() {
  console.log(
    [
      '用法：node scripts/patch-vscode.js [选项]',
      '',
      '  （无参数）        隐藏编辑器标题栏的「分栏」按钮',
      '  --revert         还原到打补丁前的原始文件',
      '  --app <path>     指定 VS Code 安装路径，默认 ' + DEFAULT_APP,
      '  --dry-run        只打印将要做的改动，不写文件',
      '',
    ].join('\n')
  );
}

function sha256Base64(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('base64');
}

function checksumOf(file) {
  return sha256Base64(file).replace(/=+$/, '');
}

function readProduct(file) {
  const raw = fs.readFileSync(file, 'utf8');
  return { raw, json: JSON.parse(raw) };
}

function checksumFromProduct(productJson) {
  return (productJson.checksums || {})[CSS_KEY];
}

function writeChecksum(productFile, newChecksum) {
  const { raw } = readProduct(productFile);
  const keyPattern = CSS_KEY.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re = new RegExp(`("${keyPattern}"\\s*:\\s*")[^"]*(")`);
  if (!re.test(raw)) throw new Error(`product.json 中找不到 ${CSS_KEY} 的 checksums 记录`);
  const next = raw.replace(re, `$1${newChecksum}$2`);
  JSON.parse(next);
  fs.writeFileSync(productFile, next);
}

function readMeta() {
  try {
    return JSON.parse(fs.readFileSync(BACKUP_META, 'utf8'));
  } catch {
    return undefined;
  }
}

function saveBackup(appPath, cssFile, productFile) {
  fs.mkdirSync(BACKUP_DIR, { recursive: true });
  fs.copyFileSync(cssFile, BACKUP_CSS);
  const { json } = readProduct(productFile);
  const meta = {
    appPath,
    vscodeVersion: json.version,
    cssSha256: sha256Base64(BACKUP_CSS),
    productChecksum: checksumFromProduct(json),
    patchedAt: new Date().toISOString(),
  };
  fs.writeFileSync(BACKUP_META, JSON.stringify(meta, null, 2) + '\n');
  return meta;
}

function apply(opts) {
  const cssFile = path.join(opts.app, ...CSS_REL);
  const productFile = path.join(opts.app, ...PRODUCT_REL);
  if (!fs.existsSync(cssFile)) throw new Error(`找不到 ${cssFile}`);

  const css = fs.readFileSync(cssFile, 'utf8');
  const { json } = readProduct(productFile);

  if (css.includes(MARK_BEGIN)) {
    const beginIdx = css.indexOf(MARK_BEGIN);
    const endIdx = css.indexOf(MARK_END);
    if (endIdx < beginIdx) throw new Error('补丁标记不完整，请先执行 --revert 还原。');
    const existing = css.slice(beginIdx, endIdx + MARK_END.length);
    const wanted = CSS_BLOCK.replace(/\n$/, '');
    if (existing !== wanted) {
      if (opts.dryRun) {
        console.log('[dry-run] 补丁样式有更新，将替换为：');
        console.log(CSS_BLOCK);
      } else {
        fs.writeFileSync(cssFile, css.slice(0, beginIdx) + CSS_BLOCK);
        writeChecksum(productFile, checksumOf(cssFile));
        console.log('补丁样式已更新，并同步 product.json 校验和。');
      }
      return;
    }
    console.log('已经打过补丁，无需重复追加。');
    const current = checksumOf(cssFile);
    if (checksumFromProduct(json) !== current) {
      if (opts.dryRun) console.log(`[dry-run] 将更新 product.json 校验和 → ${current}`);
      else {
        writeChecksum(productFile, current);
        console.log('已同步 product.json 校验和。');
      }
    }
    return;
  }

  const currentSha = sha256Base64(cssFile);
  const meta = readMeta();
  const backupValid = meta && fs.existsSync(BACKUP_CSS) && meta.cssSha256 === sha256Base64(BACKUP_CSS);
  const backupMatchesCurrent = backupValid && currentSha === meta.cssSha256;

  if (!backupMatchesCurrent) {
    if (meta && backupValid) {
      console.log(`检测到 VS Code 版本变化（${meta.vscodeVersion} → ${json.version}），将以当前文件作为新基线重建备份。`);
    }
    if (opts.dryRun) console.log(`[dry-run] 将备份 ${cssFile} → ${BACKUP_CSS}`);
    else {
      const saved = saveBackup(opts.app, cssFile, productFile);
      console.log(`已备份原始 CSS（版本 ${saved.vscodeVersion}）。`);
    }
  } else {
    console.log('复用已有的原始 CSS 备份。');
  }

  if (opts.dryRun) {
    console.log(`[dry-run] 将追加以下样式到 ${cssFile}：`);
    console.log(CSS_BLOCK);
    return;
  }

  fs.writeFileSync(cssFile, css.replace(/\s*$/, '\n') + '\n' + CSS_BLOCK);
  writeChecksum(productFile, checksumOf(cssFile));
  console.log('已追加样式并同步 product.json 校验和。');
}

function revert(opts) {
  const cssFile = path.join(opts.app, ...CSS_REL);
  const productFile = path.join(opts.app, ...PRODUCT_REL);
  const meta = readMeta();
  if (!meta || !fs.existsSync(BACKUP_CSS)) throw new Error('没有找到备份，无法还原。');
  if (sha256Base64(BACKUP_CSS) !== meta.cssSha256) throw new Error('备份文件已损坏，无法还原。');

  const css = fs.existsSync(cssFile) ? fs.readFileSync(cssFile, 'utf8') : '';
  if (!css.includes(MARK_BEGIN)) {
    if (sha256Base64(cssFile) === meta.cssSha256) {
      console.log('当前文件已是原始版本，无需还原。');
      return;
    }
    throw new Error('当前 CSS 里没有补丁标记，且内容与备份不一致（可能被 VS Code 更新覆盖）。已中止，避免误覆盖新版本文件。');
  }

  if (opts.dryRun) {
    console.log(`[dry-run] 将用 ${BACKUP_CSS} 覆盖 ${cssFile}，并恢复校验和 ${meta.productChecksum}`);
    return;
  }

  fs.copyFileSync(BACKUP_CSS, cssFile);
  writeChecksum(productFile, meta.productChecksum);
  console.log('已还原原始 CSS 与 product.json 校验和。');
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    usage();
    return;
  }
  try {
    if (opts.revert) revert(opts);
    else apply(opts);
    if (!opts.dryRun) {
      console.log('');
      console.log('提示：在 VS Code 中执行「Developer: Reload Window」即可看到效果。');
    }
  } catch (err) {
    if (err.code === 'EACCES' || err.code === 'EPERM') {
      console.error(`权限不足：${err.path}`);
      console.error('请用 sudo 重新执行，或确认 VS Code 安装在可写目录。');
    } else {
      console.error(`失败：${err.message}`);
    }
    process.exit(1);
  }
}

main();