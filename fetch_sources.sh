#!/bin/sh
# 拉取 mpv 全部依赖源码（浅克隆，可重复执行；在脚本所在目录克隆）
# 提示:
#   - libmali 的 deb 不在脚本内（体积大且属于外部发布物），见 README 第 3 节手动下载
set -e
cd "$(dirname "$0")"

clone() { # clone <dir> <url> [ref]
  dir="$1"; url="$2"; ref="$3"
  if [ -d "$dir/.git" ]; then
    echo "[skip] $dir 已存在"
    return
  fi
  echo "[clone] $dir <- $url ($ref)"
  if [ -n "$ref" ]; then
    git clone --depth 1 --single-branch --branch "$ref" "$url" "$dir"
  else
    git clone --depth 1 "$url" "$dir"
  fi
}

# --- 基础 ---
clone zlib       https://github.com/madler/zlib           v1.3.1
clone expat      https://github.com/libexpat/libexpat     R_2_6_2
clone libffi     https://github.com/libffi/libffi         v3.4.6

# --- FFmpeg 直接依赖 ---
clone libdrm     https://gitlab.freedesktop.org/mesa/drm  libdrm-2.4.121 || \
  clone libdrm   https://github.com/robclark/libdrm       master
clone mpp        https://github.com/rockchip-linux/mpp    ""
clone openssl    https://github.com/openssl/openssl       openssl-3.0.13
clone libxml2    https://github.com/GNOME/libxml2         v2.12.5
clone alsa-lib   https://github.com/alsa-project/alsa-lib v1.2.11
clone dav1d      https://github.com/videolan/dav1d        1.4.1

# --- libass 依赖链 ---
clone freetype   https://github.com/freetype/freetype     VER-2-13-2
# freetype 测试程序用的 dlg 子模块
git -C freetype submodule update --init --depth 1 subprojects/dlg 2>/dev/null || true
clone fribidi    https://github.com/fribidi/fribidi       v1.0.13
clone harfbuzz   https://github.com/harfbuzz/harfbuzz     8.3.0
clone fontconfig https://gitlab.freedesktop.org/fontconfig/fontconfig 2.15.0 || \
  clone fontconfig https://github.com/freedesktop/fontconfig 2.15.0
clone libass     https://github.com/libass/libass         0.17.2

# --- mpv 专用 ---
clone libplacebo https://github.com/haasn/libplacebo      v5.264.1 || \
  clone libplacebo https://github.com/haasn/libplacebo    master
# libplacebo 子模块：glad 必需；Vulkan-Headers 即使 -Dvulkan=disabled 也强制要求；
# jinja/markupsafe 供构建期代码生成
git -C libplacebo submodule update --init --depth 1 \
    3rdparty/glad 3rdparty/Vulkan-Headers 3rdparty/jinja 3rdparty/markupsafe 2>/dev/null || true
clone wayland    https://gitlab.freedesktop.org/wayland/wayland 1.22.0 || \
  clone wayland  https://github.com/wayland-project/wayland 1.22.0
clone wayland-protocols https://github.com/wayland-project/wayland-protocols 1.32 || \
  clone wayland-protocols https://gitlab.freedesktop.org/wayland/wayland-protocols 1.32
clone xkbcommon  https://github.com/xkbcommon/libxkbcommon xkbcommon-1.6.0
clone lua        https://github.com/lua/lua               v5.2.3
clone mujs       https://github.com/ArtifexSoftware/mujs  ""

# --- GL/EGL 头文件（libmali-rockchip）: 仓库很大，只稀疏检出 include/ 目录 ---
if [ -d libmali-rockchip/.git ]; then
  echo "[skip] libmali-rockchip 已存在"
else
  echo "[clone] libmali-rockchip <- tsukumijima/libmali-rockchip (sparse: include/)"
  git clone --depth 1 --filter=blob:none --sparse \
      https://github.com/tsukumijima/libmali-rockchip libmali-rockchip
  (cd libmali-rockchip && git sparse-checkout set include)
fi

# --- 最终产物 ---
clone ffmpeg     https://github.com/FFmpeg/FFmpeg         n6.1
clone mpv        https://github.com/mpv-player/mpv        v0.36.0

echo "=== 全部拉取完成 ==="
ls -d */
