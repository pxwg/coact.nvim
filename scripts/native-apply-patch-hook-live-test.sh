#!/bin/sh
set -eu

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
nvim_bin="${NVIM_BIN:-nvim}"
tmpdir="${TMPDIR:-/tmp}"
tmpdir="${tmpdir%/}"
timeout_sec="${CODEX_NVIM_APPLY_PATCH_TIMEOUT:-30}"

socket="$tmpdir/codex-nvim-apply-patch-live-test.$$.sock"
log="$tmpdir/codex-nvim-apply-patch-live-test.$$.log"
output="$tmpdir/codex-nvim-apply-patch-live-test.$$.out"
hook_stderr="$tmpdir/codex-nvim-apply-patch-live-test.$$.err"
hook_pid=""
nvim_pid=""

dump_nvim_state() {
  if [ -z "$nvim_pid" ] || ! kill -0 "$nvim_pid" 2>/dev/null; then
    return 0
  fi
  state_expr='luaeval("(function() local out = { mode = vim.api.nvim_get_mode(), current = vim.api.nvim_buf_get_name(0), bufs = {} }; for _, b in ipairs(vim.api.nvim_list_bufs()) do table.insert(out.bufs, { name = vim.api.nvim_buf_get_name(b), loaded = vim.api.nvim_buf_is_loaded(b), lines = vim.api.nvim_buf_get_lines(b, 0, math.min(12, vim.api.nvim_buf_line_count(b)), false) }) end; return vim.json.encode(out) end)()")'
  printf '%s\n' '--- nvim state ---' >&2
  "$nvim_bin" --server "$socket" --remote-expr "$state_expr" >&2 2>/dev/null || true
  printf '\n' >&2
}

die() {
  printf 'native apply_patch hook live test failed: %s\n' "$*" >&2
  dump_nvim_state
  if [ -s "$hook_stderr" ]; then
    printf '%s\n' '--- hook stderr ---' >&2
    cat "$hook_stderr" >&2
  fi
  if [ -s "$log" ]; then
    printf '%s\n' '--- hook debug log ---' >&2
    cat "$log" >&2
  fi
  if [ -s "$output" ]; then
    printf '%s\n' '--- hook output ---' >&2
    cat "$output" >&2
  fi
  exit 1
}

cleanup() {
  if [ -n "$hook_pid" ] && kill -0 "$hook_pid" 2>/dev/null; then
    kill "$hook_pid" 2>/dev/null || true
  fi
  if [ -n "$nvim_pid" ] && kill -0 "$nvim_pid" 2>/dev/null; then
    "$nvim_bin" --server "$socket" --remote-send '<Cmd>qa!<CR>' >/dev/null 2>&1 || true
    count=0
    while kill -0 "$nvim_pid" 2>/dev/null && [ "$count" -lt 20 ]; do
      count=$((count + 1))
      sleep 0.1
    done
    if kill -0 "$nvim_pid" 2>/dev/null; then
      kill "$nvim_pid" 2>/dev/null || true
    fi
  fi
  rm -f "$socket" "$log" "$output" "$hook_stderr" "$repo/codex-nvim-live-test.txt"
}
trap cleanup EXIT INT TERM

"$nvim_bin" \
  --headless \
  -u NONE \
  --listen "$socket" \
  --cmd "lua vim.opt.runtimepath:prepend([[$repo]])" \
  --cmd 'set columns=120 lines=40' \
  >/dev/null 2>&1 &
nvim_pid=$!

count=0
while [ "$count" -lt 50 ]; do
  if "$nvim_bin" --server "$socket" --remote-expr '1' >/dev/null 2>&1; then
    break
  fi
  count=$((count + 1))
  sleep 0.1
done
if [ "$count" -ge 50 ]; then
  die "timed out waiting for temporary Neovim RPC server"
fi

set_debug_expr="luaeval('(function(path) vim.g.codex_native_apply_patch_debug_log = path; package.loaded[\"codex.native_apply_patch_hook\"] = nil; return [[ok]] end)(_A)', '$log')"
debug_ready="$("$nvim_bin" --server "$socket" --remote-expr "$set_debug_expr" 2>/dev/null || true)"
if [ "$debug_ready" != "ok" ]; then
  die "failed to initialize Neovim debug state: $debug_ready"
fi

payload='{"hook_event_name":"PreToolUse","session_id":"live-test","cwd":"'"$repo"'","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: codex-nvim-live-test.txt\n+before-from-codex\n*** End Patch"},"tool_use_id":"live-test-1"}'

(
  printf '%s' "$payload" |
    CODEX_NVIM_APPLY_PATCH_TIMEOUT="$timeout_sec" /bin/sh "$repo/scripts/codex-nvim-apply-patch-hook" "$socket" "" "$nvim_bin" "$log"
) >"$output" 2>"$hook_stderr" &
hook_pid=$!

review_expr='luaeval("(function() local found = false; for _, b in ipairs(vim.api.nvim_list_bufs()) do local name = vim.api.nvim_buf_get_name(b); if name:match([[codex%-nvim%-live%-test%.txt$]]) and require([[codex.patch_session]])._active_session(b) then found = true end end; return found end)()")'
count=0
while [ "$count" -lt 100 ]; do
  found="$("$nvim_bin" --server "$socket" --remote-expr "$review_expr" 2>/dev/null || true)"
  if [ "$found" = "true" ]; then
    break
  fi
  count=$((count + 1))
  sleep 0.1
done
if [ "$count" -ge 100 ]; then
  die "timed out waiting for Neovim review buffer"
fi

modify_expr='luaeval("(function() local target = nil; for _, b in ipairs(vim.api.nvim_list_bufs()) do local name = vim.api.nvim_buf_get_name(b); if name:match([[codex%-nvim%-live%-test%.txt$]]) and require([[codex.patch_session]])._active_session(b) then target = b end end; if not target then return [[missing]] end; local lines = vim.api.nvim_buf_get_lines(target, 0, -1, false); for i, line in ipairs(lines) do if line == [[before-from-codex]] then vim.api.nvim_buf_set_lines(target, i - 1, i, false, { [[after-from-nvim]] }) end end; for _, win in ipairs(vim.fn.win_findbuf(target)) do if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end end; return [[ok]] end)()")'
modified="$("$nvim_bin" --server "$socket" --remote-expr "$modify_expr" 2>/dev/null || true)"
if [ "$modified" != "ok" ]; then
  die "failed to edit review buffer through Neovim RPC: $modified"
fi

accept_expr='luaeval("(function() local patch_session = require([[codex.patch_session]]); for _, b in ipairs(vim.api.nvim_list_bufs()) do local session = patch_session._active_session(b); if session and session.hunks and session.hunks[1] then patch_session._accept_hunk(session, session.hunks[1]); return [[ok]] end end; return [[missing]] end)()")'
accepted="$("$nvim_bin" --server "$socket" --remote-expr "$accept_expr" 2>/dev/null || true)"
if [ "$accepted" != "ok" ]; then
  die "failed to accept review hunk through Neovim RPC: $accepted"
fi

count=0
limit=$((timeout_sec * 10))
while kill -0 "$hook_pid" 2>/dev/null && [ "$count" -lt "$limit" ]; do
  count=$((count + 1))
  sleep 0.1
done
if kill -0 "$hook_pid" 2>/dev/null; then
  die "hook did not return after accepting review"
fi
wait "$hook_pid" || die "hook process failed"
hook_pid=""

grep -q '"permissionDecision":"allow"' "$output" || die "hook did not allow the reviewed patch"
grep -q '+after-from-nvim' "$output" || die "hook output did not include the Neovim-edited patch"
grep -q -- '-before-from-codex' "$output" || die "hook output did not describe the user edit from the Codex proposal"
grep -q 'USER MODIFICATIONS TO CODEX PROPOSAL' "$output" || die "hook output did not include user modification feedback"
grep -q '.codex-nvim-apply-patch-noop' "$output" || die "hook output did not return a native no-op completion patch"
if grep -q '+before-from-codex' "$output"; then
  die "hook output still included the original unedited patch"
fi
if [ "$(cat "$repo/codex-nvim-live-test.txt" 2>/dev/null || true)" != "after-from-nvim" ]; then
  die "hook review did not write the Neovim-edited patch through patch_session"
fi

printf '%s\n' "native apply_patch hook live test passed"
cat "$output"
printf '\n'
