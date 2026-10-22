#!/usr/bin/env sh
# Runs on the host before the container is created (initializeCommand).
# Resolves .devcontainer/.env into .devcontainer/.env.resolved, the file the
# container loads. Values may be literals or 1Password secret references
# (op://vault/item/field), which are resolved with `op inject`. Comment lines
# are ignored when looking for references, so the example's commented
# op:// placeholder does not require the 1Password CLI.
set -eu

dir=$(dirname "$0")
src="$dir/.env"
out="$dir/.env.resolved"

umask 077
touch "$src"

# Write to a temp file beside the target and move it into place, so a failed
# `op inject` never leaves a half-written file and the result is always 0600,
# even when an older, more permissive .env.resolved already exists.
tmp=$(mktemp "$dir/.env.resolved.XXXXXX")
trap 'rm -f "$tmp"' EXIT

if grep -v '^[[:space:]]*#' "$src" | grep -q 'op://'; then
  if ! command -v op >/dev/null 2>&1; then
    echo "resolve-env: $src has op:// references but the 1Password CLI (op) is not installed" >&2
    exit 1
  fi
  op inject --force --in-file "$src" --out-file "$tmp"
else
  cp "$src" "$tmp"
fi

chmod 600 "$tmp"
mv "$tmp" "$out"
