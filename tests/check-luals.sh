#!/bin/sh
# check-luals.sh - LuaLS conformance check for the devtools plugin sources.
#
# Builds two throwaway workspaces that point LuaLS at the vendored Plugin API
# v1 definitions (tests/lua-defs/bitty.d.lua, SDK e1723b6, plus the local
# tests/lua-defs/bitty-debug.d.lua for bitty.debug) and runs
# `lua-language-server --check`:
#
# - positive: lua/devtools/** must diagnose cleanly, including the
#   require("devtools.*") module tree.
# - negative: tests/lua-defs/negative-fixture.lua must be rejected for
#   surface excluded from Plugin API v1.
#
# The check is skipped with exit 0 when lua-language-server is unavailable so
# CI stays deterministic; `just lua` remains the always-on syntax gate. Set
# LUA_LANGUAGE_SERVER to override discovery.
#
# Usage: sh tests/check-luals.sh

set -eu

# Upper bound for one `lua-language-server --check` run, in seconds.
CHECK_TIMEOUT_SECS=120

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$here")
defs_dir="$here/lua-defs"

find_luals() {
  if [ -n "${LUA_LANGUAGE_SERVER:-}" ] && [ -x "$LUA_LANGUAGE_SERVER" ]; then
    printf '%s\n' "$LUA_LANGUAGE_SERVER"
    return 0
  fi
  command -v lua-language-server 2>/dev/null
}

if ! luals=$(find_luals) || [ -z "$luals" ]; then
  echo "skipped: lua-language-server not found on PATH (set LUA_LANGUAGE_SERVER)"
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/devtools-luals.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

# setup_workspace DIR RUNTIME_PATH_JSON: copy defs and write .luarc.json.
setup_workspace() {
  mkdir -p "$1/defs"
  cp "$defs_dir/bitty.d.lua" "$defs_dir/bitty-debug.d.lua" "$1/defs/"
  cat >"$1/.luarc.json" <<EOF
{
  "runtime": { "version": "Lua 5.4"$2 },
  "workspace": { "library": ["defs"], "checkThirdParty": false }
}
EOF
}

# run_check DIR: run LuaLS, store its exit status in $status and write one
# "<code><TAB><raw JSON message>" line per diagnostic to DIR/diagnostics.
run_check() {
  status=0
  timeout "$CHECK_TIMEOUT_SECS" "$luals" \
    "--check=$1" \
    --checklevel=Warning \
    --check_format=json \
    --locale=en-us \
    "--logpath=$1/log" >"$1/luals.out" 2>&1 || status=$?
  : >"$1/diagnostics"
  if [ -f "$1/log/check.json" ]; then
    # LuaLS writes pretty-printed JSON with sorted keys, so each entry's
    # "code" line precedes its "message" line.
    awk '
      /^[[:space:]]*"code":/ {
        code = $0
        sub(/^[[:space:]]*"code":[[:space:]]*"/, "", code)
        sub(/",?[[:space:]]*$/, "", code)
      }
      /^[[:space:]]*"message":/ {
        msg = $0
        sub(/^[[:space:]]*"message":[[:space:]]*"/, "", msg)
        sub(/",?[[:space:]]*$/, "", msg)
        printf "%s\t%s\n", code, msg
        code = ""
      }
    ' "$1/log/check.json" >"$1/diagnostics"
  fi
  count=$(wc -l <"$1/diagnostics" | tr -d ' ')
}

problems="$work/problems"
: >"$problems"

positive="$work/positive"
setup_workspace "$positive" ', "path": ["lua/?.lua", "lua/?/init.lua"]'
cp -R "$repo_root/lua" "$positive/lua"
run_check "$positive"
echo "positive: exit=$status diagnostics=$count"
if [ "$status" -ne 0 ] || [ "$count" -gt 0 ]; then
  echo "positive workspace must diagnose cleanly" >>"$problems"
  sed 's/^/    /' "$positive/diagnostics" >>"$problems"
fi

negative="$work/negative"
setup_workspace "$negative" ''
cp "$defs_dir/negative-fixture.lua" "$negative/"
run_check "$negative"
echo "negative: exit=$status diagnostics=$count"
# Each expectation is "<code>|<substring of the raw JSON message>".
for expectation in \
  'undefined-field|`api`' \
  'undefined-field|`on_event`' \
  'undefined-field|`control`' \
  'param-type-mismatch|\"secrets\"'; do
  code=${expectation%%|*}
  needle=${expectation#*|}
  if ! grep "^$code	" "$negative/diagnostics" | grep -qF -- "$needle"; then
    echo "negative workspace missing $code for $needle" >>"$problems"
  fi
done
if [ "$status" -eq 0 ]; then
  echo "negative workspace must report problems" >>"$problems"
fi

if [ -s "$problems" ]; then
  echo "LuaLS conformance failed:" >&2
  sed 's/^/  - /' "$problems" >&2
  exit 1
fi
echo "LuaLS conformance passed"
