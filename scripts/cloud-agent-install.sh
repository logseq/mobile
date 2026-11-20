#!/usr/bin/env bash
# Cloud Agent install for logseq/mobile (Linux OCaml core).
# Idempotent: safe to re-run. Does not start servers or run tests.
set -euo pipefail

[ ! -d '/agent/repos/mobile' ] || cd '/agent/repos/mobile' || exit $?
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

export DEBIAN_FRONTEND=noninteractive
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0="url.https://github.com/.insteadOf"
export GIT_CONFIG_VALUE_0="git@github.com:"
export GIT_CONFIG_KEY_1="url.https://github.com/.insteadOf"
export GIT_CONFIG_VALUE_1="ssh://git@github.com/"
export GIT_CONFIG_KEY_2="url.https://github.com/.insteadOf"
export GIT_CONFIG_VALUE_2="git+ssh://git@github.com/"

SDL3_PREFIX="${LOGSEQ_SDL3_PREFIX:-/opt/sdl3}"
export PKG_CONFIG_PATH="${SDL3_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="${SDL3_PREFIX}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBRARY_PATH="${SDL3_PREFIX}/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
export C_INCLUDE_PATH="${SDL3_PREFIX}/include${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"

sudo apt-get update -qq
sudo apt-get install -y -qq \
  build-essential cmake ninja-build pkg-config \
  opam bubblewrap m4 \
  libsqlite3-dev libffi-dev \
  libsdl2-dev libsdl2-ttf-dev \
  libpango1.0-dev libcairo2-dev \
  libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxfixes-dev \
  libxi-dev libxss-dev libxtst-dev libwayland-dev libxkbcommon-dev \
  libdbus-1-dev libibus-1.0-dev libudev-dev \
  libasound2-dev libpulse-dev libdrm-dev libgbm-dev \
  libegl1-mesa-dev libgles2-mesa-dev

# Persist toolchain env for subsequent login shells / agent commands.
PROFILE_SNIPPET="$HOME/.profile"
MARKER='# logseq-mobile-cloud-agent'
if ! grep -qF "$MARKER" "$PROFILE_SNIPPET" 2>/dev/null; then
  cat >> "$PROFILE_SNIPPET" <<EOF

$MARKER
export PKG_CONFIG_PATH="${SDL3_PREFIX}/lib/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="${SDL3_PREFIX}/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export LIBRARY_PATH="${SDL3_PREFIX}/lib\${LIBRARY_PATH:+:\$LIBRARY_PATH}"
export C_INCLUDE_PATH="${SDL3_PREFIX}/include\${C_INCLUDE_PATH:+:\$C_INCLUDE_PATH}"
if command -v opam >/dev/null 2>&1; then
  eval "\$(opam env --switch=5.5.0 --set-switch 2>/dev/null)" || true
fi
EOF
fi

# SDL3 is not packaged on Ubuntu 24.04; build the pinned runtime once.
if ! PKG_CONFIG_PATH="${SDL3_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
     pkg-config --exists sdl3; then
  sudo mkdir -p "$SDL3_PREFIX"
  sudo chown "$(whoami)" "$SDL3_PREFIX"
  TMP_SDL=$(mktemp -d)
  trap 'rm -rf "$TMP_SDL"' EXIT
  curl -fsSL \
    https://raw.githubusercontent.com/logseq/ocaml-sdl3/a9919c19bb4a0ba4857142f007ad93dd2563e799/tooling/install_sdl3.py \
    -o "$TMP_SDL/install_sdl3.py"
  python3 "$TMP_SDL/install_sdl3.py" "$SDL3_PREFIX"
  trap - EXIT
  rm -rf "$TMP_SDL"
fi
sudo ldconfig || true

# Opam switch (global ~/.opam — survives across checkouts).
if [ ! -d "${OPAMROOT:-$HOME/.opam}" ]; then
  opam init --disable-sandboxing -a --bare
fi
if ! opam switch list --short 2>/dev/null | grep -qx '5.5.0'; then
  opam switch create 5.5.0
fi
eval "$(opam env --switch=5.5.0 --set-switch)"

git config --global url."https://github.com/".insteadOf "git@github.com:" || true
git config --global url."https://github.com/".insteadOf "ssh://git@github.com/" || true
git config --global url."https://github.com/".insteadOf "git+ssh://git@github.com/" || true

opam pin add -n -y melange-edn-core git+https://github.com/logseq/melange-edn.git#main
opam pin add -n -y melange-edn-native git+https://github.com/logseq/melange-edn.git#main
opam pin add -n -y melange-transit-core git+https://github.com/logseq/melange-transit.git#main
opam pin add -n -y melange-transit-native git+https://github.com/logseq/melange-transit.git#main

# Fresh switch: install deps then drop lockfile-vendored packages (duniverse owns them).
# Re-runs skip the heavy deps pass when melange + opam-monorepo are already present.
if ! opam list --installed --short | grep -qx 'opam-monorepo'; then
  opam install . --deps-only --yes --with-test --assume-depexts
  if [ -f logseq.opam.locked ]; then
    comm -12 \
      <(grep -oE '"[a-zA-Z0-9_.-]+" \{= "[^"]*" & \?vendor\}' logseq.opam.locked | cut -d'"' -f2 | sort) \
      <(opam list --installed --short | sort) \
      | xargs -r opam remove -y || true
  fi
  opam install -y melange.7.0.1-55
  opam install -y opam-monorepo.0.3.6
else
  opam install -y melange.7.0.1-55 opam-monorepo.0.3.6
fi

if [ ! -d duniverse ] || [ ! -d duniverse/lui ]; then
  for attempt in 1 2 3; do
    if opam exec -- opam-monorepo pull; then
      break
    fi
    [ "$attempt" -lt 3 ] || exit 1
    sleep 10
  done
fi

# Pin-depends that opam-monorepo does not vendor (logseq git pins).
if [ -f logseq.opam ]; then
  for pin in $(grep -oE 'logseq/[A-Za-z0-9_-]+\.git#[A-Za-z0-9._/-]+' logseq.opam | sort -u); do
    url="${pin%%#*}"
    sha="${pin##*#}"
    name="$(basename "$url" .git)"
    if [ -d "duniverse/$name" ]; then
      # Keep pin SHA current when logseq.opam changes.
      if [ -d "duniverse/$name/.git" ]; then
        current="$(git -C "duniverse/$name" rev-parse HEAD 2>/dev/null || true)"
        if [ "$current" != "$sha" ] && [ "${#sha}" -ge 7 ]; then
          git -C "duniverse/$name" fetch --quiet "https://github.com/$url" "$sha" || true
          git -C "duniverse/$name" checkout --quiet "$sha" 2>/dev/null \
            || git -C "duniverse/$name" checkout --quiet FETCH_HEAD || true
        fi
      fi
      continue
    fi
    git clone --quiet "https://github.com/$url" "duniverse/$name"
    if ! git -C "duniverse/$name" checkout --quiet "$sha"; then
      git -C "duniverse/$name" fetch --quiet "https://github.com/$url" "$sha"
      git -C "duniverse/$name" checkout --quiet FETCH_HEAD
    fi
  done
fi

mkdir -p "$HOME/.config/dune"
printf '(lang dune 3.0)\n(cache enabled)\n' > "$HOME/.config/dune/config"

# Smoke: toolchain present (full runtest is for agents, not install).
ocaml -version
dune --version
test -d duniverse/lui
pkg-config --exists sdl3
echo "cloud-agent-install: ok"
