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

This is what DevPod's git credential injection uses under the hood — having `gh` authenticated on the host is what lets the container clone/push private repos transparently over HTTPS.

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

### 4. Enable DevPod's credential injection (defaults — verify)

DevPod auto-injects a git credential helper into the container that proxies HTTPS calls back to the host's `gh`. Confirm it's on:

```bash
devpod context set-options \
  -o SSH_INJECT_GIT_CREDENTIALS=true \
  -o SSH_AGENT_FORWARDING=true
devpod context options | grep -iE "(INJECT|AGENT_FORWARDING)"
```

Both should report `true`. Both are default-on in DevPod 0.6.15 — this is belt-and-suspenders.

### 5. Generate an SSH key and register it with GitHub

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "devpod-host"
ssh-add ~/.ssh/id_ed25519
gh auth refresh -h github.com -s admin:public_key
gh ssh-key add ~/.ssh/id_ed25519.pub --title "devpod-host" --type authentication
ssh -T git@github.com                                  # should greet you by username
```

(Inside the container you'll use HTTPS remotes via DevPod's credential injection, not SSH. This key is for host-side `git` operations and for tools like `gh` itself.)

### 6. Wire up dotfiles

DevPod has a separate global bootstrap mechanism from `devcontainer.json`: it clones a dotfiles repo into `~/dotfiles` inside **every** workspace and runs a script there on every `devpod up`, regardless of whether that workspace's own repo has a devcontainer.json at all. This repo's own [`dotfiles/`](dotfiles/) directory is that bootstrap — currently just the `xterm-ghostty` terminfo entry and the tmux truecolor fix (see [Known gotchas](#known-gotchas-beyond-the-procacpi-saga)).

```bash
devpod context set-options \
  -o DOTFILES_URL=https://github.com/pcomans/devpods.git \
  -o DOTFILES_SCRIPT=dotfiles/install.sh
devpod context options | grep -iE "DOTFILES"
```

`DOTFILES_SCRIPT` is relative to the repo root, so this works even though `dotfiles/` isn't at the top level. DevPod does **not** `git pull` an already-cloned `~/dotfiles` on repeat `up`s — only `install.sh` re-runs — so changes here reach existing workspaces only via `devpod up <workspace> --recreate` (which wipes and re-clones the container's home directory) or a manual `rm -rf ~/dotfiles && devpod up`.

### 7. Enable Tailscale SSH (for remote access)

```bash
sudo tailscale set --ssh
```

Tailscale runs its own SSH server bound to the tailnet interface only — port 22 stays closed to LAN and internet.

### 8. Spin up your first workspace

The project repo must contain a `.devcontainer/devcontainer.json` (see [Reference devcontainer](#reference-devcontainer) below for the minimum-viable seed).

**Always pass `--id <stable-name>`** so the workspace identity is decoupled from the git URL/branch. Without it, every branch you bootstrap from creates a separate workspace with a different slug.

```bash
devpod up git@github.com:OWNER/REPO.git --ide none --id REPO
devpod ssh REPO                                        # interactive shell
claude                                                 # first run: browser device flow
```

Bootstrap from a feature branch — only the source URL changes, the workspace name stays put:
```bash
devpod up git@github.com:OWNER/REPO.git@some-branch --ide none --id REPO
```

Inside the container, switch tasks via `git worktree add`. One container, many branches.

---

## Remote access from a client device

Once Tailscale SSH is on, any other device on your tailnet can attach. Pattern: ProxyCommand chain through the host into DevPod's `--stdio` tunnel.

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

Replace `USER`, `TAILNET_HOSTNAME`, and `WORKSPACE_NAME` (the value you passed to `--id`). Then `ssh my-workspace` from the client drops you straight into the container.

**VS Code / Cursor / JetBrains Gateway**: with this SSH config in place, use the Remote-SSH extension's "Connect to Host…" → `my-workspace`. The IDE installs its remote server inside the container; full LSP/debugger/extensions run there, UI is local.

---

## Reference devcontainer

Minimal `.devcontainer/devcontainer.json` that works on Bazzite (rootless Podman, SELinux enforcing) **in May 2026**. This config has been hard-won — earlier versions with SSH socket mounts, `--userns=keep-id`, and env-var passthrough all worked for a while then started failing after a podman/Bazzite update. See [The `/proc/acpi` saga](#the-procacpi-saga) below for why this config is so minimal.

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspaces/${localWorkspaceFolderBasename},type=bind,relabel=private",
  "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}",
  "features": {
    "ghcr.io/devcontainers/features/github-cli:1": {}
  },
  "runArgs": [
    "--dns=1.1.1.1",
    "--dns=8.8.8.8"
  ],
  "postCreateCommand": "curl -fsSL https://claude.ai/install.sh | bash"
}
```

Three things to know:

- **`relabel=private` on the workspace mount** is required for rootless Podman + SELinux. Without it the bind-mounted workspace ends up with `user_home_t` label and the container's `container_t` process gets denied. Equivalent to `:Z` in a manual `podman run -v`.
- **DNS override (`1.1.1.1` / `8.8.8.8`)** prevents the container from name-resolving Tailscale peers via the host's MagicDNS. Blocks the common prompt-injection-driven recon path. Does not block raw-IP probes to `100.x.x.x` — full network-namespace isolation would be a meaningfully larger change.
- **`curl … claude.ai/install.sh`** is the current official Claude Code installer (native binary). `npm install -g @anthropic-ai/claude-code` is deprecated as of 2026. Image base intentionally generic — Python or Node projects should set their own image and add features (`node:1`, `python:1`, `rust:1`).

### What's deliberately *not* in there

| Old idea | Why removed |
|---|---|
| `mounts: [SSH agent socket]` | Triggers the `/proc/acpi` bug on current podman. DevPod's per-session agent forwarding handles interactive use; HTTPS git via the credential helper handles non-interactive. |
| `--userns=keep-id` | Required *only* if you mount the SSH socket. Without the socket mount, default rootless-podman UID mapping is fine. Also a `/proc/acpi` trigger. |
| `containerEnv` with `${localEnv:...}` | Triggers `/proc/acpi`. |
| `--security-opt=no-new-privileges` | Blocks `sudo` (sudo needs setuid to escalate). Agent-in-container workflows that `sudo apt install <dep>` need sudo. |
| `runArgs: [--env=NAME]` | Triggers `/proc/acpi`. |
| Bind-mount of a host secrets file | Triggers `/proc/acpi`. (Even hardcoded source path — it's adding *any* extra mount that fires the bug.) |

---

## Credential strategy

The principle: **broad-scope credentials never live in the container fs**, and we lean on DevPod's built-in injection rather than rolling our own.

### GitHub — DevPod's built-in credential injection (HTTPS) + per-session SSH agent forwarding

What you get for free with `SSH_INJECT_GIT_CREDENTIALS=true` and `SSH_AGENT_FORWARDING=true` (both default-on):

- **HTTPS git auth works automatically.** DevPod sets `git config --global credential.helper` inside the container to a helper that proxies `git credential fill` calls back to the host's git/gh over the existing SSH channel. `git clone https://github.com/OWNER/PRIVATE.git`, `git push`, `git pull` — all just work.
- **Interactive `devpod ssh` sessions get the SSH agent forwarded** via DevPod's per-session `/tmp/auth-agent.../listener.sock`. So if a tool inside the container uses `git@github.com:...` URLs interactively, that also works.

What you don't get (and the workarounds):

- **`devpod ssh --command "..."` mode does NOT get agent forwarding** — only fully interactive sessions do. If you have a script that needs git auth, use HTTPS remotes; the credential helper works in both modes.
- **`gh` CLI inside the container is NOT pre-authed.** For `gh pr create`, `gh api`, etc., run `gh auth login` once per workspace (browser device flow, ~10s). It's separate from git auth.

### Use HTTPS remotes inside the container

DevPod clones with the URL you pass it, so if you bootstrap from `git@github.com:OWNER/REPO.git` the in-container origin will be SSH and won't work for `git push` from `--command` mode. Flip to HTTPS once after the workspace is created:

```bash
devpod ssh REPO --command "cd /workspaces/content && git remote set-url origin https://github.com/OWNER/REPO.git"
```

### Claude Max — per-workspace login

`claude` inside the container, browser device flow on first run, takes ~10s. We tried two pre-auth patterns (env-var passthrough and credentials bind-mount); both were either fragile, undocumented, or now broken by the `/proc/acpi` bug. Per-workspace login is the only setup that's robust to current DevPod/podman behavior.

### Passing API keys into the container (for tools like Aider)

If you need additional secrets (DeepSeek API key, OpenAI key, etc.) in the container for tools that don't use the git credential helper, **don't add `containerEnv` or mounts** — they trigger the `/proc/acpi` bug. Instead, inject from host shell via `devpod ssh` stdin into the container's bashrc:

```bash
devpod ssh REPO --command 'cat >> ~/.bashrc' <<EOF
export ANTHROPIC_API_KEY="\$ANTHROPIC_API_KEY"
export DEEPSEEK_API_KEY="\$DEEPSEEK_API_KEY"
EOF
```

Keys flow through the encrypted DevPod tunnel; never touch devcontainer.json. Re-run after each `devpod delete`/recreate (container fs is wiped).

### `git-credentials` skill — teach the in-container agent this, not just you

Everything above is easy for a human to internalize once and easy for an agent inside the container
to get wrong every single time it hits an auth failure fresh, especially the non-obvious part: DevPod's
credential/SSH-agent forwarding only exists inside a process tree started by `devpod ssh` — it's
invisible to a bare shell attached to the container by any other means, even though that shell looks
identical from inside. An agent that doesn't know this will try things it shouldn't: reading SSH keys,
asking the user for a token, or reporting "credentials broken" when the actual fix is "reconnect
through `devpod ssh`."

This repo ships that knowledge as a plugin (`plugins/git-credentials/`) with a skill that loads only
when relevant (~190 tokens always-on for the listing, ~1k on invoke — see `claude plugin details
git-credentials@devpods`), not a project CLAUDE.md entry that would cost context on every unrelated
turn. Install it once per workspace, in `postCreateCommand`, alongside any other tool installs:

```bash
claude plugin marketplace add pcomans/devpods
claude plugin install git-credentials@devpods --scope user
```

Both are non-interactive `claude plugin` CLI subcommands (distinct from the interactive `/plugin`
slash commands), so they work unattended in `postCreateCommand`. See
`plugins/git-credentials/skills/git-credentials/SKILL.md` for the actual content, and
[Create and distribute a plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces) for
how the marketplace/plugin structure works if you want to add more skills here later.

---

## The `/proc/acpi` saga

This is a real DevPod + rootless-podman bug as of 2026-05. Recording the trigger conditions so future-you doesn't re-derive them.

**Symptom**: container fails to start with
```
chown ssh agent sock file: open /proc/acpi: permission denied
devcontainer up: run agent command: Process exited with status 1
```

**Triggers (any one of these will reproduce):**
- `mounts: [...]` with any source path (literal OR `${localEnv:...}`-substituted)
- `containerEnv: {...}` with `${localEnv:VAR}` substitution
- `runArgs: ["--env=VAR_NAME", ...]` (podman name-only env forwarding)
- `runArgs: ["--userns=keep-id", ...]` combined with any of the above

**Mechanism (best guess)**: a recent podman/crun bump strictly enforces masked paths (`/proc/acpi`, etc.). DevPod's setup code walks the FS to chown the forwarded ssh-agent socket; when extra mounts or env-forwarding are present, the walk order changes and hits a masked node, returning `EACCES`.

**No upstream fix as of DevPod 0.6.15.** Workarounds: keep the devcontainer.json minimal (as above), rely on DevPod's per-session agent forwarding and credential helper injection for git, and use the `devpod ssh ... <<EOF` heredoc pattern to inject any other env values.

Closest related issues: [loft-sh/devpod#1611](https://github.com/loft-sh/devpod/issues/1611), [#1719](https://github.com/loft-sh/devpod/issues/1719), [#1907](https://github.com/loft-sh/devpod/issues/1907), [containers/podman#25189](https://github.com/containers/podman/issues/25189).

---

## The Claude Code `codex` plugin's sandbox is broken here — and how it's fixed

**Symptom**: the `codex` plugin (from `openai/codex-plugin-cc`) authenticates fine, then every shell command it tries to run is blocked before execution — it falls back to useless web searches instead. The plugin hardcodes its sandbox mode per-request (`read-only` for reviews, `workspace-write` for write tasks), overriding `~/.codex/config.toml` entirely, and none of those modes can actually construct a working [bubblewrap](https://github.com/containers/bubblewrap) sandbox in this container: it needs `CAP_SYS_ADMIN` to mount `devpts`, which an unprivileged container user doesn't have, and is separately blocked by the SELinux `container_t` policy.

**Rejected fix**: granting the container `CAP_SYS_ADMIN` + `--security-opt label=disable` (disabling SELinux confinement) makes bubblewrap work, but it's a real, ongoing reduction in host isolation for every workspace that inherits it — not something to put in a shared reference template. (Full diagnosis, including the rejected fix and why: [`docs/reports/codex-sandbox-in-devcontainers.md`](docs/reports/codex-sandbox-in-devcontainers.md).)

**Actual fix**: this is a well-known, actively-tracked upstream bug ([openai/codex-plugin-cc#482](https://github.com/openai/codex-plugin-cc/issues/482) and others), with an open, reviewed, tested fix already written but not yet merged: [openai/codex-plugin-cc#508](https://github.com/openai/codex-plugin-cc/pull/508). It makes the plugin properly defer to `sandbox_mode` in `~/.codex/config.toml` instead of hardcoding it — Codex's own `danger-full-access` mode skips bubblewrap's sandbox construction entirely, so there's no container privilege needed at all. Install the plugin from that fix, pinned to the exact commit (not the branch):

```bash
rm -rf ~/.claude/plugins/marketplaces/cubicj-codex-plugin-cc
git clone https://github.com/cubicj/codex-plugin-cc.git ~/.claude/plugins/marketplaces/cubicj-codex-plugin-cc
(cd ~/.claude/plugins/marketplaces/cubicj-codex-plugin-cc && git checkout e5ce2723f7a174ba6b616c84ef8abb1771b2471e)
claude plugin marketplace add ~/.claude/plugins/marketplaces/cubicj-codex-plugin-cc
claude plugin install codex@openai-codex --scope user
mkdir -p ~/.codex
grep -q "^sandbox_mode" ~/.codex/config.toml 2>/dev/null || (grep -q "^\[" ~/.codex/config.toml 2>/dev/null && sed -i "0,/^\[/s//sandbox_mode = \"danger-full-access\"\n[/" ~/.codex/config.toml || printf 'sandbox_mode = "danger-full-access"\n' >> ~/.codex/config.toml)
```

`claude plugin marketplace add owner/repo#<ref>` only resolves branch/tag refs, not arbitrary commit SHAs — hence the manual clone + checkout + local-path registration, which pins the exact commit and is immune to a future force-push on the branch.

The `config.toml` write is guarded two ways, both load-bearing:
- The `grep -q "^sandbox_mode"` check makes repeat `postCreateCommand` runs a no-op instead of appending duplicate keys.
- A blind `printf ... >> config.toml` isn't safe even the *first* time: if `codex` has already run once and written a `[projects."..."]` or `[tui...]` table (which happens automatically, before you'd ever think to check), a plain append lands the new key *inside* that last table instead of at the top level — silently producing `tui.model_availability_nux.sandbox_mode` instead of a global `sandbox_mode`, which Codex then just ignores. Reproduced this exact failure live when applying this recipe to a second workspace that had already been used interactively. The `sed` branch above finds the first `[table]` header (if any) and inserts before it, so the key always lands at the top level regardless of what's already in the file.

**Revisit when [#508](https://github.com/openai/codex-plugin-cc/pull/508) merges upstream** — switch back to `claude plugin marketplace add openai/codex-plugin-cc` directly.

**Caveat found after shipping this**: the fix only unblocks a *flagless* task call. **Neither `/codex:review` nor `/codex:rescue` actually work** — both always pass an explicit sandbox mode (`read-only` or `workspace-write`), and *any* explicit mode still tries to construct a real bubblewrap sandbox, which still fails here. Verified: `task` (no flag) works; `task --read-only` and `task --write` both still hit `bwrap: Can't mount devpts`. Until the container gets real bubblewrap support (Option A above, not adopted), the only way to use Codex here is a direct, flagless companion-script call — which is also fully unsandboxed, since flagless defers to `~/.codex/config.toml`'s `danger-full-access`. See the report's third addendum for the full trade-off and the two alternatives considered and rejected.

---

## Safety hooks for agents using this setup

If you let a Claude Code (or similar) agent operate against this host, install the **bulk-rmi guard hook** to prevent a single bad command from wiping every workspace's container image at once.

### The incident this prevents

On 2026-05-27, an agent ran:

```bash
podman images --filter "reference=localhost/vsc-content-*" -q | xargs -r podman rmi -f
```

…intending to clean up one workspace's cached image. That filter matches **every DevPod-built image on the host**, so `xargs rmi -f` simultaneously destroyed the runtime images for three live workspaces. None of the workspaces' source-code clones were lost (cached under `~/.devpod/agent/...` and on GitHub), but every container's filesystem state — injected API keys, agent bashrc additions, in-progress session state — vanished. Real ~30 minutes of recovery work, and the only reason data survived was that the agent had pushed commits earlier.

### Install

```bash
mkdir -p ~/.claude/hooks
cp hooks/block-vsc-content-bulk-rmi.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/block-vsc-content-bulk-rmi.sh
```

Add to `~/.claude/settings.json` (merge with existing keys):

```jsonc
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/home/<USER>/.claude/hooks/block-vsc-content-bulk-rmi.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

Then open Claude Code's `/hooks` menu once (forces a settings reload), or restart.

### What it does

- **Blocks**: any `podman rmi` / `podman image rm` / `podman image prune` whose command line mentions `vsc-content`. Covers the original filter pattern, the `grep vsc-content` variant, and other shapes that target DevPod-built images en masse.
- **Allows**: `podman rmi <image-id>` by the bare image ID; any `podman` command that isn't an rmi-class operation; everything unrelated to podman. **Note:** the pattern match is on the literal string `vsc-content`, so `podman rmi vsc-content-abcde:devpod-xxx` for one specific *tag* is still blocked even though it targets a single image — use the bare ID (`podman images` to look it up) to delete a specific image under this hook.
- **Escape hatch**: prefix the command with `DANGEROUS_CONFIRMED=1` to override the block when you really mean it. The block message tells the user this.
- **Output on block**: exits 2 with a stderr message listing safer alternatives (`devpod up <name> --reset` for single-workspace rebuilds, `podman images --filter` to inspect before delete, etc.). The agent sees the explanation and re-plans.

### Verify it's wired up

After install + restart:

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"podman images --filter \"reference=localhost/vsc-content-*\" -q | xargs podman rmi -f"}}' \
  | ~/.claude/hooks/block-vsc-content-bulk-rmi.sh
echo "rc=$?"   # should be 2
```

---

## Principles (do not violate)

1. **Host stays pristine.** No `rpm-ostree install` for dev tooling. Everything in `~/.local/bin`, Homebrew, or containers.
2. **Agent in container owns container config.** Host-authored `.devcontainer/` should be a deliberate minimal seed; the in-workspace agent extends it.
3. **No bind mounts of source.** Container clones the repo itself, uses worktrees internally for branch-per-task work.
4. **No broad-scope creds in container.** Lean on DevPod's credential injection for git; per-workspace login for tool-specific auth.
5. **Rebuild, don't repair.** When something breaks: `devpod delete WORKSPACE && devpod up git@github.com:OWNER/REPO.git --id WORKSPACE`. Don't debug a misbehaving container.

---

## Useful commands

```bash
devpod list                                # current workspaces
devpod up REPO --id REPO                   # start (or create) a workspace
devpod ssh REPO                            # interactive shell in
devpod stop REPO                           # stop without destroying
devpod delete REPO                         # destroy
devpod up REPO --recreate                  # rebuild container, keep source
devpod up REPO --reset                     # nuke everything, fresh clone

# Inspect / clean podman state:
podman ps -a --format "{{.Names}}\t{{.Status}}"
podman images
podman images --filter "reference=localhost/vsc-content-*" -q | xargs -r podman rmi -f

# Bazzite housekeeping:
ujust clean-system                         # purges old images/volumes
```

---

## Known gotchas (beyond the `/proc/acpi` saga)

- **Neither `--recreate` nor `--reset` forces a real image rebuild.** DevPod tags built images by a hash of the devcontainer.json/Dockerfile content and skips the build step entirely — logs `Found existing local image ...` — whenever an image with that tag already exists locally and no `--repository` is set (`pkg/driver/docker/build.go`: the cache-skip check is `options.Repository == "" && !options.ForceBuild`; neither `--recreate` nor `--reset` sets `ForceBuild`). So if the upstream base image (e.g. `mcr.microsoft.com/devcontainers/base:ubuntu`) has been updated but your devcontainer.json content hasn't changed, `--recreate`/`--reset` will keep running the same stale build indefinitely — `--reset` only additionally wipes and re-clones the git checkout, it does not touch the image cache. To force a genuine rebuild against fresh upstream layers: `podman pull` the base image first, then remove the locally cached hash-tagged image (`podman images --filter reference=localhost/vsc-content-*` to find it, `podman rmi <id>` on the *specific ID* — never the bulk wildcard form, see the guard hook above), then `devpod up <name> --recreate`. (There's also an undocumented, hidden `devpod build <name> --force-build` flag in the CLI source, marked `TESTING ONLY` and `MarkHidden` — it bypasses the cache check directly, but it's unsupported with no stability guarantee; the manual-evict approach above is the reliable path.) **Version note:** the `vsc-content-*` naming (and the guard hook's pattern match) is specific to 0.6.x — on current `main` the image-name builder was moved/changed and drops the `vsc-` prefix, so re-check the actual local tag with `podman images` before relying on the filter pattern after upgrading DevPod.
- **A devcontainer.json that loses `workspaceMount`'s `relabel=private` (i.e. `:Z`, not `:z`/`shared`) breaks with SELinux `Permission denied` — but only on the *next* recreate, not immediately.** Podman only relabels a bind-mounted host directory to a container-specific SELinux category (`:Z`/`relabel=private`) at mount time; `:z`/`relabel=shared` instead applies a bare, category-less label that every container's level dominates, so dropping *that* variant doesn't break anything — this gotcha is specific to the private/`:Z` form. An *already-running* container keeps working fine even if its devcontainer.json is later edited down to drop the option — it was labeled correctly back when it was created. The break surfaces on the next `--recreate`: the new container gets a fresh SELinux category, the host directory keeps its old one, and every file access starts failing with `Permission denied` despite correct Unix ownership/permissions (`postCreateCommand` then fails partway through, since it needs to read/write into the mount). SELinux denials don't show up as anything special in the podman log — same generic `Permission denied` errno; check `ausearch -m avc -ts recent` for the AVC if you want to confirm it's SELinux rather than a real ownership problem. Diagnose with `podman container inspect <name> --format '{{.MountLabel}}'` vs `ls -Zd <host-dir>` — a mismatched `cNNN,cNNN` category pair is the tell. Fix: restore `workspaceMount` with `relabel=private` in devcontainer.json and recreate; podman relabels the directory correctly on the next mount. (Converse trap: with `:Z`, two containers concurrently mounting the same host dir will fight over the label — the second one to start re-relabels it out from under the first.)
- **DevPod caches the cloned source under `~/.devpod/agent/contexts/default/workspaces/<id>/content/`** and `devpod delete` doesn't always wipe it. If your `devcontainer.json` changes don't seem to be picked up even after `--reset`, also `rm -rf` that directory and re-up.
- **DevPod 0.6.15 ignores `overrideFeatureInstallOrder`.** Don't rely on it; install dependent things via `postCreateCommand` instead of stacking features.
- **Do not use `${containerEnv:PATH}` substitution.** DevPod doesn't expand it to the image's default PATH — resolves to empty, wipes `/bin` and `/usr/bin`, crashes the container at start (DevPod's keep-alive `sleep` command fails).
- **DevPod's `--stdio` is the right primitive for SSH chaining.** Don't expose the container's sshd on a port.
- **Post-quantum SSH warning** on Remote-SSH from OpenSSH 10+ clients. Harmless for tailnet-only use; ignore.
- **In-container `sudo` works without configuration** in `mcr.microsoft.com/devcontainers/base:ubuntu` (and other MS devcontainer base images) — the `vscode` user has passwordless sudo pre-configured.
- **A long-lived tmux session can get truecolor rendering permanently wrong for a client that reconnects later.** tmux negotiates RGB/truecolor support against whichever client was attached when its *server* first started, and that negotiation sticks for the server's whole lifetime — even once a different, fully terminfo'd client (e.g. Ghostty) attaches to the same session afterward. Symptom: garbled/garbage characters, most visibly at the left margin where redraws and prompt lines land, because tmux emits truecolor SGR codes the currently-attached client was never told to expect. Fixed at the dotfiles level (see [Wire up dotfiles](#6-wire-up-dotfiles)) with an explicit `default-terminal`/`terminal-overrides` pair in `dotfiles/tmux.conf`, but that only takes effect for a *new* server — an already-running one needs `tmux kill-server` (drops all sessions) or, less disruptively, `tmux source-file ~/.tmux.conf` plus a detach/reattach of the affected client.
