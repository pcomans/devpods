# DevPod-on-Bazzite — reference setup for AI dev sandboxes

A reproducible setup for disposable AI-development containers on a headless Bazzite host (immutable, OSTree-based Fedora), driven by [DevPod](https://devpod.sh), accessed remotely over [Tailscale](https://tailscale.com).

The goal: spin up project-specific, ephemeral workspaces where Claude Code runs with full in-container permissions, while the host OS stays pristine and broad-scope credentials never persist inside the container.

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

The container clones via SSH using this key forwarded via `$SSH_AUTH_SOCK`. No token ever lives in the container filesystem.

### 5. Enable Tailscale SSH (for remote access)

If you want to attach from another machine on your tailnet:

```bash
sudo tailscale set --ssh
```

Tailscale runs its own SSH server bound to the tailnet interface only — port 22 stays closed to LAN and internet.

### 6. Spin up your first workspace

The project repo must contain a `.devcontainer/devcontainer.json` (see [Reference devcontainer](#reference-devcontainer) below for the minimum-viable seed).

**Always pass `--id <stable-name>`** so the workspace identity is decoupled from the git URL/branch — without it, every branch you bootstrap from creates a separate workspace with a different slug, and your client SSH config has to track it. With `--id`, the workspace name stays the same forever.

```bash
devpod up git@github.com:OWNER/REPO.git --ide none --id REPO
devpod ssh REPO                                        # shell into the container
claude                                                 # first run: walks you through device-flow login
```

Bootstrap from a feature branch the same way — only the source URL changes, the workspace name stays put:
```bash
devpod up git@github.com:OWNER/REPO.git@some-branch --ide none --id REPO
```

Inside the container, switch tasks via `git worktree add` against the same repo — one container, many branches, all under `/workspaces/content/.worktrees/<task>`.

The `claude` login is per-workspace (~10s via browser). We deliberately don't bake credentials into the container — see [Why no Claude pre-auth](#why-no-claude-pre-auth).

---

## Remote access from a client device

Once Tailscale SSH is on (step 5), any other device on the tailnet can attach. Pattern: ProxyCommand chain through the host into DevPod's `--stdio` tunnel.

In **`~/.ssh/config` on the client**:

```
Host my-workspace
    HostName placeholder
    User vscode
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    RequestTTY yes
    LogLevel ERROR
    ProxyCommand ssh USER@TAILNET_HOSTNAME "/home/USER/.local/bin/devpod ssh --stdio --user vscode --workdir /workspaces/content WORKSPACE_NAME"
```

Replace `USER`, `TAILNET_HOSTNAME`, and `WORKSPACE_NAME` (the value you passed to `--id`). Then `ssh my-workspace` from the client drops you straight into the container. **Use `--id` when creating workspaces** — otherwise the workspace slug derives from the git URL and changes when you bootstrap from a branch, forcing you to edit this config every time.

**VS Code / Cursor / JetBrains Gateway**: with the same SSH config in place, use the Remote-SSH extension's "Connect to Host…" → `my-workspace`. The IDE installs its remote server inside the container, full LSP/debugger/extensions run there, the UI is local.

---

## Reference devcontainer

Minimal `.devcontainer/devcontainer.json` that works on Bazzite (rootless Podman, SELinux enforcing):

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/python:3",
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspaces/${localWorkspaceFolderBasename},type=bind,relabel=private",
  "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}",
  "features": {
    "ghcr.io/devcontainers/features/node:1": {},
    "ghcr.io/devcontainers/features/github-cli:1": {}
  },
  "mounts": [
    "source=${localEnv:SSH_AUTH_SOCK},target=/ssh-auth-sock,type=bind,relabel=shared"
  ],
  "containerEnv": {
    "SSH_AUTH_SOCK": "/ssh-auth-sock"
  },
  "runArgs": [
    "--security-opt=no-new-privileges",
    "--dns=1.1.1.1",
    "--dns=8.8.8.8"
  ],
  "postCreateCommand": "curl -fsSL https://claude.ai/install.sh | bash"
}
```

Five things to know:

- **`relabel=private` on the workspace mount** is required for rootless Podman + SELinux. Without it the bind-mounted workspace ends up with `user_home_t` label and the container's `container_t` process gets denied. Equivalent to `:Z` in a manual `podman run -v`.
- **SSH agent socket bind-mount** with `relabel=shared` (note: `shared`, not `private` — the host's ssh-agent process needs to keep serving the socket while the container reads from it). DevPod's docker provider does NOT auto-forward `$SSH_AUTH_SOCK` into rootless podman containers; this mount is what makes `git@github.com:...` clones / pushes work without baking in a token. **Requires the shell that runs `devpod up` to have `SSH_AUTH_SOCK` set** — interactive shells on systemd hosts do by default.
- **`runArgs` hardening**: `no-new-privileges` prevents in-container setuid escalation (free win); explicit public DNS overrides the host's MagicDNS so the container can't name-resolve Tailscale peers. Blocks the common prompt-injection-driven recon path. Does **not** block raw-IP probes to 100.x.x.x — full network-namespace isolation would be a meaningfully larger change (see [Security trade-offs](#security-trade-offs) below).
- **`curl … claude.ai/install.sh`** is the current official installer (native binary). The older `npm install -g @anthropic-ai/claude-code` path is deprecated as of 2026.
- **Node + github-cli via standard features.** Both are needed for typical project work; the `claude-code` devcontainer feature is *not* used (failed install on this base — `npm` not detected even with node feature, install order isn't honored by DevPod 0.6.15). The `gh` CLI requires its own per-workspace `gh auth login` (device flow, ~10s — same pattern as `claude`) before commands like `gh pr create` work; SSH-agent-based `git push`/clone work without any gh auth.

### Security trade-offs

The reference config is **reasonably-isolated, not air-gapped**. What you get:

- Rootless podman + user namespaces + seccomp + SELinux on the workspace mount.
- No container-management sockets mounted; in-container processes have `CapEff=0`.
- `no-new-privileges` prevents setuid escalation.
- Host's MagicDNS overridden — Tailscale peers can't be name-resolved from inside.

What you don't get (left out deliberately as overkill for a personal-trust workspace):

- **Tailnet IP isolation.** Container can still reach 100.x.x.x by raw IP if a process inside knows the address. If your tailnet hosts sensitive services and your container will run untrusted code, do the network-namespace work as a follow-up (1-3 hours of pasta config + verification matrix).
- **Image supply-chain pinning.** We use `mcr.microsoft.com/devcontainers/python:3` (latest python:3); pin a SHA digest if you want byte-reproducible builds.
- **Outbound egress restriction.** Container can reach the whole internet. Add a host firewall rule (firewalld) if you need to allowlist specific destinations.

The in-container agent (a `claude` session running inside the workspace) is expected to extend this seed with project-specific tooling, lifecycle hooks, and sibling services as a follow-up commit.

---

## Why no Claude pre-auth

We tried two patterns and abandoned both:

1. **Env-var passthrough** (`CLAUDE_CODE_OAUTH_TOKEN` via `containerEnv`). Works for `claude -p` non-interactive mode. **Does not skip the interactive onboarding prompt** — on first launch in a fresh container, `claude` opens the setup flow regardless of env. There's an undocumented workaround (write a `~/.claude.json` stub with `hasCompletedOnboarding: true`), but the current stub now requires 5 fields including `accountUuid`/`organizationUuid` and is keyed to internal CLI behavior that can break between releases. Not stable enough to bake in.

2. **Bind-mount `~/.claude/.credentials.json`** from host. Works, but: couples container auth to a host file the host's own `claude` mutates (refresh tokens, label drift under SELinux); credentials file contains both access AND refresh tokens (wider blast radius than the env-var-only path); not revocable independently of your main Claude account.

**The accepted approach: per-workspace login.** `claude` inside the workspace presents a browser device flow on first run (URL + code). You paste the URL into your local browser, paste the code back, done in ~10s. Workspace is ephemeral so the credentials die with it on `devpod delete`.

---

## Credential strategy

The principle: **broad-scope credentials never live in the container, and we don't try to be clever about narrower ones either.**

### GitHub — SSH agent socket bind-mount

Container clones / pushes over `git@github.com:...` using the host's loaded ed25519 key via a bind-mounted ssh-agent socket. No token or private key in container fs; `devpod delete` leaves nothing behind.

- **DevPod does not auto-forward `$SSH_AUTH_SOCK`** into rootless podman containers — you have to bind-mount the socket explicitly (see the reference devcontainer config above). An earlier draft of this doc said "DevPod forwards `$SSH_AUTH_SOCK`" without the mount; that was wrong, and inside such a container `ssh-add -l` would report no agent.
- The mount uses `relabel=shared` (`:z`) because both the host's ssh-agent process and the container's ssh client need to use the socket concurrently. `relabel=private` (`:Z`) would lock the host out.
- Do **not** bind-mount `~/.config/gh` (long-lived OAuth, full user scope).
- Do **not** bind-mount `~/.ssh` directory (private keys exposed). Mount only the agent socket.
- For `gh`-based operations (`gh pr create`, `gh api ...`), do `gh auth login` once per workspace (device flow, ~10s). `git` operations don't need this — they use the SSH agent.
- If HTTPS is forced (CI etc.), use a fine-grained PAT scoped to the single repo with ≤30-day expiry, injected via `containerEnv`.

### Claude Max — per-workspace login

See [Why no Claude pre-auth](#why-no-claude-pre-auth) above. Short version: `claude` inside the container, browser device flow, once per workspace.

---

## Principles (do not violate)

1. **Host stays pristine.** No `rpm-ostree install` for dev tooling. Everything in `~/.local/bin`, Homebrew, or containers.
2. **Agent in container owns container config.** Host-authored `.devcontainer/` should be a deliberate minimal seed; the in-workspace agent extends it. The seed above is the bare minimum to bootstrap.
3. **No bind mounts of source.** Container clones the repo itself, uses worktrees internally for branch-per-task work.
4. **No broad-scope creds in container.** SSH agent forwarding for git; per-workspace login for Claude.
5. **Rebuild, don't repair.** When something breaks: `devpod delete WORKSPACE && devpod up git@github.com:OWNER/REPO.git`. Don't debug a misbehaving container.

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
- **DevPod's `--stdio` is the right primitive for SSH chaining.** Don't try to expose the container's sshd on a port; use ProxyCommand.
- **Post-quantum SSH warning** when connecting via Remote-SSH. The container's sshd doesn't advertise PQ key-exchange yet; OpenSSH 10+ clients warn but the connection still works fine. Harmless for tailnet-only use.
