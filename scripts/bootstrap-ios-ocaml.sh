#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 simulator|device"
platform=$1
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
toolchain_root=${LOGSEQ_APPLE_TOOLCHAIN_ROOT:-$repo_root/_build/apple-toolchains}
ocaml_version=${LOGSEQ_IOS_OCAML_VERSION:-5.5.0}
deployment_target=${LOGSEQ_IOS_DEPLOYMENT_TARGET:-17.0}
jobs=${LOGSEQ_IOS_BUILD_JOBS:-8}

case "$platform" in
  simulator)
    sdk=iphonesimulator
    swift_target="arm64-apple-ios${deployment_target}-simulator"
    configure_target=aarch64-apple-darwin.simulator
    ;;
  device)
    sdk=iphoneos
    swift_target="arm64-apple-ios${deployment_target}"
    configure_target=aarch64-apple-darwin
    ;;
  *)
    die "unsupported iOS platform: $platform"
    ;;
esac

ios_root="$toolchain_root/ios"
host_prefix="$ios_root/host-$ocaml_version"
target_prefix="$ios_root/$swift_target-$ocaml_version"
host_stamp="$host_prefix/.logseq-toolchain-complete"
target_stamp="$target_prefix/.logseq-toolchain-complete"

[[ $(uname -s) == Darwin ]] || die "the iOS toolchain requires macOS"
command -v xcrun >/dev/null 2>&1 || die "xcrun was not found"

sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
clang=$(xcrun --sdk "$sdk" --find clang)
ar=$(xcrun --sdk "$sdk" --find ar)
ld=$(xcrun --sdk "$sdk" --find ld)
ranlib=$(xcrun --sdk "$sdk" --find ranlib)
strip=$(xcrun --sdk "$sdk" --find strip)
mkdir -p "$ios_root"
exec 8>>"$ios_root/.build-lock"
python3 -c 'import fcntl; fcntl.flock(8, fcntl.LOCK_EX)'

checkout_ocaml_source() {
  source_dir=$(mktemp -d "${TMPDIR:-/tmp}/logseq-ocaml.XXXXXX")
  trap 'rm -rf -- "$source_dir"' EXIT
  git clone --depth 1 --branch "$ocaml_version" \
    https://github.com/ocaml/ocaml.git "$source_dir"
  cd "$source_dir"
}

if [[ ! -f $host_stamp || ! -x $host_prefix/bin/ocamlopt.opt ]]; then
  (
    checkout_ocaml_source
    ./configure \
      --disable-ocamldoc \
      --disable-ocamltest \
      --disable-stdlib-manpages \
      --without-zstd \
      --prefix="$host_prefix"
    make -j"$jobs"
    make install
  )
fi

host_version=$("$host_prefix/bin/ocamlopt.opt" -version)
[[ $host_version == "$ocaml_version" ]] \
  || die "host compiler version is $host_version, expected $ocaml_version"
[[ -f $host_stamp ]] || touch "$host_stamp"

if [[ ! -f $target_stamp || ! -x $target_prefix/bin/ocamlopt.opt ]]; then
  (
    checkout_ocaml_source
    PATH="$host_prefix/bin:$PATH" \
      ac_cv_func___secure_getenv=no \
      ac_cv_func_accept4=no \
      ac_cv_func_dup3=no \
      ac_cv_func_execvpe=no \
      ac_cv_func_getentropy=no \
      ac_cv_func_pipe2=no \
      ac_cv_func_prctl=no \
      ac_cv_func_secure_getenv=no \
      ac_cv_func_system=no \
      ./configure \
      --disable-dependency-generation \
      --disable-function-sections \
      --disable-shared \
      --disable-warn-error \
      --prefix="$target_prefix" \
      --target="$configure_target" \
      --without-zstd \
      TARGET_LIBDIR=/dummy/directory \
      CC="$clang -target $swift_target -isysroot $sdk_path" \
      AR="$ar" \
      DIRECT_LD="$ld" \
      LD="$ld" \
      PARTIALLD="$ld -r" \
      RANLIB="$ranlib" \
      STRIP="$strip"
    PATH="$host_prefix/bin:$PATH" make crossopt -j"$jobs"
    PATH="$host_prefix/bin:$PATH" make installcross
  )
fi

target_version=$("$target_prefix/bin/ocamlopt.opt" -version)
[[ $target_version == "$ocaml_version" ]] \
  || die "target compiler version is $target_version, expected $ocaml_version"
[[ -f $target_stamp ]] || touch "$target_stamp"

echo "$target_prefix"
