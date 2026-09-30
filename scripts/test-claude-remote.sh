#!/bin/bash
# Sync source only; all validation commands execute on the SSH host.
set -euo pipefail
host="${1:?usage: bash scripts/test-claude-remote.sh HOST REMOTE_DIR [REMOTE_CLAUDE_LAUNCHER]}"
remote_dir="${2:?remote validation directory required}"
launcher="${3:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"
printf -v quoted_dir '%q' "$remote_dir"
printf -v quoted_launcher '%q' "$launcher"
ssh "$host" "mkdir -p $quoted_dir"
tar -C "$root" --exclude=.git -cf - . | ssh "$host" "tar -xf - -C $quoted_dir"
ssh "$host" "bash -s -- $quoted_dir $quoted_launcher" <<'REMOTE'
set -euo pipefail
cd "$1"
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$HOME/.local/share/nvim/mason/bin:$PATH"
node --check scripts/claude-rpc-fixture.mjs
bash -n scripts/test-claude-remote.sh
stylua --check --indent-type Spaces --indent-width 2 lua/coact/providers/claude*.lua lua/coact/rpc.lua lua/coact/config.lua lua/coact/patch_session.lua lua/coact/core.lua lua/coact/init.lua lua/coact/catalog.lua lua/coact/parser.lua lua/coact/slash.lua lua/coact/buffers.lua lua/coact/providers/pi_tree.lua scripts/claude-smoke.lua scripts/claude-provider-test.lua scripts/claude-history-smoke.lua scripts/claude-history-test.lua scripts/smoke.lua
nvim --headless -u NONE -c 'set rtp+=.' -l scripts/smoke.lua
nvim --headless -u NONE -c 'set rtp+=.' -l scripts/claude-provider-test.lua
history_root="$(mktemp -d)"
trap 'rm -rf "$history_root"' EXIT
for phase in 1 2 3; do
  COACT_HISTORY_ROOT="$history_root/fixture" COACT_HISTORY_PHASE="$phase" nvim --headless --listen "$history_root/f$phase.sock" -u NONE -c 'set rtp+=.' -l scripts/claude-history-test.lua
done
if [ -n "$2" ]; then
  COACT_CLAUDE_LIVE="$2" nvim --headless -u NONE -c 'set rtp+=.' -l scripts/claude-provider-test.lua
  for phase in 1 2 3; do
    COACT_CLAUDE_LIVE="$2" COACT_HISTORY_ROOT="$history_root/live" COACT_HISTORY_PHASE="$phase" nvim --headless --listen "$history_root/l$phase.sock" -u NONE -c 'set rtp+=.' -l scripts/claude-history-test.lua
  done
fi
REMOTE
