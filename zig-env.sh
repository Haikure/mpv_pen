# 交叉编译环境：导出 zig 包装工具链到 PATH
# 用法: source ~/build/zig-env.sh
# 说明: 需先把本目录下 zig-toolchain/ 复制到 $HOME/build/zig-toolchain/（或改下方 TOOLCHAIN）

#export PREFIX=/opt/ffmpeg
export TOOLCHAIN=$HOME/build/zig-toolchain

export PATH="$TOOLCHAIN:$PATH"

export CC=aarch64-linux-gnu-gcc
export CXX=aarch64-linux-gnu-g++
export AR=aarch64-linux-gnu-ar
export RANLIB=aarch64-linux-gnu-ranlib

#export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
#export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

#export CFLAGS="-O2 -fPIC -I$PREFIX/include"
#export CXXFLAGS="-O2 -fPIC -I$PREFIX/include"
#export CPPFLAGS="-I$PREFIX/include"
#export LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"
