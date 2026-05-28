#!/bin/bash
# PreToolUse Bash hook — blocks bulk-removal of DevPod-built (vsc-content-*) podman images.
#
# Pattern that triggered a real workspace-loss incident on 2026-05-27:
#   podman images --filter "reference=localhost/vsc-content-*" -q | xargs -r podman rmi -f
# That command nuked ALL DevPod workspaces' images in one shot. This hook prevents repeats.
#
# Allow single-image deletes by hash/full-tag. Block anything that bulk-filters vsc-content-*.
# Escape hatch: prefix the command with DANGEROUS_CONFIRMED=1 to override.

# Read stdin JSON, extract the command string
COMMAND=$(jq -r '.tool_input.command // empty' 2>/dev/null)

# If we can't parse the input, fail-open (allow) — don't break unrelated bash calls
[ -z "$COMMAND" ] && exit 0

# Escape hatch: caller explicitly acknowledged the risk
if echo "$COMMAND" | grep -qE '(^|[[:space:]]|;)DANGEROUS_CONFIRMED=1'; then
  exit 0
fi

# Detect the dangerous pattern:
# - command contains 'podman' AND 'rmi' (image-remove operation)
# - AND uses a wildcard reference filter on vsc-content-* (matches multiple images)
# Patterns to catch:
#   podman images --filter "reference=localhost/vsc-content-*" -q | xargs ... podman rmi ...
#   podman rmi $(podman images --filter reference=...vsc-content-* -q)
#   podman rmi $(podman images | grep vsc-content | awk ...)
#   podman image prune --filter label=...vsc-content-*
if echo "$COMMAND" | grep -qE 'podman[[:space:]]+(image[s]?[[:space:]]+)?(rmi|prune|rm)' \
   && echo "$COMMAND" | grep -qE 'vsc-content'; then
  cat >&2 <<'MSG'
BLOCKED: Bulk podman rmi command targeting DevPod (vsc-content-*) images detected.

This command would remove container images for MULTIPLE DevPod workspaces at once,
destroying the runtime state of every workspace currently using a vsc-content-*
image. This previously caused a real workspace-loss incident.

Safer alternatives:
  1. List the candidates first to confirm scope:
       podman images --filter "reference=localhost/vsc-content-*"
  2. Delete a specific image by ID:
       podman rmi <IMAGE_ID>
  3. To rebuild ONE workspace's image:
       devpod up <workspace-name> --reset    # devpod handles per-workspace cleanup

If you really need the bulk delete, prefix with DANGEROUS_CONFIRMED=1:
  DANGEROUS_CONFIRMED=1 podman images --filter ... | xargs podman rmi -f
MSG
  exit 2
fi

exit 0
