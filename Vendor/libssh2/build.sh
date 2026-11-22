#!/bin/sh
# Builds libssh2 with OpenSSL from the unmodified sources in libssh2/ and openssl/ into
# build/LibSSH2.xcframework: one static library (libssh2, libssl and libcrypto, arm64, macOS 27)
# with libssh2's headers and a module map for the CLibSSH2 module. Package.swift wraps it.
# libssl is for the FTPS client, through the CBasilTLS target (TLS/), which also needs the
# OpenSSL headers this script installs into build/openssl/include.
#
# The xcframework has to exist before SwiftPM or Xcode resolve the packages, so run this once
# after cloning (scripts/bootstrap.sh does). Later runs only rebuild what changed and replace the
# xcframework only when the library or headers changed.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/build"
jobs="$(sysctl -n hw.ncpu)"
mkdir -p "$out"

# Xcode's environment (SDKROOT, deployment target, compiler flags) must not leak into the build.
unset MACOSX_DEPLOYMENT_TARGET SDKROOT CC CXX CFLAGS CXXFLAGS LDFLAGS CPATH LIBRARY_PATH 2>/dev/null || true
minos="-mmacosx-version-min=27.0"

# OpenSSL: libcrypto (libssh2) and libssl (FTPS). Configure runs again only when these options change.
options="darwin64-arm64-cc no-shared no-tests no-apps no-docs no-module no-dso no-engine no-ui-console $minos"
ossl_obj="$out/openssl-obj"
ossl="$out/openssl"
mkdir -p "$ossl_obj"
if [ "$(cat "$ossl_obj/.options" 2>/dev/null || true)" != "$options" ]; then
    rm -rf "$ossl_obj" "$ossl"
    mkdir -p "$ossl_obj"
    (cd "$ossl_obj" && perl "$here/openssl/Configure" $options --prefix="$ossl" --libdir=lib >/dev/null)
    echo "$options" > "$ossl_obj/.options"
fi
make -s -C "$ossl_obj" -j"$jobs" build_libs >/dev/null
# install_dev prints its install variables on stderr.
make -s -C "$ossl_obj" install_dev >/dev/null 2>&1 || make -s -C "$ossl_obj" install_dev >/dev/null

# libssh2 with the OpenSSL backend and zlib compression (zlib from the SDK).
ssh_obj="$out/libssh2-obj"
cmake -S "$here/libssh2" -B "$ssh_obj" -G "Unix Makefiles" -Wno-deprecated \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
    -DCRYPTO_BACKEND=OpenSSL \
    -DOPENSSL_ROOT_DIR="$ossl" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_ZLIB_COMPRESSION=ON \
    -DLIBSSH2_NO_DEPRECATED=ON >/dev/null
cmake --build "$ssh_obj" -j "$jobs" >/dev/null

# One static library and the headers, then the xcframework.
stage="$out/stage"
rm -rf "$stage"
mkdir -p "$stage/include"
ZERO_AR_DATE=1 libtool -static -no_warning_for_no_symbols -o "$stage/libBasilSSH2.a" \
    "$ssh_obj/src/libssh2.a" "$ossl/lib/libssl.a" "$ossl/lib/libcrypto.a"
cp "$here/libssh2/include/libssh2.h" "$here/libssh2/include/libssh2_sftp.h" \
   "$here/libssh2/include/libssh2_publickey.h" "$stage/include/"
cat > "$stage/include/module.modulemap" <<'EOF'
module CLibSSH2 {
    header "libssh2.h"
    header "libssh2_sftp.h"
    header "libssh2_publickey.h"
    link "z"
    export *
}
EOF

stamp="$(cat "$stage/libBasilSSH2.a" "$stage/include/"* | shasum -a 256 | cut -d' ' -f1)"
if [ "$(cat "$out/.xcframework-stamp" 2>/dev/null || true)" != "$stamp" ] || [ ! -d "$out/LibSSH2.xcframework" ]; then
    rm -rf "$out/new"
    xcodebuild -create-xcframework -library "$stage/libBasilSSH2.a" -headers "$stage/include" \
        -output "$out/new/LibSSH2.xcframework" >/dev/null
    rm -rf "$out/LibSSH2.xcframework"
    mv "$out/new/LibSSH2.xcframework" "$out/LibSSH2.xcframework"
    rmdir "$out/new"
    echo "$stamp" > "$out/.xcframework-stamp"
fi
