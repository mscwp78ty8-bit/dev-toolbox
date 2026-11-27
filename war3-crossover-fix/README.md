# War3 · CrossOver 修复包

11 对战平台《魔兽争霸 III》1.26 在 macOS + CrossOver(Wine) 环境下的两个硬伤，以及一套可复用的修复脚本。

| 编号 | 症状 | 根因 | 修复手段 |
|---|---|---|---|
| 问题一 | 启动或进入游戏时崩溃，错误码 `0xC0000005 (at 0x00000000)` | 平台注入的 `DxRender.dll` 调用 OpenGL 3.0 函数，Wine 只提供 GL 2.1，函数指针为 NULL → `call NULL` | 把 `DxRender.dll` 里一处 `jne` 改成 `jmp`，跳过 GL 渲染器创建，走 D3D9 兜底 |
| 问题二 | 96 DPI 画面完整但模糊；120/144/168 DPI 画面逐步向下偏移；192 DPI 只剩声音 | War3 硬编码 `2704×1756` 全屏，RetinaMode 与 LogPixels 一起参与坐标换算，把画面整体下移 `(DPI/96-1)×屏高` | RetinaMode=y + 高 DPI 感知标记 + 分辨率对齐 |

两个问题都不需要安装任何额外库、也不需要改 Wine 的加载库设置，全部通过容器内注册表与平台补丁包完成。

---

## 快速开始

```bash
# 1. 新建 CrossOver 容器（win10_64 即可），装好 11 平台
# 2. 先正常启动一次平台，让它把 War3 补丁包 gp_1297.zip 下载到本地
#    （脚本要修的就是这个包里的 DxRender.dll，没有它无从下手）
# 3. 完全退出平台（CrossOver 菜单 -> 退出所有 Windows 程序）
# 4. 运行修复包
open "一键修复全部.command"
#    或命令行： ./一键修复全部.command
# 5. 重新启动 11 平台，进游戏
```

`一键修复全部.command` 会依次做两件事：先改注册表（分辨率 / DPI），再打崩溃补丁，最后自动校验并打印结论。中途会询问一次是否关闭容器内 Wine 进程。

整个目录可以直接拷到另一台 Mac / 另一个容器环境使用：脚本里没有任何写死的用户名或容器名，容器是运行时自动扫描 `~/Library/Application Support/CrossOver/Bottles/` 找出来的。唯一的外部依赖是 `python3`（macOS 装过 Xcode 命令行工具就有，脚本会先检查）。

只想看会改什么、不动文件：

```bash
./一键修复全部.command --dry-run
```

---

## 目录结构

```
war3-crossover-fix/
├── 一键修复全部.command      # 入口：DPI/分辨率 + 崩溃补丁，一次搞定
├── 一键修复崩溃补丁.command   # 只修问题一
├── fix-war3-dpi.py           # 问题二：注册表修复（RetinaMode / 高 DPI 感知 / 分辨率）
├── fix-war3-dxrender.py      # 问题一：DxRender.dll 补丁（含防平台还原）
├── tools/
│   └── win-rect.swift        # 诊断：打印 War3 / 平台窗口的真实位置与尺寸
├── .backup/                  # 首次运行自动生成的备份（已被 .gitignore 忽略）
│   ├── w3l/                  #   官方原始 gp_1297.zip / MD5.dat / DownloadList.xml
│   └── <容器名>-user.reg.orig / -system.reg.orig
└── .gitignore
```

`.backup/` 里的东西是回滚用的原件，**不要提交到 git**（里面有一个 21 MB 的官方补丁包）。

---

## 问题一：0xC0000005 崩溃

### 现象

平台能启动、能匹配，一点"开始游戏"就崩，或者加载地图时闪退。Wine 日志里是 `EIP=00000000`，Windows 侧报 `0xC0000005 (at 0x00000000)`。

### 根因

平台为了加速渲染会往游戏进程里注入 `DxRender.dll`。它初始化时先尝试建 OpenGL 3.0+ 渲染器，调了一串扩展函数：

```
glGenVertexArrays / glGenBuffers / glMapBufferRange / glBlitFramebuffer ...
```

这些函数必须通过 `wglGetProcAddress` 取地址。Wine 的 wined3d 只给 legacy GL 2.1 上下文，对这些名字一律返回 NULL。DLL 里没有判空就直接 `call eax`，于是跳到 0 地址执行 → 访问违例。

### 修复

`DxRender.dll` 在创建 GL 渲染器失败后会走 D3D9 兜底分支，只是那个判断分支写成了"GL 失败就整体放弃"。把判断处的跳转改掉即可：

| 项 | 值 |
|---|---|
| 文件 | `Patch/war3/gp_1297/DxRender.dll` |
| 位置 | RVA `0x76AC`（前面紧跟 `8B F8` 作为特征校验） |
| 原始字节 | `75 7B`（`jne`） |
| 补丁字节 | `EB 7B`（`jmp`） |

改完直接跳到 D3D9 分支，画面由 wined3d 正常渲染。

### 为什么会被平台还原

平台每次启动都会做两层校验，只改 DLL 是留不住的：

1. `PatchZip/war3/gp_1297.zip` 与解压目录 `Patch/war3/gp_1297/` 内容不一致 → 重新解压覆盖；
2. `core/Config/DownloadList.xml` 与 `MD5.dat` 里记录的 md5 与实际 zip 不符 → 从服务器重新下载官方包。

所以脚本会**同时**处理四处，让它们彼此自洽：

```
磁盘 DxRender.dll  ── 打补丁
zip 内 DxRender.dll ── 打补丁（保持与磁盘字节完全一致）
MD5.dat            ── 写入打补丁后 zip 的真实 md5
DownloadList.xml   ── 写入打补丁后 zip 的真实 md5
```

四处一致，平台就会认为本地已是最新，不会重下也不会重解压。

### 用法

```bash
python3 fix-war3-dxrender.py             # 修复（幂等，可反复执行）
python3 fix-war3-dxrender.py --verify    # 只检查四处状态是否自洽
python3 fix-war3-dxrender.py --dry-run   # 只列出会改动哪些项
python3 fix-war3-dxrender.py --restore   # 还原官方原版
python3 fix-war3-dxrender.py --watch 5   # 守护：每 5 秒检查，被还原就立刻重打
```

---

## 问题二：DPI 与画面偏移

### 现象（实测）

| LogPixels | 现象 |
|---|---|
| 96 DPI | 画面完整，但整体偏模糊 |
| 120 DPI | 屏幕上方约 1/4 是黑的，游戏画面压在下面 3/4 |
| 144 DPI | 上方一半黑 |
| 168 DPI | 上方 3/4 黑 |
| 192 DPI | 画面完全移出可视区域，只剩声音 |

### 根因

这台机器的显示链路是：物理面板 3024×1964，系统"看起来像" 1352×878，HiDPI 后备缓冲 2704×1756。

War3 1.26 全屏时用注册表里写死的分辨率渲染：

| 键 | 值 | 换算 |
|---|---|---|
| `reswidth` | `0xa90` | 2704 |
| `resheight` | `0x6dc` | 1756 |

正好是 2× 逻辑分辨率。两个开关一起决定了最终结果：

- **RetinaMode = "n"**：Wine 按逻辑分辨率 1352×878 渲染，再被 macOS 放大到面板 → 画面糊（96 DPI 时看到的就是这个）。
- **RetinaMode = "y" 且 LogPixels > 96**：Wine 按 `dpi/96` 的比例换算全屏客户区原点，画面整体下移：

```
下移量(点) ≈ (DPI / 96 - 1) × 屏幕逻辑高度
```

代入 878 点：

| DPI | `DPI/96 - 1` | 下移量 | 屏高占比 |
|---|---|---|---|
| 96 | 0 | 0 | 0 |
| 120 | 0.25 | 219 点 | 1/4 |
| 144 | 0.50 | 439 点 | 1/2 |
| 168 | 0.75 | 659 点 | 3/4 |
| 192 | 1.00 | 878 点 | 整屏移出 |

与实测现象完全吻合。所以"糊"和"看不见"不是两个毛病，是同一条公式的两端。

### 修复

`fix-war3-dpi.py` 写四个位置：

| 位置 | 键 | 值 | 作用 |
|---|---|---|---|
| `Software\Wine\Mac Driver` | `RetinaMode` | `"y"` | 2× 后备缓冲，2704×1756 与物理像素 1:1，画面清晰 |
| `Control Panel\Desktop`、`Software\Wine\Fonts`、system.reg 的 Hardware Profiles Fonts | `LogPixels` | 保持原值，或 `--dpi 96` 固定 | 偏移公式归零 |
| `AppCompatFlags\Layers` | 各 exe 路径 | `~ HIGHDPIAWARE` | 让 Wine 不对这些程序做 DPI 换算，DPI 再高也不偏移 |
| `Software\Blizzard Entertainment\Warcraft III\Video` | `reswidth` / `resheight` | 2× 逻辑分辨率（Retina）/ 1× 逻辑分辨率 | 与后备缓冲严格对齐 |

高 DPI 感知标记会覆盖容器内所有能找到的目标程序，不止 War3：

```
War3.exe / Warcraft III.exe / War3Loader.exe
11Client.exe / War3Lobby.exe / YYEmulatorClient.exe
（含 5211game、5211game1、ylgame 各目录下的副本，以及裸文件名兜底）
```

分辨率是自动算的：取 Finder 桌面逻辑尺寸，Retina 屏 ×2，普通屏 ×1。也可以用 `--resolution 2704x1756` 手动指定。

### 用法

```bash
python3 fix-war3-dpi.py                  # 修复（保持当前 DPI）
python3 fix-war3-dpi.py --dpi 96         # 顺便把 DPI 固定为 96（最保守）
python3 fix-war3-dpi.py --dry-run        # 演练：只列出会改哪几项
python3 fix-war3-dpi.py --verify         # 只检查状态
python3 fix-war3-dpi.py --restore        # 用首次备份还原注册表
python3 fix-war3-dpi.py --kill-wine      # 先结束容器内 Wine 进程再改（强烈推荐）
```

### 一个容易踩的坑

**不要在 Wine 进程运行期间改 `user.reg`。** Wine 会把内存里的注册表在 wineserver 退出时整份写回文件，你手改的值会被旧值覆盖——排查时就遇到过"改完 96，游戏退出后变回 192"。正确顺序是：先结束 Wine 进程（`--kill-wine`），再改文件，再启动。

---

## 参数速查

两个 Python 脚本共享同一套定位逻辑：不写 `--bottle` 时自动扫描 `~/Library/Application Support/CrossOver/Bottles/` 下所有容器，优先选择装了 11 平台（存在 `W3L` 目录）的容器，并逐个处理。

| 参数 | 说明 |
|---|---|
| `--bottle NAME` | 只处理指定容器，例如 `win10_64` |
| `--verify` | 只检查，不改动任何文件 |
| `--dry-run` | 演练，只列出会改动哪些项 |
| `--restore` | 用首次运行时的备份还原 |
| `--kill-wine` | （仅 dpi）改注册表前先结束容器内 Wine 进程 |
| `--dpi N` | （仅 dpi）把 DPI 写成 N；不填则保持原值 |
| `--resolution WxH` | （仅 dpi）手动指定游戏分辨率 |
| `--keep-resolution` | （仅 dpi）不改游戏分辨率 |
| `--watch N` | （仅 dxrender）守护模式，每 N 秒检查补丁是否被还原 |

---

## 验证与回滚

**验证**

```bash
python3 fix-war3-dpi.py --verify      # RetinaMode / LogPixels / 标记数量 / 分辨率
python3 fix-war3-dxrender.py --verify # 磁盘、zip、MD5.dat、DownloadList.xml 四处是否自洽
```

**看窗口到底在哪**（游戏全屏时执行）

```bash
swift tools/win-rect.swift war3
# RECT=(0,0 1352x878)  正常：贴左上角、铺满逻辑屏幕
# RECT=(0,219 ...)     偏移：219 点 = (120/96-1)×878，说明高 DPI 感知标记没生效
```

`win-rect.swift` 只读系统窗口列表，不改任何东西；参数换成 `11` 可以看平台主窗口。

**回滚**

```bash
python3 fix-war3-dpi.py --restore       # 注册表回到首次运行前的状态
python3 fix-war3-dxrender.py --restore  # DxRender 回到官方原版
```

备份都在 `.backup/` 下，删掉该目录就等于放弃回滚能力。

---

## 常见问题

**Q：脚本报"找不到 11 平台目录（W3L）"**
平台还没下载 War3 补丁包。先正常启动一次平台并进入 War3 专区，让它把 `gp_1297.zip` 拉到 `PatchZip/war3/`，再退出平台重跑脚本。

**Q：画面清楚了，但平台和游戏里字很小**
这是 DPI 保持原值 / 96 时的正常表现（1× 渲染在 2× 缓冲上，只是小，不糊）。想放大就 `--dpi 120` 或 `--dpi 144`，游戏已打高 DPI 感知标记，不会再偏移；若确实出现偏移，退回 `--dpi 96`。

**Q：改完注册表没生效**
容器里还有 Wine 进程在跑，内存里的旧值把它刷回去了。用 `--kill-wine` 或手动退出所有 Windows 程序后重跑。

**Q：平台过一段时间又开始崩**
说明补丁被平台重下了。先 `--verify` 看是哪一处不一致，再跑一次修复；需要长期兜底就用 `--watch 5` 常驻守护。

**Q：可以只修其中一个问题吗？**
可以，两个脚本互不依赖：`一键修复崩溃补丁.command` 只打补丁，`fix-war3-dpi.py` 只改注册表。

**Q：需要装额外的 Wine 库 / 改加载库设置吗？**
不需要。两个问题都不是缺 DLL，全部靠容器内注册表与平台自带补丁包解决。

---

## 已验证环境

| 项 | 值 |
|---|---|
| 机型 | Apple M1 Pro，面板 3024×1964，逻辑 1352×878 |
| CrossOver | 25.0.0.38553local，容器 `win10_64` / `win7_64` |
| 平台 | 11 对战平台，War3 1.26（`gp_1297.zip` 补丁包） |
| 结果 | 崩溃不再出现；96~192 DPI 下画面均完整、无偏移、无缩放模糊；平台重下补丁后仍保持 |