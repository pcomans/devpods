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
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspaces/${localWorkspaceFolderBasename},type=bind,relabel=private",
  "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}",
  "features": {
    "ghcr.io/devcontainers/features/github-cli:1": {}
  },
  "mounts": [
    "source=/run/user/1000/ssh-agent.socket,target=/ssh-auth-sock,type=bind,relabel=shared"
  ],
  "containerEnv": {
    "SSH_AUTH_SOCK": "/ssh-auth-sock"
  },
  "runArgs": [
    "--userns=keep-id",
    "--dns=1.1.1.1",
    "--dns=8.8.8.8"
  ],
  "postCreateCommand": "curl -fsSL https://claude.ai/install.sh | bash"
}
```

Five things to know:

- **`relabel=private` on the workspace mount** is required for rootless Podman + SELinux. Without it the bind-mounted workspace ends up with `user_home_t` label and the container's `container_t` process gets denied. Equivalent to `:Z` in a manual `podman run -v`.
- **SSH agent socket bind-mount, hardcoded literal path.** `source=/run/user/1000/ssh-agent.socket` is host-specific (uid 1000 baked in — fine for a single-user dev box). Two failure modes to be aware of with env-var alternatives:
   - `${localEnv:SSH_AUTH_SOCK}` resolves to DevPod's own ephemeral `/tmp/auth-agent.../listener.sock`, which is gone by the time podman tries to mount. Don't use it.
   - `${localEnv:HOST_SSH_AUTH_SOCK}` (or any other custom name) **does** substitute correctly to the host path you set, but triggers a *separate* DevPod bug: `chown ssh agent sock file: open /proc/acpi: permission denied`. DevPod takes a different code path for env-substituted mount sources than for literal strings, and that path is broken for rootless podman.
   - The hardcoded literal is the only thing that works today. `relabel=shared` (not `private`) so the host's ssh-agent process keeps access while the container reads.
- **`--userns=keep-id`** is required for the SSH socket to actually be readable inside the container. Rootless podman's default uid mapping makes the bind-mounted socket (owned by host uid 1000) unreadable as the in-container `vscode` user (which maps to a host subuid range without keep-id). `keep-id` keeps UIDs stable across the namespace boundary — same flag a hand-rolled `podman run` script would use.
- **No `--security-opt=no-new-privileges`.** It blocks `sudo` entirely (sudo needs setuid to escalate), which breaks the agent-in-container workflow that needs to `sudo apt install <dep>` on demand. Practical security loss is small — rootless podman already maps in-container root to an unprivileged host UID, so a setuid escalation can't reach host root.
- **`curl … claude.ai/install.sh`** is the current official installer (native binary). The older `npm install -g @anthropic-ai/claude-code` is deprecated as of 2026. `gh` CLI is from the standard feature and requires its own per-workspace `gh auth login` (device flow, ~10s) before commands like `gh pr create` work; SSH-agent-based `git` clone/push work without `gh` auth. **Image base intentionally generic (`base:ubuntu`)**: a Python or Node project should set its own image and add features (e.g. `node:1`, `python:1`, `rust:1`) for its stack.

### Security trade-offs

The reference config is **reasonably-isolated, not air-gapped**. What you get:

- Rootless podman + user namespaces + seccomp + SELinux on the workspace mount.
- No container-management sockets mounted; in-container processes start with `CapEff=0`.
- Host's MagicDNS overridden — Tailscale peers can't be name-resolved from inside.

What you don't get (deliberately):

- **No `no-new-privileges`.** `sudo` is the way the in-container agent installs project dependencies on demand, and `no-new-privileges` blocks `sudo` entirely (it needs setuid). The hardening was tried and reverted.
- **Tailnet IP isolation.** Container can still reach 100.x.x.x by raw IP if a process inside knows the address. If your tailnet hosts sensitive services and your container will run untrusted code, do the network-namespace work as a follow-up (1-3 hours of pasta config + verification matrix).
- **Image supply-chain pinning.** We use `mcr.microsoft.com/devcontainers/base:ubuntu` (latest); pin a SHA digest if you want byte-reproducible builds.
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

- **DevPod's `devpod ssh` interactive session DOES auto-forward the agent** (it sets up `/tmp/auth-agent.../listener.sock` and points `SSH_AUTH_SOCK` at it during the session). The explicit mount is for **non-interactive contexts**: `devpod ssh --command`, postCreate, background scripts run outside an active SSH session — those don't see the per-session forwarding. With both in place, every process has agent access.
- **Hardcoded source path required.** Use `source=/run/user/1000/ssh-agent.socket`, NOT `${localEnv:SSH_AUTH_SOCK}` — DevPod evaluates that substitution in a process where SSH_AUTH_SOCK has been overridden to its ephemeral `/tmp/auth-agent.../listener.sock`, gone by the time podman mounts.
- **`relabel=shared`** (`:z`) — both host ssh-agent and container ssh client need concurrent socket access. `relabel=private` (`:Z`) would lock the host out.
- **`--userns=keep-id` is mandatory with this mount** — without it the container's vscode user can't read the socket (UID maps don't line up).
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
- **DevPod caches the cloned source under `~/.devpod/agent/contexts/default/workspaces/<id>/content/`** and `devpod delete` doesn't always wipe it. If your `devcontainer.json` changes don't seem to be picked up even after `--reset`, also `rm -rf` that directory and re-up.
- **DevPod 0.6.15 ignores `overrideFeatureInstallOrder`.** Don't rely on it; install dependent things via `postCreateCommand` instead of stacking features.
- **Do not use `${containerEnv:PATH}` substitution.** DevPod doesn't expand it to the image's default PATH — it resolves to empty, which wipes `/bin` and `/usr/bin` and crashes the container at start (DevPod's own keep-alive `sleep` command fails). If you need to extend PATH, do it in `~/.bashrc` via postCreate.
- **DevPod's `--stdio` is the right primitive for SSH chaining.** Don't try to expose the container's sshd on a port; use ProxyCommand.
- **Post-quantum SSH warning** when connecting via Remote-SSH. The container's sshd doesn't advertise PQ key-exchange yet; OpenSSH 10+ clients warn but the connection still works fine. Harmless for tailnet-only use.
- **Run `devpod up` from a shell where `SSH_AUTH_SOCK` is set** so the bind mount source can resolve at host level. Interactive shells on systemd hosts have it; scripts/cron need an explicit `export SSH_AUTH_SOCK=/run/user/$(id -u)/ssh-agent.socket`.
