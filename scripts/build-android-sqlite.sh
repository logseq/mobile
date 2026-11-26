#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sqlite_revision=4ebc7fdcf459e8d88eb5b019c2949bda86565528
cache_root="$repo_root/_build/android-sqlite-host"
host_build="$cache_root/$sqlite_revision"

mkdir -p "$cache_root"
exec 9>>"$cache_root/.build-lock"
python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)'

if [[ ! -s $host_build/sqlite3.c || ! -s $host_build/sqlite3.h ]]; then
  staging=$(mktemp -d "$cache_root/.build.XXXXXX")
  trap 'rm -rf -- "$staging"' EXIT
  source_root="$staging/sqlite"
  git init --quiet "$source_root"
  git -C "$source_root" fetch --quiet --depth=1 --no-tags \
    https://github.com/sqlite/sqlite.git "$sqlite_revision" >&2
  git -C "$source_root" checkout --quiet --detach FETCH_HEAD >&2

  mkdir "$staging/build" "$staging/amalgamation"
  (
    cd "$staging/build"
    "$source_root/configure" --disable-shared --disable-static >&2
    make sqlite3.c sqlite3.h >&2
    mv sqlite3.c sqlite3.h "$staging/amalgamation/"
  )
  rm -rf -- "$host_build"
  mv "$staging/amalgamation" "$host_build"
fi

echo "$host_build"
