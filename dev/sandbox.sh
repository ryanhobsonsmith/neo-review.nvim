#!/usr/bin/env bash
# Build/refresh a sandboxed Neovim that mirrors your REAL config (LazyVim) and
# adds the local neo-review.nvim working copy as a dev plugin.
#
#   ./dev/sandbox.sh            # create or refresh ~/.config/review from ~/.config/nvim
#   ./dev/sandbox.sh --reset    # nuke sandbox config + data and rebuild from scratch
#   NVIM_APPNAME=review nvim    # run it (alias: rnvim)
#
# Isolation: config lives in ~/.config/review (a git clone of your config repo;
# your real config is never written). Plugins/state/swap live under
# ~/.local/share/review and ~/.local/state/review — separate installs, pinned
# by the cloned lazy-lock.json, so sandbox experiments can't touch your daily
# editor either.

set -euo pipefail

APPNAME="${APPNAME:-review}"
SRC="${SRC:-$HOME/.config/nvim}"
DST="$HOME/.config/$APPNAME"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${1:-}" == "--reset" ]]; then
  echo "removing sandbox config + data for NVIM_APPNAME=$APPNAME"
  rm -rf "$DST" "$HOME/.local/share/$APPNAME" "$HOME/.local/state/$APPNAME" "$HOME/.cache/$APPNAME"
fi

if [[ ! -d "$SRC/.git" ]]; then
  echo "error: $SRC is not a git repo; copy it manually or adjust SRC" >&2
  exit 1
fi

if [[ -d "$DST/.git" ]]; then
  echo "refreshing $DST from $SRC"
  git -C "$DST" fetch -q origin
  git -C "$DST" reset -q --hard origin/HEAD
else
  if [[ -e "$DST" ]]; then
    # Leftover from the earlier minimal sandbox (or anything else non-git).
    echo "moving aside existing non-git $DST -> $DST.bak"
    rm -rf "$DST.bak"
    mv "$DST" "$DST.bak"
  fi
  echo "cloning $SRC -> $DST"
  git clone -q "$SRC" "$DST"
fi

# Inject neo-review.nvim as a LazyVim plugin spec (lua/plugins/*.lua is
# auto-imported). lazy = false: load at startup like a real install would after
# `cmd` lazy-loading fires — the plugin is dormant by design until a command runs.
mkdir -p "$DST/lua/plugins"
cat > "$DST/lua/plugins/neo-review-dev.lua" <<EOF
-- Injected by dev/sandbox.sh (gitignored in this clone). The plugin under
-- development, loaded from the working copy.
return {
  {
    dir = "$PLUGIN_DIR",
    name = "neo-review.nvim",
    lazy = false,
    opts = {},
  },
}
EOF

# Keep `git status` clean inside the clone without touching its tracked files.
grep -qxF "lua/plugins/neo-review-dev.lua" "$DST/.git/info/exclude" 2>/dev/null \
  || echo "lua/plugins/neo-review-dev.lua" >> "$DST/.git/info/exclude"

echo "done. run:  NVIM_APPNAME=$APPNAME nvim"
echo "first launch bootstraps lazy.nvim and installs plugins per your lazy-lock.json"
