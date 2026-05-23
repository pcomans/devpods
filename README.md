# DevPod-on-Bazzite — reference setup for AI dev sandboxes

A reproducible setup for disposable AI-development containers on a headless Bazzite host (immutable, OSTree-based Fedora), driven by [DevPod](https://devpod.sh), accessed remotely over [Tailscale](https://tailscale.com).

The goal: spin up project-specific, ephemeral workspaces ("livestock, not pets") where Claude Code runs with full in-container permissions, while the host OS stays pristine and credentials never persist inside the container.

> Local clones on the host are inspection-only. Real work happens inside DevPod-managed containers that clone their own copy of the repo and spawn git worktrees internally.

---

## Setup checklist (host)

Numbered, in order. Each step is independent and idempotent — re-run if you're rebuilding.

### 1. Install GitHub CLI

```bash
brew install gh                   # Bazzite ships Homebrew preinstalled
gh auth login                     # interactive; pick HTTPS + browser device flow
```

### 2. Install DevPod CLI

The brew formula is macOS-only, so grab the Linux binary:

```bash
mkdir -p ~/.local/bin
curl -fL -o ~/.local/bin/devpod \
  https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-amd64
chmod +x ~/.local/bin/devpod
devpod version                    # should print v0.6.x
```

### 3. Configure DevPod to drive rootless Podman

Bazzite ships Podman + a user systemd socket already enabled. DevPod's docker provider can talk to Podman directly:

```bash
devpod provider add docker
devpod provider use docker --option DOCKER_PATH=/usr/bin/podman
```

### 4. Generate an SSH key and register it with GitHub

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "devpod-host"
ssh-add ~/.ssh/id_ed25519
gh auth refresh -h github.com -s admin:public_key      # extra scope for key upload
gh ssh-key add ~/.ssh/id_ed25519.pub --title "devpod-host" --type authentication
ssh -T git@github.com                                  # should greet you by username
```

The container will clone via SSH using this key forwarded via `$SSH_AUTH_SOCK`. No token ever lives in the container filesystem.

### 5. Mint a Claude Code OAuth token

This is the cleanest way to inherit your Max subscription inside every workspace — see [Credential strategy](#credential-strategy) below for the why-not-bind-mount rationale.

```bash
claude setup-token                                     # interactive; emits a 1-year Max-backed token
echo 'export CLAUDE_CODE_OAUTH_TOKEN="<paste-token>"' >> ~/.bashrc
source ~/.bashrc
```

### 6. Enable Tailscale SSH (for remote access)

If you want to attach from another machine on your tailnet:

```bash
sudo tailscale set --ssh
```

Tailscale runs its own SSH server bound to the tailnet interface only — port 22 stays closed to LAN and internet.

### 7. Spin up your first workspace

The project repo must contain a `.devcontainer/devcontainer.json` (see [Reference devcontainer](#reference-devcontainer) below for the minimum-viable seed).

```bash
devpod up git@github.com:OWNER/REPO.git --ide none
devpod ssh REPO                                        # shell into the container
```

---

## Remote access from a client device

Once Tailscale SSH is on (step 6), any other device on the tailnet can attach. Pattern: ProxyCommand chain through the host into DevPod's `--stdio` tunnel.

In **`~/.ssh/config` on the client**:

```
Host my-workspace
    HostName placeholder
    User vscode
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    RequestTTY yes
    ProxyCommand ssh USER@TAILNET_HOSTNAME "/home/USER/.local/bin/devpod ssh --stdio --user vscode --workdir /workspaces/content WORKSPACE_NAME"
```

Replace `USER`, `TAILNET_HOSTNAME`, and `WORKSPACE_NAME` (it's the slug shown by `devpod list`). Then `ssh my-workspace` from the client drops you straight into the container.

**VS Code / Cursor / JetBrains Gateway**: with the same SSH config in place, use the Remote-SSH extension's "Connect to Host…" → `my-workspace`. The IDE installs its remote server inside the container, full LSP/debugger/extensions run there, the UI is local.

---

## Reference devcontainer

Minimal `.devcontainer/devcontainer.json` that works on Bazzite (rootless Podman, SELinux enforcing) with Claude Code preinstalled and Max auth passed through:

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/python:3",
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspaces/${localWorkspaceFolderBasename},type=bind,relabel=private",
  "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}",
  "features": {
    "ghcr.io/devcontainers/features/node:1": {}
  },
  "postCreateCommand": "npm install -g @anthropic-ai/claude-code",
  "containerEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}"
  }
}
```

Three non-obvious things in there:

- **`relabel=private` on the workspace mount** is required for rootless Podman + SELinux. Without it the bind-mounted workspace ends up with `user_home_t` label and the container's `container_t` process gets denied. Equivalent to `:Z` in a manual `podman run -v`.
- **`postCreateCommand` for Claude Code, not the `claude-code` devcontainer feature.** The official `ghcr.io/anthropics/devcontainer-features/claude-code` feature checks for `npm` at install time and fails when DevPod's feature install order doesn't put `node` first. `overrideFeatureInstallOrder` is not honored by DevPod 0.6.15. Installing via `npm install -g` after the node feature is in place sidesteps the whole dance.
- **`containerEnv` passes the host's `CLAUDE_CODE_OAUTH_TOKEN`** through to the container at create time. Substitution happens in the shell that invokes `devpod up` — interactive shells inherit `.bashrc` automatically; scripts/cron need an explicit `source ~/.bashrc` or equivalent.

The full devcontainer for a real project will add more features (Python toolchain, lifecycle hooks, secrets), but this seed is what gets a workspace healthy enough for Claude inside to author the rest.

---

## Credential strategy

The principle: **broad-scope credentials never live in the container; narrow-scope ones may, via env not files.**

### GitHub — SSH agent forwarding

Container clones over `git@github.com:...`. DevPod forwards `$SSH_AUTH_SOCK`. No token in container fs. `devpod delete` leaves nothing behind.

- Do **not** bind-mount `~/.config/gh` (long-lived OAuth, full user scope).
- Do **not** bind-mount `~/.ssh` (private keys exposed).
- If HTTPS is forced (CI etc.), use a fine-grained PAT scoped to the single repo with ≤30-day expiry, injected via `remoteEnv`.

### Claude Max — `setup-token` + `CLAUDE_CODE_OAUTH_TOKEN`

Per Anthropic's current docs:

- Their devcontainer doc explicitly recommends *against* bind-mounting secret files.
- Open bug [claude-code #50743] (May 2026): OAuth refresh broken in non-interactive `-p` mode — bind-mounted credentials die after ~15 min, killing headless agent runs.
- macOS hosts now keep credentials in Keychain only; the CLI actively deletes any `.credentials.json` it finds. Cross-platform bind mount isn't viable.

`claude setup-token` mints a Max-backed 1-year token, revocable independently from claude.ai. Passed through `containerEnv` it's visible inside the container while running (env-greppable), but blast radius is bounded to Claude quota spend and is revocable in seconds.

**Billing nuance** (Anthropic change effective 2026-06-15): `claude -p` and Agent SDK invocations under subscription plans move to a separate monthly Agent-SDK credit metered at full API rates. Interactive `claude` sessions stay on the standard Max bucket.

---

## Principles (do not violate)

1. **Host stays pristine.** No `rpm-ostree install` for dev tooling. Everything in `~/.local/bin`, Homebrew, or containers.
2. **Agent in container owns container config.** Host-authored `.devcontainer/` should be a deliberate minimal seed; the in-workspace agent extends it. The seed above is the bare minimum to bootstrap.
3. **No bind mounts of source.** Container clones the repo itself, uses worktrees internally for branch-per-task work.
4. **No long-lived broad-scope creds in container.** SSH agent forwarding for git; narrow-scope OAuth env for Claude.
5. **Workspaces are livestock.** When something breaks: `devpod delete WORKSPACE && devpod up git@github.com:OWNER/REPO.git`. Don't debug a sick container — recreate it.

---

## Useful commands

```bash
devpod list                                # current workspaces
devpod up REPO                             # start (or create) a workspace
devpod ssh REPO                            # shell into it
devpod stop REPO                           # stop without destroying
devpod delete REPO                         # destroy (preserves named volumes)
devpod up REPO --recreate                  # rebuild container, keep source
devpod up REPO --reset                     # nuke everything, fresh clone

podman ps --format "{{.Names}}\t{{.Image}}"   # find the actual podman container name
podman images                              # see DevPod-built images
ujust clean-system                         # Bazzite housekeeping (purges old images/volumes)
```

---

## Known gotchas

- **`devpod up --recreate` keeps the cached image.** If you change `features` in `devcontainer.json`, `--recreate` may reuse the prior image. Use `--reset` to force a full rebuild.
- **DevPod 0.6.15 ignores `overrideFeatureInstallOrder`.** Don't rely on it; install dependent things via `postCreateCommand` instead of stacking features.
- **Bash non-interactive shells don't source `~/.bashrc`.** If you script `devpod up`, explicitly `source ~/.bashrc` first or the `CLAUDE_CODE_OAUTH_TOKEN` passthrough will be empty.
- **DevPod's `--stdio` is the right primitive for SSH chaining.** Don't try to expose the container's sshd on a port; use ProxyCommand.

[claude-code #50743]: https://github.com/anthropics/claude-code/issues/50743
