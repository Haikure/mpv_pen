#!/usr/bin/env bash
# 打包可移植 mpv 部署目录：mpv-install/{bin,lib}
# - 提取 mpv 及其全部运行时共享库依赖（排除设备基础系统库）
# - 保留 SONAME 符号链接（DT_NEEDED 名 -> 版本化真实文件）
# - patchelf：mpv 设 $ORIGIN/../lib，各 .so 设 $ORIGIN
set -euo pipefail
cd "$(dirname "$0")"

MPV=/opt/mpv
FF=/opt/ffmpeg
OUT=mpv-install
BIN=$OUT/bin
LIB=$OUT/lib

# 设备基础系统库（由设备 OS 提供，不打包）
# 注: libmali.so.1 目标机已自带系统 Mali 驱动，不打包
# 注: librockchip_mpp.so.1 目标机已自带（内核 4.4.159 的 VPU 驱动配套版本），
#     GitHub-master 版 mpp 的 ioctl 0x40086c01 会被该内核拒绝（unknown vpu service ioctl）
BASE_RE='^(ld-linux|libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|libgcc_s\.so\.1|libstdc\+\+\.so\.6|libmali\.so\.1|librockchip_mpp\.so\.1)$'

# 查找顺序：mpv 自带 lib → 我们的 sysroot → 设备系统路径
SEARCH=(/opt/mpv/lib /opt/ffmpeg/lib /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu /usr/lib /lib)

rm -rf "$OUT"
mkdir -p "$BIN" "$LIB"

# ---- 1) mpv 本体 + libmpv（保留符号链接链） ----
cp "$MPV/bin/mpv" "$BIN/mpv"
cp -a "$MPV"/lib/libmpv.so* "$LIB/"

# ---- 2) 递归收集动态依赖闭包 ----
declare -A DEPS   # soname -> 找到的路径
declare -A SEEN

find_lib() { # find_lib <soname> -> 输出路径
    for d in "${SEARCH[@]}"; do
        if [ -e "$d/$1" ]; then echo "$d/$1"; return 0; fi
    done
    return 1
}

collect() { # collect <elf 文件>
    local f="$1" dep src
    while read -r dep; do
        [ -z "$dep" ] && continue
        [[ "$dep" =~ $BASE_RE ]] && continue
        [ -n "${SEEN[$dep]:-}" ] && continue
        SEEN[$dep]=1
        if src=$(find_lib "$dep"); then
            DEPS[$dep]="$src"
            echo "  依赖: $dep -> $src"
            collect "$src"
        else
            echo "  跳过(设备提供): $dep"
        fi
    done < <(readelf -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
}

echo "== 解析 mpv 依赖闭包 =="
collect "$BIN/mpv"

# ---- 3) 拷贝库：真实文件 + SONAME 符号链接 ----
echo "== 拷贝库文件 =="
for dep in "${!DEPS[@]}"; do
    src="${DEPS[$dep]}"
    real=$(readlink -f "$src")
    if [ ! -e "$LIB/$(basename "$real")" ]; then
        cp -a "$real" "$LIB/"
        echo "  + $(basename "$real")"
    fi
    # SONAME 符号链接（若自身就是 SONAME 名则跳过）
    if [ "$dep" != "$(basename "$real")" ]; then
        ln -sf "$(basename "$real")" "$LIB/$dep"
        echo "  ln $dep -> $(basename "$real")"
    fi
done

# ---- 4) patchelf 设置 $ORIGIN rpath ----
echo "== patchelf =="
patchelf --set-rpath '$ORIGIN/../lib' "$BIN/mpv"
echo "  mpv: \$ORIGIN/../lib"
for f in "$LIB"/*.so*; do
    [ -L "$f" ] && continue        # 只改真实文件，符号链接跳过
    [ -e "$f" ] || continue
    patchelf --set-rpath '$ORIGIN' "$f"
    echo "  $(basename "$f"): \$ORIGIN"
done

# ---- 5) strip：mpv 全量 strip，.so 用 --strip-unneeded（保留动态符号） ----
# x-tools GNU strip；路径与 README 第 4 节 XT 变量一致，不同请修改
STRIP="${XT:-$HOME/build/x-tools/aarch64-unknown-linux-gnu/bin}/aarch64-unknown-linux-gnu-strip"
echo "== strip =="
"$STRIP" "$BIN/mpv"
echo "  mpv stripped"
for f in "$LIB"/*.so*; do
    [ -L "$f" ] && continue        # 符号链接跳过
    [ -e "$f" ] || continue
    "$STRIP" --strip-unneeded "$f" 2>/dev/null || true
done
echo "  libs stripped"

# ---- 6) XKB keymap 数据（wlshm VO 运行时必需；xkbcommon 已静态嵌入 mpv） ----
XKB_SRC=/usr/share/X11/xkb
if [ -d "$XKB_SRC" ]; then
    XKB_REAL=$(readlink -f "$XKB_SRC")   # 解析符号链接（如 -> ../xkeyboard-config-2）
    mkdir -p "$OUT/share/X11"
    cp -a "$XKB_REAL" "$OUT/share/X11/xkb"
    echo "== XKB 数据已打包: $OUT/share/X11/xkb ($(du -sh "$OUT/share/X11/xkb" | cut -f1))"
else
    echo "警告: 未找到 $XKB_SRC，跳过 xkb 数据（wlshm 将无法初始化）" >&2
fi

# ---- 7) 设备启动 wrapper----
cat > "$OUT/mpv" <<'EOF'
#!/bin/sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export LD_LIBRARY_PATH="$SCRIPT_DIR/lib:$LD_LIBRARY_PATH"
export FONTCONFIG_PATH=/etc/fonts
export FONTCONFIG_FILE=/etc/fonts/fonts.conf
export ALSA_CONFIG_PATH="/usr/share/alsa/alsa.conf"
export XKB_CONFIG_ROOT="$SCRIPT_DIR/share/X11/xkb"

# 创建锁文件目录
LOCK_DIR="/tmp/audio_wakelocks"
mkdir -p "$LOCK_DIR"

# 将当前 shell 的 PID 写入锁文件
echo "$$" > "$LOCK_DIR/VideoPlayer.lock"

# 启动 mpv（前台运行）
"$SCRIPT_DIR/bin/mpv" \
--config-dir="$SCRIPT_DIR/config" \
"$@"

echo "mpv 已退出"

exit 0
EOF
chmod +x "$OUT/mpv"
echo "== 设备 wrapper 已生成: $OUT/mpv"

echo "== 完成 =="
du -sh "$OUT"
ls "$BIN" "$LIB" | head -40
