# MQL Tools（macOS + CrossOver 改版）

本目录保存了 IDE 扩展 **MQL Tools** 的完整资源，以及针对 macOS / CrossOver（Wine）环境所做的编译流程改造。

- 扩展 ID：`L-I-V.mql-tools`
- 版本：`0.1.0`
- 上游仓库：<https://github.com/L-I-V/MQL-Tools>
- 插件本体：[plugin/](./plugin)（可直接覆盖安装，见“安装”一节）
- 测试用例：[Gold_M1_Scalper_HF.mq4](./Gold_M1_Scalper_HF.mq4) / `Gold_M1_Scalper_HF.ex4`

---

## 1. 目录结构

```
extensions/mql-tool-modify/
├── README.md                    本文件
├── Gold_M1_Scalper_HF.mq4       测试源码（编译对象）
├── Gold_M1_Scalper_HF.ex4       测试产物
└── plugin/                      插件完整资源（= 已安装扩展目录的内容）
    ├── package.json             扩展清单（命令、菜单、快捷键、配置项）
    ├── package.nls.json         界面文案（英文）
    ├── package.nls.ru.json      界面文案（俄文）
    ├── landes.json              多语言运行时文案
    ├── landes.ru.json
    ├── changelog.md             上游更新日志
    ├── readme.md                上游原始说明
    ├── .vsixmanifest            扩展清单（VSIX 元数据）
    ├── out/                     运行时 JS（main = out/extension.js）
    │   ├── extension.js         编译流程（本次改造集中在此文件）
    │   ├── provider.js          悬停 / 补全 / 签名帮助 / 颜色预览
    │   ├── contextMenu.js       右键菜单功能（插入模板、导入、时间等）
    │   ├── addIcon.js           图标安装
    │   ├── createProperties.js  配置生成
    │   └── help.js              F1 帮助（CHM）
    ├── data/                    函数库、颜色表、错误码（必需）
    ├── files/                   MetaEditor 辅助程序 + 图标（必需）
    │   ├── MQL Tools_Compiler.exe   Compile Script 用（macOS 下不生效）
    │   ├── KeyHH.exe                打开 CHM 帮助的 Windows 程序
    │   └── icons/                   文件图标资源
    ├── images/  media/  syntaxes/   图标与语法定义
    ├── .gitignore               忽略 files/help/*.chm
    └── ...
```

> 说明 1：`out/extension.js.backup`、`out/extension.js.bak` 是历史上一次失败改动留下的**截断损坏文件**，未纳入本目录。
>
> 说明 2：`plugin` 目录约 **4.2 MB**。上游原包里 `files/help/` 的 13 个 `.chm` 离线帮助文档（约 79 MB）**已剔除**，原因见第 8 节第 5 条——插件首次按 F1 时会自动从上游 GitHub 下载所需语言的那一个 `.chm`。

---

## 2. 相对原始版本改了什么

原始版本（上游 `L-I-V/MQL-Tools` v0.1.0，`out/extension.js` 共 342 行）**只支持 Windows**：

```js
if (os === 'linux') {            // 只有 Linux 走 wine
    command = `cd "${DirAbsPath}" && wine "${CompRelPath}" ...`;
}
else {command = `"${MetaDir}" /compile:"${path}" ...`;}   // macOS 落在这里 → 直接执行 .exe，必然失败
```

在 macOS 上 `os === 'darwin'`，会进入 `else` 分支，把一个 Windows 的 `.exe` 路径当作可执行文件交给 `child_process.exec`，因此**原始版本在 macOS 上完全无法编译**。本次改造共 4 处：

| # | 改动 | 位置 |
|---|---|---|
| 1 | macOS 走 CrossOver wine 调用 metaeditor | `out/extension.js` L107-L145 |
| 2 | macOS 路径自动转换为 Windows 盘符路径（`/.../drive_c/` → `C:\`） | L130-L137 |
| 3 | 编译成功后把 `.ex4/.ex5` 自动分发到 MT4 的 `Experts/<源文件父目录名>/` | L16、L173-L189 |
| 4 | 附带修正：stderr 判断排除 darwin、日志目录不存在时自动创建、读日志前先判空 | L115-L124、L152 |

### 改动 1/2：macOS 编译命令

```js
if (os === 'linux' || os === 'darwin') {
    ...
    if (os === 'darwin') {
        // 把 macOS 路径转换成 Windows 格式
        let winMetaDir = MetaDir.replace('/Users/mac/Library/Application Support/CrossOver/Bottles/win10_64/drive_c/', 'C:\\').replace(/\//g, '\\');
        let winPath    = path.replace(同上).replace(/\//g, '\\');
        let winLogFile = logFile.replace(同上).replace(/\//g, '\\');

        command = `/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine --bottle win10_64 --cx-app "${winMetaDir}" /compile:"${winPath}"${includefile}${...} /log:"${winLogFile}"`;
    } else {
        command = `cd "${DirAbsPath}" && wine ...`;   // Linux 保持原样
    }
}
```

关键点：`--cx-app` 让 CrossOver 直接以「应用」方式启动 Windows 程序，`/compile:` 与 `/log:` 参数都使用 **Windows 路径**，因为 metaeditor 运行在 Wine 里只认盘符路径。

### 改动 3：编译成功后自动分发产物（本次新增的核心需求）

常量（`out/extension.js` L16）：

```js
const EXPERTS_COPY_DIR = '/Users/mac/Library/Application Support/CrossOver/Bottles/win10_64/drive_c/users/crossover/AppData/Roaming/MetaQuotes/Terminal/2191F4A3D14D7B4B1EBB84F924777883/MQL4/Experts';
```

分发逻辑（L173-L189，紧跟在编译日志解析之后）：

```js
if (os === 'darwin' && rt !== 0 && log && !log.error && (extension === '.mq4' || extension === '.mq5')) {
    const outExt = extension === '.mq5' ? '.ex5' : '.ex4',
        outName = pathModule.basename(path, extension) + outExt,
        outFile = pathModule.join(pathModule.dirname(path), outName),
        subDir  = pathModule.join(EXPERTS_COPY_DIR, pathModule.basename(pathModule.dirname(path)));
    try {
        fs.existsSync(subDir) || fs.mkdirSync(subDir, { recursive: true });
        if (fs.existsSync(outFile)) {
            fs.copyFileSync(outFile, pathModule.join(subDir, outName));
            outputChannel.appendLine(`[Done] ${outName} >>> ${subDir} <<<`);
        } else {
            outputChannel.appendLine(`[Warning] ${outFile} not found`);
        }
    } catch (err) {
        outputChannel.appendLine(`[Error] ${err.message}`);
    }
}
```

行为规则：

1. 只在**编译成功**时触发（`log.error` 为假）；
2. 只在 `compileFile`(rt=1) 与 `compileScript`(rt=2) 触发，`checkFile`(rt=0) 只检查不拷贝；
3. 子目录名**取源文件的父目录名**，因此 `extensions/mql-tool-modify/Gold_M1_Scalper_HF.mq4` → `Experts/mql-tool-modify/`，路径不写死在代码里；
4. 子目录不存在则递归创建；
5. 拷贝失败只写输出面板，不影响编译结果展示。

以本目录的测试文件为例，最终落点是：

```
.../Terminal/2191F4A3D14D7B4B1EBB84F924777883/MQL4/Experts/mql-tool-modify/Gold_M1_Scalper_HF.ex4
```

---

## 3. 功能一览

继承自上游的编辑器能力：

- `.mq4 / .mq5 / .mqh` 语法高亮与颜色常量预览（`C'255,0,0'`、`D'2020.01.01'` 等）
- 悬停提示、函数补全、参数签名帮助（基于 `data/items.json` 函数库）
- 一键插入文件头模板、`#resource`、`#import`、编译时间、图标名
- 右键菜单“MQL Tools”子菜单、`F1` 调起离线 CHM 帮助（多语言）
- 编辑器标题栏按钮：编译 / 检查 / 编译脚本

本改版新增：

- macOS 下通过 CrossOver Wine 调用 `metaeditor.exe` 完成编译/检查（上游仅 Windows/Linux）
- 编译成功后自动把 `.ex4/.ex5` 复制到 MT4 `Experts/` 下与源目录同名的子目录

---

## 4. 安装

> 前提：已安装 CrossOver，且 Bottle 名为 `win10_64`，其中装有 MetaTrader 4（含 `metaeditor.exe`）。

### 方式一：覆盖已安装的扩展（推荐，最省事）

先确认 IDE 里已经安装过 `L-I-V.mql-tools`（未安装请用方式二）。

Trae CN：

```bash
rsync -a "extensions/mql-tool-modify/plugin/" "$HOME/.trae-cn/extensions/l-i-v.mql-tools-0.1.0/"
```

VS Code：

```bash
rsync -a "extensions/mql-tool-modify/plugin/" "$HOME/.vscode/extensions/l-i-v.mql-tools-0.1.0/"
```

然后在 IDE 中执行 `Developer: Reload Window`（命令面板 `Cmd+Shift+P`）或直接重启 IDE 生效。

### 方式二：打包成 VSIX 安装（适合全新环境 / 分发给别人）

```bash
cd extensions/mql-tool-modify/plugin
npx @vscode/vsce package --no-dependencies
# 生成 mql-tools-0.1.0.vsix
```

安装：

- VS Code：`code --install-extension mql-tools-0.1.0.vsix --force`
- Trae / 其他 VS Code 内核 IDE：扩展面板右上角 `...` → “Install from VSIX...” → 选择该文件

> 若本机已装同版本 0.1.0，VSIX 安装会被视为“已安装”，请用 `--force`，或先卸载再装。

### 方式三：全新手工安装（无 VSIX、也没有已装扩展时）

1. 把 `plugin/` 内容复制到 `~/.trae-cn/extensions/l-i-v.mql-tools-0.1.0/`（目录名必须是 `发布者.扩展名-版本号`）；
2. 在 `~/.trae-cn/extensions/extensions.json` 中追加一条对应记录（结构与其它条目一致）；
3. 重启 IDE。

---

## 5. 必要配置

在 IDE 的 `settings.json` 中：

```jsonc
{
  // 必须：指向 metaeditor.exe（不是 terminal.exe），代码会校验文件名
  "mql_tools.Metaeditor.Metaeditor4Dir": "/Users/mac/Library/Application Support/CrossOver/Bottles/win10_64/drive_c/Program Files (x86)/MetaTrader 4 EXNESS/metaeditor.exe",

  // 可选：Include 目录（为空则不加 /include 参数）
  "mql_tools.Metaeditor.Include4Dir": "",

  // 可选：编译后是否删除 .log
  "mql_tools.LogFile.DeleteLog": true,

  // 可选：编辑器标题栏按钮显隐
  "mql_tools.ShowButton.Compile": true,
  "mql_tools.ShowButton.Check": true,
  "mql_tools.ShowButton.Script": false
}
```

注意：`Metaeditor4Dir` 的**文件名必须是** `metaeditor.exe` 或 `metaeditor64.exe`，否则插件直接报路径错误并中止；`Metaeditor5Dir` 同理（填 `terminal64.exe` 会校验失败，需填 `metaeditor64.exe`）。

---

## 6. 使用

1. 打开 `.mq4/.mq5` 文件；
2. 三种入口任选：
   - 编辑器标题栏的编译按钮；
   - 命令面板：`MQL: Compile File`（编译）/ `MQL: Check File`（只检查）/ `MQL: Compile Script`；
   - 快捷键：编译 `Ctrl+Shift+X`、检查 `Ctrl+Shift+Z`、编译脚本 `Ctrl+Shift+C`（可在 `package.json` 的 `keybindings` 中改）；
3. 结果看输出面板 **MQL** 频道：

```
[Starting] [23:40:12] compiling >>> Gold_M1_Scalper_HF.mq4 <<<
...
[Done] Result: 0 error(s), 0 warning(s)
[Done] Gold_M1_Scalper_HF.ex4 >>> .../MQL4/Experts/mql-tool-modify <<<
```

4. 编译成功后到 `Experts/mql-tool-modify/` 下确认 `.ex4`，在 MT4 里刷新导航器即可看到该 EA。

---

## 7. 如何修改分发目标

`out/extension.js` 中有两处写死的 macOS 路径，换 Bottle / 换 MT4 实例时需同步改：

| 用途 | 位置 |
|---|---|
| 分发目标 `Experts` 目录 | L16 `EXPERTS_COPY_DIR` |
| macOS → Windows 路径前缀转换（`drive_c/` → `C:\`） | L130、L133、L136 |
| CrossOver wine 可执行文件与 Bottle 名 | L140（`--bottle win10_64`） |

`MetaQuotes/Terminal/<32位ID>` 是 MT4 实例 ID，每台机器/每个安装不同，可在 `~/Library/Application Support/CrossOver/Bottles/win10_64/drive_c/users/crossover/AppData/Roaming/MetaQuotes/Terminal/` 下查看实际目录名。

---

## 8. 已知限制

1. **Bottle 名与 CrossOver 路径写死**：`win10_64` 与 `/Applications/CrossOver.app/...`，与 `mql_tools.Metaeditor.WinePrefixME4` 配置项无关（该配置项在本版本代码中未被读取）。
2. **`Compile Script`（rt=2）在 macOS 上不可用**：编译本身成功后，它会 `execSync` 调用 Windows 专用的 `files/MQL Tools_Compiler.exe`（用于自动拉起 MetaEditor），在 macOS 下会报错。日常请使用 `Compile File`。
3. **`.mqh` 仅能检查**：头文件走 `rt=0`，不会产生可分发产物。
4. **版本号仍是 0.1.0**：便于覆盖安装；若要与上游区分，可在 `package.json` 改 `version`（目录名需同步改）。
5. **离线帮助文档已剔除**：`plugin` 目录现约 **4.2 MB**，上游原包 `files/help/` 下的 13 个 `.chm`（约 79 MB）已删除。`out/help.js` 的 `download()` 会在首次按 F1 时自动从上游 GitHub 拉取**当前语言**对应的那一个 `.chm` 并写入 `files/help/`，因此功能不受影响（仅在 macOS 下因 `KeyHH.exe` 是 Windows 程序而无法真正弹出帮助）。`plugin/.gitignore` 已忽略 `files/help/*.chm`，避免误入库。
6. **已删除两张无引用图片**：`images/ctrlAltD.gif`、`images/mp.gif`（上游 readme 与代码均未引用）。`images/mql_icon_mini.png` 被 `provider.js` 使用，已保留。

---

## 9. 验证记录

- `node --check plugin/out/*.js` 全部通过；
- 分发逻辑用沙箱目录实测：产物解析为 `Gold_M1_Scalper_HF.ex4`，子目录解析为 `<Experts>/mql-tool-modify`，目录自动创建、文件拷贝成功；
- 已部署到 `~/.trae-cn/extensions/l-i-v.mql-tools-0.1.0/` 与 `~/.vscode/extensions/l-i-v.mql-tools-0.1.0/`，两份 `out/extension.js` 的 MD5 一致；
- 瘦身前后：`plugin` 目录 84 MB → **4.2 MB**（删除 13 个 `.chm` 与 2 张无引用图片，共 48 个文件）。

---

## 附录：提交到 GitHub Desktop

本目录位于 `dev-toolbox` 仓库内，该仓库已有远程：`https://github.com/mscwp78ty8-bit/dev-toolbox.git`（分支 `main` 跟踪 `origin/main`）。

1. GitHub Desktop 中 `File → Add local repository`，选择 `/Users/mac/Projects/dev-toolbox`（若已在列表中则直接选中）；
2. 左侧 **Changes** 会列出 `extensions/mql-tool-modify/` 下全部新增文件（约 4.2 MB，48 个文件，提交很快）；
3. 填 Summary，例如 `feat(mql-tools): macOS CrossOver 编译支持 + 编译产物自动分发`，点 **Commit to main**；
4. 点右上角 **Push origin** 推送到 GitHub；
5. 若推送被拒（远程有新提交），先 **Pull origin** 再 Push。

> `plugin/files/help/*.chm` 已被 `plugin/.gitignore` 忽略，不会出现在 Changes 列表里。`.DS_Store`、`node_modules/`、`*.log` 由仓库根目录 `.gitignore` 忽略。