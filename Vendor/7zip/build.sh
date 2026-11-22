#!/bin/sh
# Builds the 7zz command-line tool from the unmodified sources in src/ into Vendor/build/7zip/7zz.
# make only rebuilds what changed, so running it again is quick. Used by the Xcode build of
# Basil (which copies and signs 7zz into the app) and by the BasilArchives tests.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/../build/7zip}"
mkdir -p "$out/obj"
out="$(cd "$out" && pwd)"

cd "$here/src/CPP/7zip/Bundles/Alone2"
# The upstream makefile treats every clang warning as an error (-Werror -Weverything); a newer
# clang adds warnings, so build with -Wall only. Objects go to $out/obj, not into the sources.
# Xcode's environment (SDKROOT, deployment target) must not leak into the C++ build.
env -u MACOSX_DEPLOYMENT_TARGET -u SDKROOT -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS \
    make -s -j"$(sysctl -n hw.ncpu)" -f ../../cmpl_mac_arm64.mak \
    O="$out/obj" \
    MY_ARCH="-arch arm64 -mmacosx-version-min=27.0" \
    CFLAGS_WARN_WALL="-Wall" CFLAGS_WARN="-Wno-poison-system-directories"
if ! cmp -s "$out/obj/7zz" "$out/7zz"; then
    cp -p "$out/obj/7zz" "$out/7zz.new"
    mv -f "$out/7zz.new" "$out/7zz"
fi
