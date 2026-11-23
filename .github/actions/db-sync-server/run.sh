#!/usr/bin/env bash
set -euo pipefail

source_dir="$GITHUB_WORKSPACE/logseq-server/deps/db-sync"
runtime_dir="$RUNNER_TEMP/db-sync-runtime"
started=$SECONDS

if [[ -s $runtime_dir/worker/dist/node-adapter.js ]]; then
  echo "Using cached db-sync runtime"
else
  echo "Building db-sync runtime"
  work_dir=$(mktemp -d "$RUNNER_TEMP/db-sync-build.XXXXXX")
  trap 'rm -rf "$work_dir"' EXIT

  installer=linux-install.sh
  if [[ $RUNNER_OS == macOS ]]; then
    installer=posix-install.sh
  fi
  (
    cd "$work_dir"
    curl -fsSL --retry 3 \
      "https://github.com/clojure/brew-install/releases/download/1.12.7.1681/$installer" \
      -o install.sh
    bash install.sh --prefix "$work_dir/clojure"
  )
  export PATH="$work_dir/clojure/bin:$PATH"

  cd "$source_dir"
  # The adapter builds with the server's own locked production dependencies.
  corepack pnpm install --ignore-workspace --prod --frozen-lockfile
  clojure -M:cljs release db-sync-node

  staging="$work_dir/runtime"
  mkdir -p "$staging/worker/dist"
  cp package.json start.sh "$staging/"
  cp worker/dist/node-adapter.js "$staging/worker/dist/"
  mv node_modules "$staging/"
  # Publish only a complete runtime for actions/cache to save at job completion.
  rm -rf "$runtime_dir"
  mv "$staging" "$runtime_dir"
fi

echo "db-sync runtime prepared in $((SECONDS - started))s"
mkdir -p "$source_dir/data"
cd "$runtime_dir"
DB_SYNC_DATA_DIR="$source_dir/data" nohup bash ./start.sh >"$source_dir/db-sync.log" 2>&1 &
echo $! > "$source_dir/db-sync.pid"
