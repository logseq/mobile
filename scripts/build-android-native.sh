#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ocaml_version=${LOGSEQ_ANDROID_OCAML_VERSION:-5.5.0}
android_abi=${LOGSEQ_ANDROID_ABI:-arm64-v8a}
api_level=${LOGSEQ_ANDROID_API_LEVEL:-21}
android_home=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}

die() {
  echo "error: $*" >&2
  exit 1
}

case "$android_abi" in
  arm64-v8a)
    target_arch=aarch64
    dune_context=android_arm64
    ;;
  x86_64)
    target_arch=x86_64
    dune_context=android_x86_64
    ;;
  *) die "unsupported Android ABI: $android_abi" ;;
esac

target="${target_arch}-linux-android${api_level}"
target_prefix="$repo_root/_build/android-toolchain/$target-$ocaml_version"
build_dir="$repo_root/_build/android-core/$android_abi"
jni_dir="$repo_root/android/app/src/main/jniLibs/$android_abi"
library="$build_dir/liblogseq_core.so"

"$repo_root/scripts/bootstrap-android-ocaml.sh" >/dev/null

case "$(uname -s)" in
  Darwin) ndk_host=darwin-x86_64 ;;
  Linux) ndk_host=linux-x86_64 ;;
  *) die "unsupported build host: $(uname -s)" ;;
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
ocaml_lib="$target_prefix/lib/ocaml"
sqlite_source_dir=$("$repo_root/scripts/build-android-sqlite.sh")

mkdir -p "$build_dir" "$jni_dir"
cd "$build_dir"

"$ndk_bin/clang" \
  --target="$target" \
  -fPIC \
  -O2 \
  -D_FILE_OFFSET_BITS=64 \
  -DSQLITE_ENABLE_FTS5 \
  -DSQLITE_OMIT_LOAD_EXTENSION \
  -DSQLITE_THREADSAFE=1 \
  -c "$sqlite_source_dir/sqlite3.c" \
  -o sqlite3.o
"$ndk_bin/llvm-nm" sqlite3.o | grep "sqlite3Fts5Init" >/dev/null
"$ndk_bin/llvm-ar" rcs libsqlite3.a sqlite3.o

# The NDK ships no libffi; ctypes-foreign needs real headers for its stub
# build and -lffi must resolve at the final .so link.
# Use NDK archive tools: macOS tools cannot archive Android ELF objects.
ffi_prefix=$(AR="$ndk_bin/llvm-ar" \
  NM="$ndk_bin/llvm-nm" \
  RANLIB="$ndk_bin/llvm-ranlib" \
  "$repo_root/scripts/build-mobile-libffi.sh" \
  "$target_arch-linux-android" \
  "$repo_root/_build/android-toolchain/libffi-$target" \
  "$ndk_bin/clang --target=$target" \
  "$ndk_bin/clang++ --target=$target")

mkdir -p "$build_dir/pkgconfig"
cat > "$build_dir/pkgconfig/sqlite3.pc" <<EOF
prefix=$build_dir
libdir=\${prefix}
includedir=$sqlite_source_dir

Name: SQLite
Description: Self-contained SQLite amalgamation built for $target
Version: 3
Libs: -L\${libdir} -lsqlite3
Cflags: -I\${includedir}
EOF

runtime_object=$(C_INCLUDE_PATH="$sqlite_source_dir${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}" \
  PKG_CONFIG_PATH="$build_dir/pkgconfig:$ffi_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
  SQLITE3_DISABLE_LOADABLE_EXTENSIONS=1 \
  DATASCRIPT_SQLITE_LIB_DIR="$build_dir" \
  DUNE_PROFILE=android \
  LOGSEQ_SQLITE_LIB_DIR="$build_dir" \
  LOGSEQ_SQLITE_LINK_FILE="$build_dir/libsqlite3.a" \
  "$repo_root/scripts/build-mobile-ocaml.sh" "$target_prefix" "$dune_context")

for source in logseq_crypto_android.c logseq_https_android.c; do
  "$ndk_bin/clang" \
    --target="$target" \
    -fPIC \
    -I "$ocaml_lib" \
    -c "$repo_root/shared/native/$source" \
    -o "${source%.c}.o"
done

"$ndk_bin/clang" \
  --target="$target" \
  -shared \
  -Wl,-z,max-page-size=16384 \
  -Wl,-z,common-page-size=16384 \
  -Wl,--no-undefined \
  -Wl,-soname,liblogseq_core.so \
  -o "$library" \
  "$runtime_object" \
  logseq_crypto_android.o \
  logseq_https_android.o \
  "$ffi_prefix/lib/libffi.a" \
  -lm \
  -ldl \
  -llog \
  -pthread

"$ndk_bin/llvm-strip" --strip-unneeded "$library"
cp "$library" "$jni_dir/liblogseq_core.so"

"$ndk_bin/llvm-readelf" -h "$library" \
  | grep "Machine:.*AArch64\\|Machine:.*Advanced Micro Devices X86-64" \
  >/dev/null
"$ndk_bin/llvm-readelf" -s "$library" | grep "logseq_call" >/dev/null

echo "$jni_dir/liblogseq_core.so"
