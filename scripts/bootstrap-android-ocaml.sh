#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ocaml_version=${LOGSEQ_ANDROID_OCAML_VERSION:-5.5.0}
android_abi=${LOGSEQ_ANDROID_ABI:-arm64-v8a}
api_level=${LOGSEQ_ANDROID_API_LEVEL:-21}
jobs=${LOGSEQ_BUILD_JOBS:-8}
android_home=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
toolchain_root="$repo_root/_build/android-toolchain"

die() {
  echo "error: $*" >&2
  exit 1
}

case "$android_abi" in
  arm64-v8a)
    target_arch=aarch64
    ;;
  x86_64)
    target_arch=x86_64
    ;;
  *)
    die "unsupported Android ABI: $android_abi"
    ;;
esac

target="${target_arch}-linux-android${api_level}"
host_prefix="$toolchain_root/host-$ocaml_version"
target_prefix="$toolchain_root/$target-$ocaml_version"

case "$(uname -s)" in
  Darwin)
    ndk_host=darwin-x86_64
    ;;
  Linux)
    ndk_host=linux-x86_64
    ;;
  *)
    die "unsupported build host: $(uname -s)"
    ;;
esac

if [[ -d ${ANDROID_NDK_HOME:-} ]]; then
  ndk_root=$ANDROID_NDK_HOME
else
  ndk_root=
  for candidate in "$android_home"/ndk/*; do
    [[ -x $candidate/toolchains/llvm/prebuilt/$ndk_host/bin/clang ]] && ndk_root=$candidate
  done
fi
[[ -n ${ndk_root:-} && -d $ndk_root ]] || die "Android NDK is not installed under $android_home/ndk"

ndk_bin="$ndk_root/toolchains/llvm/prebuilt/$ndk_host/bin"
[[ -x $ndk_bin/clang ]] || die "Android NDK clang was not found: $ndk_bin/clang"

mkdir -p "$toolchain_root"
exec 8>>"$toolchain_root/.build-lock"
python3 -c 'import fcntl; fcntl.flock(8, fcntl.LOCK_EX)'

checkout_ocaml_source() {
  source_dir=$(mktemp -d "${TMPDIR:-/tmp}/logseq-ocaml.XXXXXX")
  trap 'rm -rf -- "$source_dir"' EXIT
  git clone --depth 1 --branch "$ocaml_version" \
    https://github.com/ocaml/ocaml.git "$source_dir"
  cd "$source_dir"
}

build_host_compiler() {
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
}

build_target_compiler() {
  (
    checkout_ocaml_source
    PATH="$host_prefix/bin:$PATH" ./configure \
      --disable-function-sections \
      --without-zstd \
      --prefix="$target_prefix" \
      --target="$target" \
      TARGET_LIBDIR=/dummy/directory \
      CC="$ndk_bin/clang --target=$target" \
      AR="$ndk_bin/llvm-ar" \
      PARTIALLD="$ndk_bin/ld -r" \
      RANLIB="$ndk_bin/llvm-ranlib" \
      STRIP="$ndk_bin/llvm-strip"
    PATH="$host_prefix/bin:$PATH" make crossopt -j"$jobs"
    PATH="$host_prefix/bin:$PATH" make installcross
  )
}

if [[ ! -x $host_prefix/bin/ocamlopt.opt ]]; then
  build_host_compiler
fi

host_version=$("$host_prefix/bin/ocamlopt.opt" -version)
[[ $host_version == "$ocaml_version" ]] \
  || die "host compiler version is $host_version, expected $ocaml_version"

if [[ ! -x $target_prefix/bin/ocamlopt.opt ]]; then
  build_target_compiler
fi

target_version=$("$target_prefix/bin/ocamlopt.opt" -version)
[[ $target_version == "$ocaml_version" ]] \
  || die "target compiler version is $target_version, expected $ocaml_version"

echo "$target_prefix"
