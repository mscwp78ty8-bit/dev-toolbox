#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""11 对战平台 War3 在 CrossOver/Wine 下 0xC0000005 (at 0x00000000) 崩溃的一键修复工具。

原理：
  平台注入的 DxRender.dll 在初始化时会调用一串 OpenGL 3.0+ 扩展函数
  (glGenVertexArrays / glMapBufferRange / glBlitFramebuffer ...)。
  Wine 的 wined3d 只给 legacy GL 2.1 上下文，wglGetProcAddress 对这批函数返回 NULL，
  于是 `call NULL` -> EIP=0 -> 0xC0000005。
  把 DxRender.dll 里 RVA 0x76AC 处的 `jne` 改成 `jmp`（75 7B -> EB 7B），
  就能跳过整段 GL 渲染器创建逻辑，直接走 D3D9 兜底分支。

难点：
  平台每次启动都会比对 gp_1297.zip 与解压目录，不一致就重新解压覆盖；
  还会用 Config/DownloadList.xml 里的 md5 校验 zip，不一致就从服务器重新下载。
  所以必须把 4 个地方同时改成一致状态，补丁才不会被还原。

用法：
  python3 fix-war3-dxrender.py            # 一键修复（可反复执行，幂等）
  python3 fix-war3-dxrender.py --verify   # 只检查当前状态
  python3 fix-war3-dxrender.py --restore  # 还原为官方原版
  python3 fix-war3-dxrender.py --watch 1  # 常驻守护，发现被还原就立刻重打
"""

import argparse
import datetime
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import zipfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BACKUP_DIR = os.path.join(SCRIPT_DIR, ".backup", "w3l")

BOTTLE_ROOT = os.path.expanduser("~/Library/Application Support/CrossOver/Bottles")
W3L_REL = os.path.join("drive_c", "Program Files (x86)", "5211game", "W3L")

ZIP_NAME = "gp_1297.zip"
DLL_NAME = "DxRender.dll"

PATCH_RVA = 0x76AC
BYTES_ORIG = b"\x75\x7b"
BYTES_PATCH = b"\xeb\x7b"
GUARD = b"\x8b\xf8"


def md5hex(data):
    return hashlib.md5(data).hexdigest()


def info(msg):
    print("  " + msg)


def step(msg):
    print("\n[%s]" % msg)


class Paths(object):
    def __init__(self, w3l):
        self.w3l = w3l
        self.zip = os.path.join(w3l, "PatchZip", "war3", ZIP_NAME)
        self.dll = os.path.join(w3l, "Patch", "war3", "gp_1297", DLL_NAME)
        self.dll_orig = self.dll + ".orig"
        self.md5dat = os.path.join(w3l, "MD5.dat")
        self.dlist = os.path.join(w3l, "core", "Config", "DownloadList.xml")


def find_w3ls(bottle=None):
    if bottle:
        c = os.path.join(BOTTLE_ROOT, bottle, W3L_REL)
        return [c] if os.path.isfile(os.path.join(c, "PatchZip", "war3", ZIP_NAME)) else []
    out = []
    if os.path.isdir(BOTTLE_ROOT):
        for name in sorted(os.listdir(BOTTLE_ROOT)):
            c = os.path.join(BOTTLE_ROOT, name, W3L_REL)
            if os.path.isfile(os.path.join(c, "PatchZip", "war3", ZIP_NAME)):
                out.append(c)
    return out


def pe_rva_to_off(data, rva):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    for i in range(nsec):
        base = pe + 24 + opt_size + i * 40
        vsz, va, rsz, raw = struct.unpack_from("<IIII", data, base + 8)
        if va <= rva < va + max(vsz, rsz):
            return raw + (rva - va)
    raise ValueError("RVA 0x%X 不在任何节内" % rva)


def patch_off(data):
    return pe_rva_to_off(data, PATCH_RVA)


def is_patched(data):
    off = patch_off(data)
    return data[off:off + 2] == BYTES_PATCH


def is_original(data):
    off = patch_off(data)
    return data[off:off + 2] == BYTES_ORIG and data[off - 2:off] == GUARD


def make_patched(orig):
    if not is_original(orig):
        off = patch_off(orig)
        raise ValueError("DxRender.dll 版本不符：RVA 0x%X 处字节为 %s，期望 75 7b（前面应为 8b f8）"
                         % (PATCH_RVA, orig[off:off + 2].hex()))
    off = patch_off(orig)
    out = bytearray(orig)
    out[off:off + 2] = BYTES_PATCH
    return bytes(out)


def get_zip_entry(zip_path, name):
    z = zipfile.ZipFile(zip_path)
    for i in z.infolist():
        if i.filename.lower() == name.lower():
            return z, i
    raise ValueError("%s 里找不到 %s" % (zip_path, name))


def read_original_dll(p):
    cands = []
    if os.path.isfile(p.dll_orig):
        cands.append(("磁盘 %s.orig" % DLL_NAME, open(p.dll_orig, "rb").read()))
    if os.path.isfile(p.dll):
        cands.append(("磁盘 %s" % DLL_NAME, open(p.dll, "rb").read()))
    if os.path.isfile(p.zip):
        z, e = get_zip_entry(p.zip, DLL_NAME)
        cands.append(("zip 内 %s" % DLL_NAME, z.read(e.filename)))
    bk = os.path.join(BACKUP_DIR, ZIP_NAME + ".orig")
    if os.path.isfile(bk):
        z, e = get_zip_entry(bk, DLL_NAME)
        cands.append(("备份 zip 内 %s" % DLL_NAME, z.read(e.filename)))
    for tag, data in cands:
        try:
            if is_original(data):
                return data, tag
        except Exception:
            continue
    raise ValueError("找不到未打补丁的原始 %s，请先用 --restore 或重新下载平台补丁包" % DLL_NAME)


def ensure_backup(p):
    os.makedirs(BACKUP_DIR, exist_ok=True)
    made = []
    pairs = [("gp_1297.zip.orig", p.zip), ("MD5.dat.orig", p.md5dat), ("DownloadList.xml.orig", p.dlist)]
    for bk_name, src in pairs:
        dst = os.path.join(BACKUP_DIR, bk_name)
        if not os.path.isfile(dst) and os.path.isfile(src):
            shutil.copy2(src, dst)
            made.append(bk_name)
    if made:
        info("已备份官方原件到 %s：%s" % (BACKUP_DIR, "、".join(made)))


def rewrite_zip(zip_path, patched_dll):
    tmp = zip_path + ".tmp"
    zin = zipfile.ZipFile(zip_path)
    changed = False
    with zipfile.ZipFile(tmp, "w") as zout:
        for e in zin.infolist():
            data = zin.read(e.filename)
            if e.filename.lower() == DLL_NAME.lower():
                if data != patched_dll:
                    if len(data) != len(patched_dll):
                        raise ValueError("大小不一致：zip 内 %d，补丁后 %d" % (len(data), len(patched_dll)))
                    data = patched_dll
                    changed = True
            zi = zipfile.ZipInfo(e.filename, date_time=e.date_time)
            zi.compress_type = e.compress_type
            zi.external_attr = e.external_attr
            zi.internal_attr = e.internal_attr
            zi.create_system = e.create_system
            zi.extra = e.extra
            zi.comment = e.comment
            zout.writestr(zi, data)
    zin.close()
    if not changed:
        os.remove(tmp)
        return False
    os.replace(tmp, zip_path)
    return True


def update_md5dat(path, zip_md5):
    raw = open(path, "rb").read()
    pat = re.compile(br'("gp_1297\.zip"\s*:\s*")([0-9A-Fa-f]+)(")')
    if not pat.search(raw):
        raise ValueError("MD5.dat 里找不到 gp_1297.zip 记录")
    new, n = pat.subn(lambda m: m.group(1) + zip_md5.upper().encode() + m.group(3), raw, count=1)
    if new != raw:
        open(path, "wb").write(new)
        return True
    return False


def update_downloadlist(path, zip_md5):
    raw = open(path, "rb").read()
    pat = re.compile(br'(name="gp_1297\.zip"[^>]*?md5=")([0-9A-Fa-f]+)(")')
    if not pat.search(raw):
        raise ValueError("DownloadList.xml 里找不到 gp_1297.zip 条目")
    new, n = pat.subn(lambda m: m.group(1) + zip_md5.upper().encode() + m.group(3), raw, count=1)
    if new != raw:
        open(path, "wb").write(new)
        return True
    return False


def plan(p):
    acts = []
    ondisk = open(p.dll, "rb").read()
    if not is_patched(ondisk):
        acts.append("磁盘 %s：75 7B -> EB 7B" % DLL_NAME)
    z, e = get_zip_entry(p.zip, DLL_NAME)
    inzip = z.read(e.filename)
    z.close()
    if not is_patched(inzip):
        acts.append("zip 内 %s：75 7B -> EB 7B（重建 gp_1297.zip）" % DLL_NAME)
    if inzip != ondisk:
        acts.append("统一磁盘与 zip 内的 %s（两者最终都指向补丁版）" % DLL_NAME)
    zipmd5 = md5hex(open(p.zip, "rb").read())
    txt = open(p.md5dat, "rb").read().decode("utf-8", "ignore")
    m = re.search(r'"gp_1297\.zip"\s*:\s*"([0-9A-Fa-f]+)"', txt)
    raw = open(p.dlist, "rb").read()
    m2 = re.search(br'name="gp_1297\.zip"[^>]*?md5="([0-9A-Fa-f]+)"', raw)
    if not m or m.group(1).upper() != zipmd5.upper():
        acts.append("重写 MD5.dat 里的 gp_1297.zip md5")
    if not m2 or m2.group(1).decode().upper() != zipmd5.upper():
        acts.append("重写 DownloadList.xml 里的 gp_1297.zip md5")
    if not acts:
        acts.append("四处已自洽，无需改动")
    return acts


def platform_running():
    try:
        out = subprocess.run(["ps", "-axo", "command"], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=10).stdout.decode("utf-8", "ignore")
    except Exception:
        return False
    keys = ("11client.exe", "war3loader.exe", "war3lobby.exe", "w3l.exe")
    for line in out.splitlines():
        low = line.lower()
        if any(k in low for k in keys):
            return True
    return False


def verify(p, quiet=False):
    ok = True
    if not quiet:
        step("状态检查")
    try:
        ondisk = open(p.dll, "rb").read()
        disk_patched = is_patched(ondisk)
        info("磁盘 %s：%s" % (DLL_NAME, "已打补丁 (EB)" if disk_patched else "未打补丁 (75)"))
        ok = ok and disk_patched
    except Exception as e:
        info("磁盘 %s 读取失败：%s" % (DLL_NAME, e))
        return False

    z, e = get_zip_entry(p.zip, DLL_NAME)
    inzip = z.read(e.filename)
    zip_patched = is_patched(inzip)
    info("zip 内 %s：%s" % (DLL_NAME, "已打补丁 (EB)" if zip_patched else "未打补丁 (75)"))
    ok = ok and zip_patched

    same = inzip == ondisk
    info("zip 内与磁盘内容一致：%s（不一致时平台会重新解压覆盖）" % ("是" if same else "否"))
    ok = ok and same

    zipmd5 = md5hex(open(p.zip, "rb").read())
    txt = open(p.md5dat, "rb").read().decode("utf-8", "ignore")
    m = re.search(r'"gp_1297\.zip"\s*:\s*"([0-9A-Fa-f]+)"', txt)
    md5_ok = bool(m) and m.group(1).upper() == zipmd5.upper()
    info("MD5.dat 记录与 zip 实际 md5 一致：%s" % ("是" if md5_ok else "否（会被平台重新下载）"))
    ok = ok and md5_ok

    raw = open(p.dlist, "rb").read()
    m2 = re.search(br'name="gp_1297\.zip"[^>]*?md5="([0-9A-Fa-f]+)"', raw)
    dl_ok = bool(m2) and m2.group(1).decode().upper() == zipmd5.upper()
    info("DownloadList.xml 记录与 zip 实际 md5 一致：%s" % ("是" if dl_ok else "否（会被平台重新下载）"))
    ok = ok and dl_ok

    if not quiet:
        print()
        print("  结论：%s" % ("补丁已生效且不会被平台还原" if ok else "状态不完整，请运行一次修复"))
    return ok


def apply_fix(p, quiet=False):
    ensure_backup(p)
    orig, src = read_original_dll(p)
    patched = make_patched(orig)
    if not quiet:
        step("打补丁")
        info("原始 DLL 来源：%s（md5 %s）" % (src, md5hex(orig)))
        info("补丁位置：RVA 0x%X（文件偏移 0x%X） 75 7B -> EB 7B"
             % (PATCH_RVA, patch_off(orig)))

    changed = False

    ondisk = open(p.dll, "rb").read() if os.path.isfile(p.dll) else b""
    if ondisk != patched:
        open(p.dll, "wb").write(patched)
        changed = True
        if not quiet:
            info("已写入磁盘 %s（md5 %s）" % (DLL_NAME, md5hex(patched)))

    z, e = get_zip_entry(p.zip, DLL_NAME)
    if z.read(e.filename) != patched:
        z.close()
        rewrite_zip(p.zip, patched)
        changed = True
        if not quiet:
            info("已替换 zip 内 %s" % DLL_NAME)
    else:
        z.close()

    zipmd5 = md5hex(open(p.zip, "rb").read())
    if update_md5dat(p.md5dat, zipmd5):
        changed = True
        if not quiet:
            info("已更新 MD5.dat")
    if update_downloadlist(p.dlist, zipmd5):
        changed = True
        if not quiet:
            info("已更新 DownloadList.xml")

    z, e = get_zip_entry(p.zip, DLL_NAME)
    try:
        ts = time.mktime(datetime.datetime(*e.date_time).timetuple())
        os.utime(p.dll, (ts, ts))
    finally:
        z.close()

    if not quiet:
        if changed:
            info("修复完成（本次有改动）")
        else:
            info("已是最新状态，无需改动")
    return True


def restore(p):
    step("还原官方原版")
    done = []
    bk_zip = os.path.join(BACKUP_DIR, "gp_1297.zip.orig")
    bk_md5 = os.path.join(BACKUP_DIR, "MD5.dat.orig")
    bk_dl = os.path.join(BACKUP_DIR, "DownloadList.xml.orig")
    if os.path.isfile(bk_zip):
        shutil.copy2(bk_zip, p.zip)
        done.append("gp_1297.zip")
    if os.path.isfile(bk_md5):
        shutil.copy2(bk_md5, p.md5dat)
        done.append("MD5.dat")
    if os.path.isfile(bk_dl):
        shutil.copy2(bk_dl, p.dlist)
        done.append("DownloadList.xml")
    if done:
        info("已还原：" + "、".join(done))
    if os.path.isfile(bk_zip):
        z, e = get_zip_entry(bk_zip, DLL_NAME)
        orig = z.read(e.filename)
        z.close()
        open(p.dll, "wb").write(orig)
        ts = time.mktime(datetime.datetime(*e.date_time).timetuple())
        os.utime(p.dll, (ts, ts))
        info("已还原磁盘 %s（md5 %s）" % (DLL_NAME, md5hex(orig)))
    if not done and not os.path.isfile(bk_zip):
        info("没有找到备份，无法还原")


def main():
    ap = argparse.ArgumentParser(description="11 平台 War3 在 CrossOver 下崩溃的一键修复")
    ap.add_argument("--bottle", help="CrossOver 容器名，例如 win10_64；不填则自动查找")
    ap.add_argument("--verify", action="store_true", help="只检查状态，不改动文件")
    ap.add_argument("--dry-run", action="store_true", help="只显示会改动哪些项，不写入文件")
    ap.add_argument("--restore", action="store_true", help="还原为官方原版")
    ap.add_argument("--watch", type=float, metavar="秒", help="常驻守护：发现补丁被还原就立刻重新打上")
    args = ap.parse_args()

    w3ls = find_w3ls(args.bottle)
    if not w3ls:
        print("找不到 11 平台目录（W3L），请确认已安装并指定 --bottle")
        return 1

    print("=" * 72)
    print("11 平台 War3 / CrossOver 崩溃修复工具")
    for w in w3ls:
        print("平台目录：" + w)
    print("=" * 72)

    if args.restore:
        for w in w3ls:
            restore(Paths(w))
            print()
            verify(Paths(w))
        return 0

    if args.verify:
        ok = True
        for w in w3ls:
            ok = verify(Paths(w)) and ok
        return 0 if ok else 1

    if args.dry_run:
        for w in w3ls:
            step("改动预览（演练，不落盘）")
            try:
                for a in plan(Paths(w)):
                    info(a)
            except Exception as e:
                info("预览失败：%s" % e)
        return 0

    if platform_running():
        print("\n  提示：检测到平台或游戏正在运行，建议先退出平台再修复（改动仍会生效，但可能被运行中的平台覆盖）。")

    ok = True
    for w in w3ls:
        p = Paths(w)
        apply_fix(p)
        print()
        ok = verify(p) and ok

    if args.watch:
        print("\n守护模式已启动，每 %.1f 秒检查一次，Ctrl+C 退出。" % args.watch)
        try:
            while True:
                for w in w3ls:
                    p = Paths(w)
                    try:
                        data = open(p.dll, "rb").read()
                        if not is_patched(data) or data != read_zip_dll(p):
                            apply_fix(p, quiet=True)
                            print("[%s] %s 补丁被还原，已自动重新打上"
                                  % (time.strftime("%H:%M:%S"), os.path.basename(os.path.dirname(p.w3l))))
                    except Exception as e:
                        print("[%s] 守护检查出错：%s" % (time.strftime("%H:%M:%S"), e))
                time.sleep(args.watch)
        except KeyboardInterrupt:
            print("\n已退出守护模式。")
    return 0 if ok else 1


def read_zip_dll(p):
    z, e = get_zip_entry(p.zip, DLL_NAME)
    try:
        return z.read(e.filename)
    finally:
        z.close()


if __name__ == "__main__":
    sys.exit(main())