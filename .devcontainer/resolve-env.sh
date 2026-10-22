#!/usr/bin/env sh
# Runs on the host before the container is created (initializeCommand).
# Resolves .devcontainer/.env into .devcontainer/.env.resolved, the file the
# container loads. Values may be literals or 1Password secret references
# (op://vault/item/field), which are resolved with `op inject`.
set -eu

dir=$(dirname "$0")
src="$dir/.env"
out="$dir/.env.resolved"

touch "$src"
umask 077

if grep -q 'op://' "$src"; then
  if ! command -v op >/dev/null 2>&1; then
    echo "resolve-env: $src has op:// references but the 1Password CLI (op) is not installed" >&2
    exit 1
  fi
  op inject --force --in-file "$src" --out-file "$out"
else
  cp "$src" "$out"
fi
