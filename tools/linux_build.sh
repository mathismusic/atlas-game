#!/bin/zsh
#
# Compile the server for Linux, from a Mac, without Docker.
#
#   zsh tools/linux_build.sh
#
# There is no way to *run* the result here, but there is every way to find out
# that it does not build — and the ways it fails to build are not obvious ones.
# Four real bugs turned up the first time this was run, all of them invisible on
# a Mac: `Darwin.close` names a module that does not exist off Apple platforms,
# `sa_family` is a byte here and a short there, `sa_len` is a BSD field glibc
# has never had, and `usleep` needs a C library import that Foundation does not
# imply.  None of them would have shown up until a deploy failed.
#
# The static SDK is musl, not glibc, which is why the platform conditionals in
# the sources test for three C libraries rather than two: a `#if canImport(Glibc)
# / #else` pair quietly selects Darwin under musl and fails to compile for
# exactly the platform being deployed to.
set -eu
cd "$(dirname "$0")/.."

SDK_VERSION=6.3.2
SDK_NAME="swift-${SDK_VERSION}-RELEASE_static-linux-0.1.0"
SDK_URL="https://download.swift.org/swift-${SDK_VERSION}-release/static-sdk/swift-${SDK_VERSION}-RELEASE/${SDK_NAME}.artifactbundle.tar.gz"
SDK_SUM=3fd798bef6f4408f1ea5a6f94ce4d4052830c4326ab85ebc04f983f01b3da407

# Apple's Swift and swift.org's Swift report the same version number and emit
# incompatible module formats, so the SDK's Foundation is unreadable to the
# compiler that ships with the command-line tools.  The toolchain from
# swift.org is what the SDK expects; it installs into the home directory, needs
# no sudo, and is one `rm -rf` to be rid of.
TOOLCHAIN=~/Library/Developer/Toolchains/swift-${SDK_VERSION}-RELEASE.xctoolchain
SWIFT=$TOOLCHAIN/usr/bin/swift

if [[ ! -x $SWIFT ]]; then
  echo "The swift.org $SDK_VERSION toolchain is not installed.  To get it:"
  echo "  curl -Lo /tmp/swift.pkg https://download.swift.org/swift-${SDK_VERSION}-release/xcode/swift-${SDK_VERSION}-RELEASE/swift-${SDK_VERSION}-RELEASE-osx.pkg"
  echo "  installer -pkg /tmp/swift.pkg -target CurrentUserHomeDirectory"
  exit 1
fi

if ! $SWIFT sdk list 2>/dev/null | grep -q "$SDK_NAME"; then
  echo "=== installing the static Linux SDK (about 300 MB) ==="
  $SWIFT sdk install "$SDK_URL" --checksum "$SDK_SUM"
fi

# A scratch path of its own: sharing .build with the Mac build makes the two
# fight over the same `release` symlink, and the test sweep runs from it.
#
# The test runner is built too, and for a reason that cost a deploy to learn:
# the Dockerfile builds only `--product atlas`, so the test sources were the one
# part of this repository that nothing had ever compiled for Linux.  They did
# not compile — `ServerTests` opens a raw socket, and off Darwin `import
# Foundation` no longer hands you the C library that declares one.  Musl cannot
# see the *type* differences glibc has, but it sees a missing import perfectly
# well, and it sees it here in two minutes instead of ten in CI.
for arch in x86_64 aarch64; do
  echo "=== $arch ==="
  for product in atlas atlastests; do
    $SWIFT build -c release --product $product \
      --swift-sdk "${arch}-swift-linux-musl" \
      --scratch-path /tmp/atlas-linux
  done
  file "/tmp/atlas-linux/${arch}-swift-linux-musl/release/atlas"
done
