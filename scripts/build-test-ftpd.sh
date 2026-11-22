#!/bin/sh
# Builds the FTP server the BasilRemote tests run: pure-ftpd from Homebrew's source tarball
# (Homebrew checks its checksum), with Homebrew's libsodium and OpenSSL. Homebrew's own bottle
# cannot be used: it only logs users in when started as root, and the tests run as the user.
# Two builds go into build/test-ftpd: pure-ftpd (plain FTP and explicit TLS) and
# pure-ftpd-implicit (implicit TLS), plus pure-pw for the test account. Only tests use them;
# the app does not. The tests run this script when the binaries are missing.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/test-ftpd"
if [ -x "$out/pure-ftpd" ] && [ -x "$out/pure-ftpd-implicit" ] && [ -x "$out/pure-pw" ]; then
    exit 0
fi
command -v brew >/dev/null || { echo "Homebrew is needed to build the test FTP server" >&2; exit 1; }
brew list libsodium >/dev/null 2>&1 || brew install libsodium >/dev/null
brew list openssl@3 >/dev/null 2>&1 || brew install openssl@3 >/dev/null
brew fetch --build-from-source pure-ftpd >/dev/null
tarball="$(brew --cache --build-from-source pure-ftpd)"
sodium="$(brew --prefix libsodium)"
ssl="$(brew --prefix openssl@3)"
unset MACOSX_DEPLOYMENT_TARGET SDKROOT CC CFLAGS LDFLAGS CPATH LIBRARY_PATH 2>/dev/null || true

work="$out/src"
rm -rf "$work"
mkdir -p "$work"
build() { # $1: binary name, then configure options
    name="$1"
    shift
    rm -rf "$work/tree"
    mkdir -p "$work/tree"
    tar xzf "$tarball" -C "$work/tree" --strip-components 1
    (cd "$work/tree" &&
        ./configure --with-nonroot --with-tls --with-puredb --without-privsep --without-capabilities \
            --with-ftpwho=no "$@" \
            CFLAGS="-I$sodium/include -I$ssl/include" LDFLAGS="-L$sodium/lib -L$ssl/lib" >/dev/null &&
        make -j"$(sysctl -n hw.ncpu)" >/dev/null)
    cp "$work/tree/src/pure-ftpd" "$out/$name"
}
build pure-ftpd
cp "$work/tree/src/pure-pw" "$out/pure-pw"
build pure-ftpd-implicit --with-implicittls
rm -rf "$work"
