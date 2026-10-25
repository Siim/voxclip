#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK=$1
TARGET=$2
JOBS=$3
PREFIX="$WORK/prefix"
export CC="$TARGET-clang" CXX="$TARGET-clang++" AR="$TARGET-ar"
export RANLIB="$TARGET-ranlib" STRIP="$TARGET-strip"
export CFLAGS="-O2 -g0 -ffile-prefix-map=$WORK=/build -fno-ident"
export CXXFLAGS="$CFLAGS -static-libstdc++"
export LDFLAGS="-static -Wl,--no-insert-timestamp"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH=
mkdir -p "$PREFIX/include/AMF" "$PREFIX/include/ffnvcodec" "$PREFIX/lib/pkgconfig"
cp -R "$AMF_SOURCE/amf/public/include/." "$PREFIX/include/AMF/"
test -f "$PREFIX/include/AMF/core/Version.h"
cp "$NV_SOURCE"/include/ffnvcodec/*.h "$PREFIX/include/ffnvcodec/"
sed "s|@@PREFIX@@|$PREFIX|g; s|@@LIBDIR@@|$PREFIX/lib|g; s|@@VERSION@@|13.0.19.0|g" \
    "$NV_SOURCE/ffnvcodec.pc.in" > "$PREFIX/lib/pkgconfig/ffnvcodec.pc"

cat > "$WORK/dav1d-cross.ini" <<EOF
[binaries]
c = '$TARGET-clang'
cpp = '$TARGET-clang++'
ar = '$TARGET-ar'
strip = '$TARGET-strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'windows'
cpu_family = '$CPU_FAMILY'
cpu = '$CPU_FAMILY'
endian = 'little'
[built-in options]
c_args = ['-O2', '-g0', '-ffile-prefix-map=$WORK=/build', '-fno-ident']
c_link_args = ['-static', '-Wl,--no-insert-timestamp']
EOF
python3 "$MESON_SOURCE/meson.py" setup "$WORK/dav1d" "$DAV1D_SOURCE" \
    --cross-file "$WORK/dav1d-cross.ini" --prefix "$PREFIX" --libdir lib \
    --buildtype release --default-library static --wrap-mode nodownload \
    -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_asm=true
ninja -C "$WORK/dav1d" -j"$JOBS"
python3 "$MESON_SOURCE/meson.py" install -C "$WORK/dav1d"

if [ "$TARGET" = x86_64-w64-mingw32 ]; then
    patch -p1 -d "$VPL_SOURCE" < "$ROOT/patches/libvpl-mingw-secure-crt.patch"
    cmake -S "$VPL_SOURCE" -B "$WORK/vpl" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=AMD64 \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_RC_COMPILER="$TARGET-windres" -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF \
        -DINSTALL_EXAMPLES=OFF -DBUILD_EXPERIMENTAL=OFF \
        -DFETCHCONTENT_FULLY_DISCONNECTED=ON -DFETCHCONTENT_UPDATES_DISCONNECTED=ON
    cmake --build "$WORK/vpl" --parallel "$JOBS"
    cmake --install "$WORK/vpl"
fi
