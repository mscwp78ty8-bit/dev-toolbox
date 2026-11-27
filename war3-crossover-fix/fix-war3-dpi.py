#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""11 对战平台 War3 在 CrossOver/Wine 下的「分辨率 / DPI 画面偏移」修复工具。

症状
  96 DPI  : 画面完整但模糊
  120 DPI : 屏幕上方约 1/4 是黑的，游戏画面被压到下方 3/4
  144 DPI : 上方一半黑
  168 DPI : 上方 3/4 黑
  192 DPI : 画面完全移出屏幕，只剩声音

原理
  War3 1.26 用注册表里写死的 reswidth/resheight 做全屏渲染，Retina 屏上这个值
  通常等于 2× 逻辑分辨率（2704×1756 = 2×1352×878）。
  * RetinaMode = "n" 时，Wine 按逻辑分辨率渲染，再被 macOS 放大 2 倍 -> 画面糊。
  * RetinaMode = "y" 且 LogPixels > 96 时，Wine 按 dpi/96 的比例换算全屏客户区
    原点，画面整体向下平移：

        下移量(点) ≈ (DPI / 96 - 1) × 屏幕逻辑高度

    120 -> 0.25×878 ≈ 219 点（屏高 1/4），192 -> 1×878 = 878 点（整屏移出），
    与实测完全吻合。

修复
  1) [Software\\Wine\\Mac Driver] RetinaMode = "y"
     2× 后备缓冲，2704×1756 与物理像素 1:1，画面清晰。
  2) LogPixels：默认保持原值；加 --dpi 96 则固定为 96，偏移公式 (DPI/96-1)×屏高 直接归零
     （Control Panel\\Desktop、Software\\Wine\\Fonts，以及 system.reg 里 Hardware
     Profiles 的 Fonts 一并处理）
  3) AppCompatFlags\\Layers 给 War3 / 平台各 exe 打上 "~ HIGHDPIAWARE"
     让 Wine 不再对它们做 DPI 换算，以后即使把 DPI 调回 192 也不会再偏移。
  4) [Warcraft III\\Video] reswidth/resheight = 2× 逻辑分辨率（Retina）/ 1×（普通屏）
     与 RetinaMode 的后备缓冲严格对齐。

用法
  python3 fix-war3-dpi.py                  # 一键修复（保持当前 DPI，可反复执行）
  python3 fix-war3-dpi.py --verify         # 只检查当前状态
  python3 fix-war3-dpi.py --dry-run        # 演练：只列出会改哪几项
  python3 fix-war3-dpi.py --restore        # 用首次备份还原注册表
  python3 fix-war3-dpi.py --dpi 96         # 顺便把 DPI 固定为 96（最保守）
  python3 fix-war3-dpi.py --resolution 2704x1756   # 手动指定游戏分辨率
"""

import argparse
import io
import os
import re
import shutil
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BACKUP_ROOT = os.path.join(SCRIPT_DIR, ".backup")
BOTTLE_ROOT = os.path.expanduser("~/Library/Application Support/CrossOver/Bottles")
CROSSOVER_DIR = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"

S_DESKTOP = r"Control Panel\\Desktop"
S_FONTS = r"Software\\Wine\\Fonts"
S_MACDRV = r"Software\\Wine\\Mac Driver"
S_LAYERS = r"Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers"
S_VIDEO = r"Software\\Blizzard Entertainment\\Warcraft III\\Video"
S_SYSFONTS = r"System\\CurrentControlSet\\Hardware Profiles\\Current\\Software\\Fonts"

TARGET_EXES = [
    "war3.exe",
    "warcraft iii.exe",
    "war3loader.exe",
    "11client.exe",
    "war3lobby.exe",
    "yyemulatorclient.exe",
]

BARE_NAMES = ["War3.exe", "War3Loader.exe"]

W3L_REL = os.path.join("drive_c", "Program Files (x86)", "5211game", "W3L")


def info(msg):
    print("  " + msg)


def step(msg):
    print("\n[%s]" % msg)


def _filetime_hex():
    return "%x" % int((time.time() + 11644473600) * 10000000)


class RegFile(object):
    """按「节」为单位读写 Wine 的 .reg 文本文件，未涉及的行原样保留。"""

    def __init__(self, path):
        self.path = path
        with io.open(path, "rb") as f:
            raw = f.read().decode("utf-8", "surrogateescape")
        self.lines = raw.replace("\r\n", "\n").split("\n")

    def _bounds(self, section):
        low = section.lower()
        start = None
        for i, line in enumerate(self.lines):
            s = line.strip()
            if not (s.startswith("[") and "]" in s):
                continue
            name = s[1:s.index("]")]
            if start is None:
                if name.lower() == low:
                    start = i
            else:
                return start, i
        if start is None:
            return None
        return start, len(self.lines)

    def _ensure(self, section):
        b = self._bounds(section)
        if b:
            return b
        if self.lines and self.lines[-1] != "":
            self.lines.append("")
        self.lines.append("[%s] %d" % (section, int(time.time())))
        self.lines.append("#time=" + _filetime_hex())
        return self._bounds(section)

    @staticmethod
    def _parse(line):
        s = line.strip()
        if not s.startswith('"'):
            return None, None
        pos = s.find('"=')
        if pos < 0:
            return None, None
        return s[1:pos], s[pos + 2:]

    def get(self, section, name):
        b = self._bounds(section)
        if not b:
            return None
        low = name.lower()
        for line in self.lines[b[0] + 1:b[1]]:
            k, v = self._parse(line)
            if k is not None and k.lower() == low:
                return v
        return None

    def set(self, section, name, value, changed=None):
        b = self._ensure(section)
        low = name.lower()
        new = '"%s"=%s' % (name, value)
        for i in range(b[0] + 1, b[1]):
            k, _ = self._parse(self.lines[i])
            if k is not None and k.lower() == low:
                if self.lines[i].strip() != new:
                    self.lines[i] = new
                    if changed is not None:
                        changed.append(name)
                return
        ins = b[0] + 1
        while ins < b[1] and self.lines[ins].strip().startswith("#"):
            ins += 1
        self.lines.insert(ins, new)
        if changed is not None:
            changed.append(name)

    def save(self):
        with io.open(self.path, "wb") as f:
            f.write("\n".join(self.lines).encode("utf-8", "surrogateescape"))


def find_bottles(name=None):
    if name:
        p = os.path.join(BOTTLE_ROOT, name)
        if not os.path.isdir(p):
            raise SystemExit("找不到容器：" + p)
        return [p]
    found = []
    if os.path.isdir(BOTTLE_ROOT):
        for n in sorted(os.listdir(BOTTLE_ROOT)):
            p = os.path.join(BOTTLE_ROOT, n)
            if os.path.isdir(os.path.join(p, "drive_c")) and os.path.isfile(os.path.join(p, "user.reg")):
                found.append(p)
    if not found:
        raise SystemExit("在 %s 下没有找到任何 CrossOver 容器" % BOTTLE_ROOT)
    with_w3l = [p for p in found if os.path.isdir(os.path.join(p, W3L_REL))]
    return with_w3l if with_w3l else found


def wineserver_path():
    for cand in (os.path.join(CROSSOVER_DIR, "CrossOver-Hosted Application", "wineserver"),
                 os.path.join(CROSSOVER_DIR, "lib", "wine", "x86_64-unix", "wineserver")):
        if os.path.isfile(cand):
            return cand
    return None


def kill_wine(bottle):
    ws = wineserver_path()
    if not ws:
        info("未找到 wineserver，请手动退出 CrossOver 里的 Windows 程序后再运行")
        return False
    env = dict(os.environ, WINEPREFIX=bottle)
    subprocess.run([ws, "-k"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    info("已结束容器内 Wine 进程")
    return True


def find_exes(bottle):
    base = os.path.join(bottle, "drive_c")
    found = []
    for root, dirs, files in os.walk(base):
        depth = root[len(base):].count(os.sep)
        if depth > 6:
            dirs[:] = []
            continue
        for f in files:
            if f.lower() in TARGET_EXES:
                found.append(os.path.join(root, f))
    return sorted(found)


def to_win(bottle, path):
    rel = os.path.relpath(path, os.path.join(bottle, "drive_c"))
    return "C:" + "\\\\" + rel.replace("/", "\\\\")


def logical_size():
    try:
        out = subprocess.run(
            ["osascript", "-e", 'tell application "Finder" to get bounds of window of desktop'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20).stdout.decode("utf-8", "ignore")
        nums = re.findall(r"\d+", out)
        if len(nums) >= 4:
            return int(nums[-2]), int(nums[-1])
    except Exception:
        pass
    return None


def is_retina():
    try:
        out = subprocess.run(["system_profiler", "SPDisplaysDataType"], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=30).stdout.decode("utf-8", "ignore")
        return "Retina" in out
    except Exception:
        return False


def auto_resolution():
    size = logical_size()
    if not size:
        return None
    w, h = size
    scale = 2 if is_retina() else 1
    return w * scale, h * scale


def backup(bottle):
    os.makedirs(BACKUP_ROOT, exist_ok=True)
    tag = os.path.basename(bottle)
    made = []
    for fn in ("user.reg", "system.reg"):
        src = os.path.join(bottle, fn)
        dst = os.path.join(BACKUP_ROOT, "%s-%s.orig" % (tag, fn))
        if os.path.isfile(src) and not os.path.isfile(dst):
            shutil.copy2(src, dst)
            made.append(fn)
    if made:
        info("首次备份原始注册表：%s -> %s" % ("、".join(made), BACKUP_ROOT))


def apply(bottle, dpi, res, do_res, dry=False):
    user = RegFile(os.path.join(bottle, "user.reg"))
    sysr = RegFile(os.path.join(bottle, "system.reg"))
    changed = []

    user.set(S_MACDRV, "RetinaMode", '"y"', changed)

    if dpi is not None:
        user.set(S_DESKTOP, "LogPixels", "dword:%08x" % dpi, changed)
        user.set(S_FONTS, "LogPixels", "dword:%08x" % dpi, changed)
        sysr.set(S_SYSFONTS, "LogPixels", "dword:%08x" % dpi, changed)

    exes = find_exes(bottle)
    for p in exes:
        user.set(S_LAYERS, to_win(bottle, p), '"~ HIGHDPIAWARE"', changed)
    for n in BARE_NAMES:
        user.set(S_LAYERS, n, '"~ HIGHDPIAWARE"', changed)

    if do_res and res:
        user.set(S_VIDEO, "reswidth", "dword:%08x" % res[0], changed)
        user.set(S_VIDEO, "resheight", "dword:%08x" % res[1], changed)

    if not dry:
        user.save()
        sysr.save()
    return exes, changed


def report(bottle, res=None, dpi=96):
    user = RegFile(os.path.join(bottle, "user.reg"))
    sysr = RegFile(os.path.join(bottle, "system.reg"))

    step("状态检查：" + os.path.basename(bottle))
    retina = user.get(S_MACDRV, "RetinaMode")
    info("RetinaMode = %s  %s" % (retina, "OK" if retina == '"y"' else "应为 \"y\""))

    lp1 = user.get(S_DESKTOP, "LogPixels")
    lp2 = user.get(S_FONTS, "LogPixels")
    lp3 = sysr.get(S_SYSFONTS, "LogPixels")
    info("LogPixels 桌面=%s 字体=%s 硬件配置=%s" % (lp1, lp2, lp3))

    rw = user.get(S_VIDEO, "reswidth")
    rh = user.get(S_VIDEO, "resheight")
    if rw and rh:
        try:
            info("游戏分辨率 = %d × %d" % (int(rw.split(":")[-1], 16), int(rh.split(":")[-1], 16)))
        except ValueError:
            info("游戏分辨率 = %s / %s" % (rw, rh))
    else:
        info("游戏分辨率 = 未设置（进游戏后会按全屏默认值写入）")

    exes = find_exes(bottle)
    marked = 0
    for p in exes:
        if user.get(S_LAYERS, to_win(bottle, p)):
            marked += 1
    info("高 DPI 感知标记：%d/%d 个 exe 已标记" % (marked, len(exes)))
    if res:
        info("建议分辨率 = %d × %d" % res)

    ok = retina == '"y"' and marked == len(exes)
    if dpi is not None:
        ok = ok and lp1 == "dword:%08x" % dpi
    print()
    info("结论：%s" % ("配置完整" if ok else "配置不完整，请运行一次修复"))
    return ok


def restore(bottle):
    tag = os.path.basename(bottle)
    step("还原注册表：" + tag)
    done = []
    for fn in ("user.reg", "system.reg"):
        bk = os.path.join(BACKUP_ROOT, "%s-%s.orig" % (tag, fn))
        if os.path.isfile(bk):
            shutil.copy2(bk, os.path.join(bottle, fn))
            done.append(fn)
    info(("已还原：" + "、".join(done)) if done else "没有找到备份，无法还原")


def main():
    ap = argparse.ArgumentParser(description="11 平台 War3 / CrossOver 分辨率与 DPI 偏移修复")
    ap.add_argument("--bottle", help="CrossOver 容器名，例如 win10_64；不填则自动查找")
    ap.add_argument("--dpi", type=int, default=None,
                    help="写入的 DPI（96 / 120 / 144 / 192）；不填则保持当前值")
    ap.add_argument("--resolution", help="手动指定游戏分辨率，例如 2704x1756")
    ap.add_argument("--keep-resolution", action="store_true", help="不改动游戏分辨率")
    ap.add_argument("--verify", action="store_true", help="只检查状态，不改动文件")
    ap.add_argument("--restore", action="store_true", help="用首次备份还原注册表")
    ap.add_argument("--kill-wine", action="store_true", help="先结束容器内 Wine 进程再改（推荐）")
    ap.add_argument("--dry-run", action="store_true", help="只显示会改动哪些项，不写入文件")
    args = ap.parse_args()

    bottles = find_bottles(args.bottle)

    res = None
    if args.resolution:
        m = re.match(r"(\d+)\s*[x×*]\s*(\d+)", args.resolution.strip().lower())
        if not m:
            raise SystemExit("--resolution 格式应为 2704x1756")
        res = (int(m.group(1)), int(m.group(2)))
    elif not args.keep_resolution:
        res = auto_resolution()
        if not res:
            info("未能自动识别屏幕尺寸，将不改动游戏分辨率")

    print("=" * 72)
    print("11 平台 War3 / CrossOver 分辨率与 DPI 修复工具")
    for b in bottles:
        print("容器：" + b)
    print("=" * 72)

    if args.restore:
        for b in bottles:
            restore(b)
        print()
        for b in bottles:
            report(b, res, args.dpi)
        return 0

    if args.verify:
        ok = True
        for b in bottles:
            ok = report(b, res, args.dpi) and ok
        return 0 if ok else 1

    if args.kill_wine and not args.dry_run:
        for b in bottles:
            kill_wine(b)
    else:
        info("提示：改注册表前最好先退出 CrossOver 里的 Windows 程序（或用 --kill-wine 自动结束）")

    ok = True
    for b in bottles:
        if not args.dry_run:
            backup(b)
        step("写入配置" + ("（演练，不落盘）" if args.dry_run else ""))
        exes, changed = apply(b, args.dpi, res, bool(res), args.dry_run)
        info("%s，RetinaMode = y，已标记 %d 个 exe"
             % ("DPI 保持不变" if args.dpi is None else "DPI = %d" % args.dpi, len(exes)))
        if res:
            info("游戏分辨率 -> %d × %d" % res)
        info("本次改动 %d 项%s" % (len(changed), "" if changed else "（已是最新状态）"))
        if args.dry_run:
            continue
        print()
        ok = report(b, res, args.dpi) and ok

    if args.dry_run:
        print()
        info("以上为演练结果，未写入任何文件。去掉 --dry-run 即真正执行。")
        return 0

    if ok:
        print()
        info("全部完成。请完全退出 CrossOver 中的 Windows 程序后重新启动 11 平台。")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())