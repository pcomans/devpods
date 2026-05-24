#!/usr/bin/env bash
# Write the API keys currently in your shell env to a file that
# DevPod workspaces (this repo's reference devcontainer) bind-mount
# into /etc/devpod-keys.env, where the container's bashrc sources them.
#
# Reads values from env only — never prompts, never echoes secrets.
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   export DEEPSEEK_API_KEY=...
#   ./scripts/setup-api-keys.sh

set -euo pipefail

SECRETS_DIR="$HOME/.config/devpod"
SECRETS_FILE="$SECRETS_DIR/api-keys.env"

required=(ANTHROPIC_API_KEY DEEPSEEK_API_KEY)

missing=()
for var in "${required[@]}"; do
  if [ -z "${!var:-}" ]; then
    missing+=("$var")
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  printf 'Missing env vars: %s\n' "${missing[*]}" >&2
  printf 'Set them in your shell first, then re-run.\n' >&2
  exit 1
fi

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

tmp="$(mktemp "$SECRETS_FILE.XXXXXX")"
chmod 600 "$tmp"
for var in "${required[@]}"; do
  printf '%s=%s\n' "$var" "${!var}" >> "$tmp"
done
mv "$tmp" "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

printf 'Wrote %s\n' "$SECRETS_FILE"
printf 'Contents (lengths only, no values shown):\n'
for var in "${required[@]}"; do
  v="${!var}"
  printf '  %s = %d chars\n' "$var" "${#v}"
done
