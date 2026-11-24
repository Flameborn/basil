#!/bin/sh
# Builds LuaJIT from the unmodified sources in LuaJIT/ into build/LuaJIT.xcframework: the static
# library (arm64, macOS 27) with lua.h, lualib.h, lauxlib.h, luaconf.h, luajit.h and a module
# map for the CLuaJIT module. Package.swift wraps it.
#
# LuaJIT builds inside its source tree, so the sources are copied to build/luajit-src first
# (only changed files, so make rebuilds only what changed). Its version comes from .relver
# (the commit time, as LuaJIT's own release tarballs carry it), never from Basil's git.
# Run once after cloning (scripts/bootstrap.sh does), before SwiftPM resolves packages.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/build"
jobs="$(sysctl -n hw.ncpu)"
mkdir -p "$out"

unset SDKROOT CC CXX CFLAGS CXXFLAGS LDFLAGS CPATH LIBRARY_PATH 2>/dev/null || true
export MACOSX_DEPLOYMENT_TARGET=27.0

src="$out/luajit-src"
mkdir -p "$src"
rsync -a "$here/LuaJIT/" "$src/"
cp "$src/.relver" "$src/src/luajit_relver.txt"
make -s -C "$src/src" -j"$jobs" BUILDMODE=static libluajit.a >/dev/null

stage="$out/stage"
rm -rf "$stage"
# The headers go in a folder of their own: Xcode copies every xcframework's headers into one
# include folder, and LibSSH2.xcframework has its module map at the top already.
mkdir -p "$stage/include/CLuaJIT"
cp "$src/src/libluajit.a" "$stage/libBasilLuaJIT.a"
for h in lua.h lualib.h lauxlib.h luaconf.h luajit.h; do cp "$src/src/$h" "$stage/include/CLuaJIT/"; done
cat > "$stage/include/CLuaJIT/module.modulemap" <<'MAP'
module CLuaJIT {
    header "lua.h"
    header "lualib.h"
    header "lauxlib.h"
    header "luajit.h"
    export *
}
MAP

stamp="$( (cd "$stage" && find . -type f | sort && cat libBasilLuaJIT.a include/CLuaJIT/*) | shasum -a 256 | cut -d' ' -f1)"
if [ "$(cat "$out/.xcframework-stamp" 2>/dev/null || true)" != "$stamp" ] || [ ! -d "$out/LuaJIT.xcframework" ]; then
    rm -rf "$out/new"
    xcodebuild -create-xcframework -library "$stage/libBasilLuaJIT.a" -headers "$stage/include" \
        -output "$out/new/LuaJIT.xcframework" >/dev/null
    rm -rf "$out/LuaJIT.xcframework"
    mv "$out/new/LuaJIT.xcframework" "$out/LuaJIT.xcframework"
    rmdir "$out/new"
    echo "$stamp" > "$out/.xcframework-stamp"
fi
