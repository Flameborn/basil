#!/bin/sh
# Builds the vendored libraries that are not plain SwiftPM sources. Run once after cloning, before
# opening the project in Xcode or running swift test: SwiftPM needs Vendor/libssh2's xcframework
# when it resolves packages. Running it again is quick (only what changed is rebuilt).
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"

echo "Building libssh2 and OpenSSL"
"$root/Vendor/libssh2/build.sh"
echo "Building LuaJIT"
"$root/Vendor/luajit/build.sh"
echo "Building 7zz"
"$root/Vendor/7zip/build.sh"
echo "Done"
