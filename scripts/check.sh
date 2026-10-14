#!/bin/bash
# Local validation: formatting, syntax, and headless Neovim tests.
# Set COACT_CLAUDE_LIVE=/path/to/launcher to also run the live Claude tests.
set -euo pipefail
cd "$(dirname "$0")/.."

run() {
  printf '==> %s\n' "$*"
  "$@"
}

nvim_test() {
  run nvim --headless -u NONE -c 'set rtp+=.' -l "$@"
}

run bash -n scripts/check.sh
run node --check scripts/claude-rpc-fixture.mjs
run node --check extensions/pi/coact-nvim.ts
history_root="$(mktemp -d)"
trap 'rm -rf "$history_root"' EXIT
pi_extension="$history_root/pi-extension.mjs"
nvim --headless -u NONE -c 'set rtp+=.' \
  -c "lua local f = assert(io.open([[$pi_extension]], 'w')); f:write(require('coact.providers.pi_edit_bridge')._extension_source()); f:close()" \
  -c qa
run node --check "$pi_extension"

run stylua --check --indent-type Spaces --indent-width 2 \
  lua/coact/providers/claude*.lua lua/coact/rpc.lua lua/coact/config.lua lua/coact/patch_session.lua \
  lua/coact/review/*.lua lua/coact/dynamic_tools.lua lua/coact/core.lua lua/coact/init.lua lua/coact/catalog.lua \
  lua/coact/parser.lua lua/coact/slash.lua lua/coact/buffers.lua lua/coact/providers/pi_tree.lua \
  lua/coact/runtime.lua lua/coact/pickers.lua lua/coact/integrations.lua lua/coact/health.lua \
  scripts/review-test.lua scripts/smoke.lua scripts/adapter-picker-test.lua scripts/claude-smoke.lua \
  scripts/claude-provider-test.lua scripts/claude-history-smoke.lua scripts/claude-history-test.lua \
  scripts/integrations-test.lua
run git diff --check

nvim_test scripts/review-test.lua
nvim_test scripts/smoke.lua
nvim_test scripts/adapter-picker-test.lua
nvim_test scripts/integrations-test.lua

# Fixture runs ignore COACT_CLAUDE_LIVE; live runs follow when it is set.
live="${COACT_CLAUDE_LIVE:-}"
COACT_CLAUDE_LIVE= nvim_test scripts/claude-provider-test.lua
for phase in 1 2 3; do
  COACT_CLAUDE_LIVE= COACT_HISTORY_ROOT="$history_root/fixture" COACT_HISTORY_PHASE="$phase" \
    run nvim --headless --listen "$history_root/f$phase.sock" -u NONE -c 'set rtp+=.' -l scripts/claude-history-test.lua
done
if [ -n "$live" ]; then
  COACT_CLAUDE_LIVE="$live" nvim_test scripts/claude-provider-test.lua
  for phase in 1 2 3; do
    COACT_CLAUDE_LIVE="$live" COACT_HISTORY_ROOT="$history_root/live" COACT_HISTORY_PHASE="$phase" \
      run nvim --headless --listen "$history_root/l$phase.sock" -u NONE -c 'set rtp+=.' -l scripts/claude-history-test.lua
  done
fi
printf '\nall checks passed\n'
