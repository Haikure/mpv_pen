# 有道词典笔2代 mpv 播放器 · 从零交叉编译指南

本指南记录如何在 x86-64 Linux 宿主机上，从源码交叉编译一个适配 **有道词典笔2代** （Rockchip / Mali-G31 / aarch64 / Wayland 触控屏）的 mpv 播放器，并打包部署到设备。

整个过程分为：**宿主机工具链 → 依赖编译 → FFmpeg → mpv → 打包 → 设备部署**。

> **提醒**：文中所有 `~/build`、`/opt/ffmpeg`、`/home/yourname` 都是示例。工作目录、zig 工具链位置、x-tools 位置请按自己的环境替换

---

## 0. 目标设备概况

| 项目 | 实测值 |
|---|---|
| 架构 | aarch64（arm64），glibc 2.27 目标 |
| 内核 | Linux 4.4.159（2023-08 固件），VPU 驱动 `rk_vcodec` / `/dev/vpu_service` |
| GPU | Mali-G31（Bifrost），系统自带 `libmali.so.1` 驱动 |
| 视频硬解 | Rockchip MPP（H.264/H.265），系统自带 `librockchip_mpp.so.1`（与内核配套） |
| 显示 | Wayland 合成器，`vo=wlshm` 可用；170x320 竖屏，触控屏 |
| 音频 | ALSA（rk817 codec） |

> 设备固件自带的 `librockchip_mpp` 与内核 4.4.159 的 VPU 驱动严格配套。任何从较新源码自编的 mpp 都会发内核不认识的 ioctl（报 `unknown vpu service ioctl cmd 40086c01`），硬解直接卡死。因此**打包时不要带 mpp，用系统版**（见第 8 节）。同理 `libmali` 也用系统版。

---

## 1. 宿主机准备

这里示例将所有所需依赖安装到 `/opt/ffmpeg` 下，mpv将安装到 `/opt/mpv`，`~/build` 作为工作目录

### 1.1 zig 交叉工具链（编译器）

```sh
# 安装 zig（任意版本，提供 aarch64-linux-gnu 目标 + glibc 2.27）
zig version   # 需要支持 -target aarch64-linux-gnu.2.27
```

用包装脚本把 `zig cc/c++/ar/ranlib` 伪装成常规交叉工具链（目录 `~/build/zig-toolchain/`，仓库已附带）：

- `aarch64-linux-gnu-gcc`：转发 `zig cc -target aarch64-linux-gnu.2.27`
- `aarch64-linux-gnu-g++`：转发 `zig c++ -target aarch64-linux-gnu.2.27`
- `aarch64-linux-gnu-ar` / `ranlib`：转发 `zig ar` / `zig ranlib`
- `aarch64-linux-gnu-pkg-config`：锁定 `PKG_CONFIG_LIBDIR=/opt/ffmpeg/lib/pkgconfig:/opt/ffmpeg/share/pkgconfig`
- `aarch64-linux-gnu-strip`：**转发到交叉编译工具链的 GNU strip**

> **gcc 包装脚本的特殊处理**：zig 的 `-Xlinker` 不识别 `--version-script=FILE` 这种带 `=` 的形式，包装脚本会把成对的 `-Xlinker --version-script=FILE` 转成单个 `-Wl,--version-script=FILE`。

### 1.2 x-tools binutils（GNU ld / GNU strip）

zig 不提供 GNU strip，符号剥离必须用 crosstool-NG 的 binutils（或安装 [gcc aarch64 6.5 编译器](https://github.com/Redbeanw44602/aarch64-linux-gnu-gcc-6.5.0)）：

```
~/build/x-tools/aarch64-unknown-linux-gnu/bin/
├── aarch64-unknown-linux-gnu-strip   # GNU strip 2.39
├── aarch64-unknown-linux-gnu-ld      # GNU ld 2.39（mpp 的 cmake 需要）
├── aarch64-unknown-linux-gnu-ar
└── aarch64-unknown-linux-gnu-ranlib  # mpp 的 cmake 需要绝对路径
```

### 1.3 meson 交叉文件

`~/build/zig-toolchain/meson-aarch64-glibc227.ini`：

```ini
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
ranlib = 'aarch64-linux-gnu-ranlib'
pkg-config = '/home/yourname/build/zig-toolchain/aarch64-linux-gnu-pkg-config'
strip = 'aarch64-linux-gnu-strip'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['-O2', '-fPIC', '-I/opt/ffmpeg/include']
cpp_args = ['-O2', '-fPIC', '-I/opt/ffmpeg/include']
c_link_args = ['-L/opt/ffmpeg/lib', '-Wl,-rpath,/opt/ffmpeg/lib']
cpp_link_args = ['-L/opt/ffmpeg/lib', '-Wl,-rpath,/opt/ffmpeg/lib']
```

`~/build/zig-toolchain/meson-native-host.ini`（宿主侧工具，pkg_config_path 前置一个 `host-pkgconfig` 目录，用于放版本匹配的宿主 wayland-scanner，见 5.16）：

```ini
[binaries]
pkg-config = '/usr/bin/pkg-config'
wayland-scanner = '/usr/bin/wayland-scanner'

[built-in options]
pkg_config_path = ['/home/yourname/build/host-pkgconfig', '/usr/local/lib/pkgconfig', '/usr/share/pkgconfig', '/usr/local/share/pkgconfig', '/usr/lib/aarch64-linux-gnu/pkgconfig', '/usr/local/lib/aarch64-linux-gnu/pkgconfig']
```

### 1.4 构建环境

```sh
source ~/build/zig-env.sh   # 导出 CC/CXX/AR/RANLIB 与 PATH

# 通用编译参数
export CFLAGS="-O2 -fPIC -I/opt/ffmpeg/include"
export LDFLAGS="-L/opt/ffmpeg/lib -Wl,-rpath,/opt/ffmpeg/lib"
```

---

## 2. 目录布局

| 路径 | 用途 |
|---|---|
| `~/build/` | 工作区：全部源码 + 构建产物 + 打包脚本 |
| `/opt/ffmpeg` | 交叉 sysroot：所有依赖的 `include/ lib/ lib/pkgconfig/` 都装到这里 |
| `/opt/mpv` | mpv 安装前缀（`bin/mpv` + `lib/libmpv.so*`） |

---

## 3. 拉取源码

`fetch_sources.sh` ：复制到你的工作目录运行 `sh fetch_sources.sh`，它会在**脚本所在目录**浅克隆下面全部源码（已存在则跳过，可重复执行）

```
zlib v1.3.1             expat R_2_6_2            libffi v3.4.6
libdrm libdrm-2.4.121   mpp rockchip-linux/mpp master
openssl openssl-3.0.13  libxml2 v2.12.5          alsa-lib v1.2.11
dav1d 1.4.1             freetype VER-2-13-2      fribidi v1.0.13
harfbuzz 8.3.0          fontconfig 2.15.0        libass 0.17.2
libplacebo v5.264.1     wayland 1.22.0           wayland-protocols 1.32
xkbcommon xkbcommon-1.6.0  lua v5.2.3(!!)        mujs master
ffmpeg n6.1             mpv v0.36.0
libmali-rockchip（tsukumijima/libmali-rockchip，稀疏检出 include/）
```

> **lua 必须用 v5.2.3**：mpv 0.36 拒绝 5.3/5.4。GitHub 上 v5.2.3 的 Makefile 还有对象列表缺陷，见 5.19。

**libmali deb**（只取 GL/EGL 头文件与链接用的 blob，部署时不带）：

```sh
wget https://github.com/tsukumijima/libmali-rockchip/releases/download/v1.9-1-20260312-bd33ee2/libmali-bifrost-g31-g13p0-wayland-gbm_1.9-1_arm64.deb
dpkg-deb -x libmali-bifrost-g31-g13p0-wayland-gbm_1.9-1_arm64.deb libmali-deb
```

---

## 4. 通用构建模式

先定义三个路径变量

```sh
export CROSS="$HOME/build/zig-toolchain/meson-aarch64-glibc227.ini"
export NATIVE="$HOME/build/zig-toolchain/meson-native-host.ini"
export XT="$HOME/build/x-tools/aarch64-unknown-linux-gnu/bin"
```

**构建顺序**（遵循下层先建）：

```
zlib → expat → libffi → libdrm → mpp → openssl → libxml2 → alsa-lib → dav1d
→ freetype → fribidi → harfbuzz → fontconfig → libass
→ libplacebo → wayland → wayland-protocols → xkbcommon
→ lua → mujs → libmali(EGL) → ffmpeg → mpv
```

---

## 5. 各依赖要点

以下脚本假设已 `cd` 到对应源码目录，且已按第 4 节导出 `CROSS` / `NATIVE` / `XT`，并执行过 `source ~/build/zig-env.sh`。

### 5.1 zlib v1.3.1

```sh
./configure --prefix=/opt/ffmpeg
make -j"$(nproc)" && make install
```

### 5.2 expat R_2_6_2

```sh
./configure --prefix=/opt/ffmpeg --host=aarch64-linux-gnu --with-pic
make -j"$(nproc)" && make install
```

### 5.3 libffi v3.4.6

**必须在子目录里 configure**（在源码根目录 in-source 构建会失败）：

```sh
mkdir -p build && cd build
../configure --prefix=/opt/ffmpeg --host=aarch64-linux-gnu
make -j"$(nproc)" && make install
```

### 5.4 libdrm 2.4.121

libdrm 被 ffmpeg、mpp、libmali 依赖。

```sh
meson setup build --prefix=/opt/ffmpeg --cross-file="$CROSS" --native-file="$NATIVE" \
  -Dtests=false -Dman-pages=disabled
meson compile -C build && meson install -C build
```

### 5.5 mpp（rockchip-linux/mpp）

- **构建目录必须叫 `build-zig`**：仓库里 `build/` 是 git 跟踪的目录，`rm -rf build` 会删掉它。
- cmake 需要 **GNU ld 作为 CMAKE_LINKER**（zig 的 lld 在 mpp 的汇编/链接里有问题），CMAKE_AR / CMAKE_RANLIB 给 **x-tools 的绝对路径**。
- 产物：`/opt/ffmpeg/lib/librockchip_mpp.so*` + include 头（ffmpeg `--enable-rkmpp` 需要）。
- **部署时不要带 mpp**（用设备系统版，理由见第 0 节）。

```sh
cmake -B build-zig -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
  -DCMAKE_AR="$XT/aarch64-unknown-linux-gnu-ar" \
  -DCMAKE_RANLIB="$XT/aarch64-unknown-linux-gnu-ranlib" \
  -DCMAKE_LINKER="$XT/aarch64-unknown-linux-gnu-ld" \
  -DCMAKE_INSTALL_PREFIX=/opt/ffmpeg
cmake --build build-zig -j"$(nproc)" && cmake --install build-zig
```

### 5.6 openssl 3.0.13

使用 `make install_sw` 来跳过说明文件的安装以节省时间。

```sh
./Configure linux-aarch64 --prefix=/opt/ffmpeg --shared
make -j"$(nproc)" && make install_sw
```

### 5.7 libxml2 v2.12.5

> libxml2 的链接会传 `-Xlinker --version-script=...`，zig 的 `-Xlinker` 不认带 `=` 的单参数形式，报 `unsupported linker arg`。解法：在 `aarch64-linux-gnu-gcc` 包装脚本里把成对的 `-Xlinker --version-script=FILE` 改写为 `-Wl,--version-script=FILE`（见 1.1）。

```sh
./autogen.sh   # git 检出需要，tarball 可跳过
./configure --prefix=/opt/ffmpeg --host=aarch64-linux-gnu --without-python
make -j"$(nproc)" && make install
```

### 5.8 alsa-lib v1.2.11

alsa 是 B 站 AAC 音频输出的基础（`ao=alsa`）。

```sh
./configure --prefix=/opt/ffmpeg --host=aarch64-linux-gnu --disable-python
make -j"$(nproc)" && make install
```

### 5.9 dav1d 1.4.1

提供 AV1 软件解码（该芯片无 AV1 硬解）。

```sh
meson setup build --prefix=/opt/ffmpeg --cross-file="$CROSS" --native-file="$NATIVE" \
  -Denable_tools=false -Denable_tests=false
meson compile -C build && meson install -C build
```

### 5.10 freetype VER-2-13-2

```sh
./autogen.sh   # git 检出需要，tarball 可跳过
./configure --prefix=/opt/ffmpeg --host=aarch64-linux-gnu \
  --with-zlib --with-bzip2=no --with-png=no --with-harfbuzz=no
make -j"$(nproc)" && make install
```

### 5.11 fribidi v1.0.13

```sh
meson setup build --prefix=/opt/ffmpeg --cross-file="$CROSS" --native-file="$NATIVE" \
  -Ddocs=false -Dtests=false
meson compile -C build && meson install -C build
```

### 5.12 harfbuzz 8.3.0

```sh
meson setup build --prefix=/opt/ffmpeg --cross-file="$CROSS" --native-file="$NATIVE" \
  -Dtests=disabled -Ddocs=disabled -Dutilities=disabled
meson compile -C build && meson install -C build
```

### 5.13 fontconfig 2.15.0

依赖 freetype、expat。

```sh
meson setup build --prefix=/opt/ffmpeg --cross-file="$CROSS" --native-file="$NATIVE" \
  -Dtests=disabled -Dtools=disabled -Ddoc=disabled
meson compile -C build && meson install -C build
```

### 5.14 libass 0.17.2

字幕渲染，依赖 freetype/fribidi/harfbuzz/fontconfig。

```sh
meson setup build --prefix=/opt/ffmpeg --cross-file="$CROSS" --native-file="$NATIVE" \
  -Dlibass-tests=disabled -Dasync=disabled
meson compile -C build && meson install -C build
```

### 5.15 libplacebo v5.264.1

> 子模块 **glad 与 Vulkan-Headers 必须拉**（即使 `-Dvulkan=disabled` 也强制要求），`3rdparty/jinja` 与 `3rdparty/markupsafe` 供构建期代码生成：

```sh
git submodule update --init --depth 1 3rdparty/glad 3rdparty/Vulkan-Headers 3rdparty/jinja 3rdparty/markupsafe
meson setup build --prefix=/opt/ffmpeg --cross-file="$CROSS" --native-file="$NATIVE" \
  -Dvulkan=disabled -Dd3d11=disabled -Dopengl=enabled
meson compile -C build && meson install -C build
```

### 5.16 wayland 1.22.0

> wayland 的构建会校验宿主 `wayland-scanner` 版本，要求精确匹配。宿主自带的版本不对时，需要准备一个 **1.22.0 的宿主 wayland-scanner** 放到 `host-pkgconfig/` 里，并由 `meson-native-host.ini` 的 `pkg_config_path` 前置引用（见 1.3）。

```sh
meson setup build --prefix=/opt/ffmpeg --cross-file="$CROSS" --native-file="$NATIVE" \
  -Dtests=false -Ddocumentation=false
meson compile -C build && meson install -C build
```

### 5.17 wayland-protocols 1.32

```sh
meson setup build --prefix=/opt/ffmpeg --cross-file="$CROSS" --native-file="$NATIVE" \
  -Dtests=false
meson compile -C build && meson install -C build
```

### 5.18 xkbcommon 1.6.0

> 默认的 `xkb-config-root` 由 prefix 推导（`$prefix/share/X11/xkb`），编进 mpv 后是 `/opt/ffmpeg/share/X11/xkb`——设备上没有。运行时靠 wrapper 里 `XKB_CONFIG_ROOT` 环境变量覆盖（见第 8 节）。另外 xkbcommon 在最终 mpv 里是**静态链接**的，所以 bundle 只需要**数据目录**，不需要库文件。

```sh
meson setup build --prefix=/opt/ffmpeg --cross-file="$CROSS" --native-file="$NATIVE" \
  -Dxkbregistry=disabled
meson compile -C build && meson install -C build
```

### 5.19 lua v5.2.3

- **版本必须 5.2.3**：mpv 0.36 编译期检测 lua 版本，5.3/5.4 直接拒绝。
- 需要 `-D_GNU_SOURCE`，否则 `_longjmp` 隐式声明报错。
- **GitHub 上 v5.2.3 的 Makefile 对象列表有缺陷**：`CORE_O` 缺 `lctype.o`，`LIB_O` 缺 `lcorolib.o` 和 `lbitlib.o`。结果 mpv 最终链接报 `undefined symbol: luaopen_coroutine / luaopen_bit32 / luai_ctype_`。

解法：正常编完后再手动补三个对象进 `liblua.a`：

```sh
make linux MYCFLAGS="-O2 -fPIC -D_GNU_SOURCE -std=c99 -DLUA_USE_LINUX -fno-common"
# 补缺的对象（注意必须带 -fPIC，否则 mpv 链接报错）
aarch64-linux-gnu-gcc -Wall -O2 -fPIC -D_GNU_SOURCE -std=c99 -DLUA_USE_LINUX -fno-common -c lctype.c lcorolib.c lbitlib.c
aarch64-linux-gnu-ar rc liblua.a lctype.o lcorolib.o lbitlib.o
aarch64-linux-gnu-ranlib liblua.a
cp liblua.a /opt/ffmpeg/lib/
```

（也可改用 lua.org 官方 5.2.3 tarball，其 Makefile 是完整的，可跳过补丁。）

### 5.20 mujs

```sh
make release
cp build/release/libmujs.a /opt/ffmpeg/lib/
cp src/*.h /opt/ffmpeg/include/
```
mpv 的 `-Djavascript=enabled` 需要（可跳过，但需要 `-Djavascript=disable`）。

### 5.21 libmali-rockchip（GL/EGL 链接素材）

mpv 的 meson 需要 `dependency('egl')`，必须手工搭一套：

```sh
# 1) 头文件（稀疏检出 include/，拷进 sysroot）
cp -r libmali-rockchip/include/* /opt/ffmpeg/include/

# 2) 真正的 blob：deb 里的 libEGL.so.1 是零符号 shim，不能用！
#    用 libmali.so.1.9.0 作为真实实现，做符号链接链
cp libmali-deb/usr/lib/aarch64-linux-gnu/libmali.so.1.9.0 /opt/ffmpeg/lib/
cd /opt/ffmpeg/lib
ln -sf libmali.so.1.9.0 libmali.so.1
ln -sf libmali.so.1    libEGL.so.1
ln -sf libEGL.so.1     libEGL.so

# 3) 手写 egl.pc
cat > /opt/ffmpeg/lib/pkgconfig/egl.pc <<'EOF'
prefix=/opt/ffmpeg
libdir=${prefix}/lib
includedir=${prefix}/include

Name: egl
Description: Mali EGL
Version: 1.5.0
Libs: -L${libdir} -lEGL
Cflags: -I${includedir}
EOF
```

---

## 6. FFmpeg（n6.1）编译

```sh
./configure \
  --prefix=/opt/ffmpeg \
  --cc=aarch64-linux-gnu-gcc --cxx=aarch64-linux-gnu-g++ \
  --ar=aarch64-linux-gnu-ar --ranlib=aarch64-linux-gnu-ranlib \
  --target-os=linux --arch=aarch64 \
  --enable-cross-compile \
  --enable-shared --disable-static \
  --enable-gpl --enable-version3 \
  --enable-libdrm --enable-rkmpp --enable-openssl --enable-libxml2 \
  --enable-alsa --enable-libdav1d --enable-libass \
  --disable-doc --disable-encoders --disable-muxers \
  --disable-decoders \
  --enable-decoder='h264,hevc,aac,mp3,flac,opus,alac,ac3,eac3,h264_rkmpp,hevc_rkmpp,av1_rkmpp,libdav1d,srt,subrip,ass,ssa,mov_text,webvtt,pgssub,dvdsub,xsub' \
  --disable-demuxers \
  --enable-demuxer='dash,hls,flv,matroska,mov,mp3,flac,wav,mpegts,ogg,srt,subrip,ass,webvtt,lrc,mov_text,subviewer,subviewer1,microdvd,mpl2,jacosub,sami,realtext,stl,vplayer' \
  --disable-protocols \
  --enable-protocol='http,https,tcp,tls,file' \
  --extra-cflags=-I/opt/ffmpeg/include \
  --extra-ldflags='-L/opt/ffmpeg/lib -Wl,-rpath,$ORIGIN/../lib -Wl,-rpath,$ORIGIN' \
  --pkg-config=pkg-config \
  --strip="$XT/aarch64-unknown-linux-gnu-strip" \
  --disable-debug

make -j"$(nproc)" && make install
```

- **`--strip` 必须给 x-tools 的 GNU strip**（默认的 strip 命令在交叉环境不可靠）。
- 编完若 `config.h` 里 `HAVE_SYSCTL` 误检为 1（zig 目标下 sysctl 相关头探测异常），特征是编译时报缺少 `sys/sysctl.h` 头文件，续手动 sed 成 0，再重新编译相关对象。
- `--enable-rkmpp` 需要 `/opt/ffmpeg` 里有 mpp 的头文件和库（5.5）。

---

## 7. mpv（v0.36.0）编译

```sh
meson setup build-aarch64 ~/build/mpv \
  -Dlibmpv=true -Dtests=false \
  -Dwayland=enabled -Dx11=disabled -Dvulkan=disabled \
  -Degl=enabled -Dgl=enabled -Ddrm=enabled \
  -Dlua=enabled -Djavascript=enabled \
  -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled \
  -Dlcms2=disabled -Dlibarchive=disabled -Dlibbluray=disabled \
  -Dlibplacebo=enabled \
  -Dprefix=/opt/mpv -Dbuildtype=release \
  --cross-file="$CROSS" --native-file="$NATIVE"

meson compile -C build-aarch64
meson install -C build-aarch64
```

---

## 8. 打包（`pack_mpv.sh`）

脚本完成：依赖闭包收集 → 拷贝 + SONAME 符号链接 → patchelf → strip → xkb 数据 → 生成设备 wrapper。要点：

1. **依赖闭包**：`readelf -d` 递归收集 DT_NEEDED，查找顺序 `/opt/mpv/lib /opt/ffmpeg/lib /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu /usr/lib /lib`。
2. **排除设备系统库**（不打包，设备自带）：

   ```
   ld-linux libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1
   libgcc_s.so.1 libstdc++.so.6
   libmali.so.1           # 系统 Mali 驱动
   librockchip_mpp.so.1   # 系统 MPP（与 4.4.159 内核配套，见第 0 节）
   ```
3. **SONAME 符号链接**：每个库保留 `SONAME → 版本化真实文件` 链（如 `libavcodec.so.60 → libavcodec.so.60.31.102`）。
4. **patchelf**：`bin/mpv` → rpath `$ORIGIN/../lib`；每个真实 `.so` → rpath `$ORIGIN`（符号链接跳过）。最终全量扫描确保无 `/opt/` 残留。
5. **strip**：x-tools GNU strip；mpv 全量 strip，`.so` 用 `--strip-unneeded`（保留动态符号）。strip 后从约 147M 降到约 70M。
6. **xkb 数据**（wlshm VO 初始化必需，见第 0 节注）：拷贝宿主 `/usr/share/X11/xkb`（注意它是符号链接，要用 `readlink -f` 解析后拷贝真实目录）到 `mpv-install/share/X11/xkb`。
7. 生成设备 wrapper（含 `XKB_CONFIG_ROOT`，见下）。

最终 `mpv-install/` 约 **31M**：

```
mpv-install/
├── bin/mpv                # 3.5M（strip 后）
├── lib/                   # 38 项 = .so + SONAME 链接
├── share/X11/xkb/         # 4M，XKB keymap 数据
└── mpv                    # 设备启动 wrapper
```

---

## 9. 设备部署（设备 `/userdisk/mpv/`）

```
/userdisk/mpv/
├── bin/mpv
├── lib/               # 不含 libmali / librockchip_mpp
├── share/X11/xkb/
├── config/            # mpv.conf + scripts/ + fonts/
└── mpv                # 启动 wrapper（可执行）
```

---

## 10. 相关文件索引

| 文件 | 说明 |
|---|---|
| `fetch_sources.sh` | 拉取全部源码（本目录，浅克隆，可重跑；lua 已固定 v5.2.3） |
| `zig-env.sh` | 交叉环境：导出 CC/CXX/AR/RANLIB 与 PATH |
| `zig-toolchain/` | zig 包装脚本 + meson 交叉文件（本目录，复制到`~/build/zig-toolchain/`，改 `yourname`） |
| `pack_mpv.sh` | 打包：闭包收集 / strip / patchelf / xkb 数据 / wrapper |
| `bin/ lib/ config/ mpv` | 部署包模板（本目录） |