# Running Codex unsandboxed inside devpod containers

## Symptom

The Claude Code `codex:` plugin starts a thread, authenticates fine, then every
shell command it tries to run is blocked before execution:

```
The first shell batch was blocked before any command ran (`bwrap` could not mount `devpts`).
```

Codex then falls back to web searches, which is useless for reviewing local code.

## Diagnosis

Codex CLI wraps every command it runs in a **bubblewrap** sandbox on Linux.
Inside this container bubblewrap cannot construct that sandbox. Reproduced
standalone, independent of Codex:

```bash
$ bwrap --dev-bind / / --dev /dev true
bwrap: Can't mount devpts on /newroot/dev/pts: Permission denied
```

Why it fails here:

| Check | Value | Verdict |
|---|---|---|
| `Seccomp` in `/proc/self/status` | `0` (no filter) | not the blocker |
| `CapBnd` | `0x800c05fb` — **no `CAP_SYS_ADMIN`** | blocker |
| `CapEff` | `0` (unprivileged `vscode` user) | blocker |
| SELinux context | `container_t` | blocker |
| `user.max_user_namespaces` | `2147483647` | fine, userns is allowed |

So user namespaces are permitted, but mounting `devpts` inside one needs
`CAP_SYS_ADMIN` and is additionally denied by the SELinux `container_t` policy.
This is a Podman + SELinux host (consistent with `relabel=private` on the
workspace mount).

Note the irony driving this request: **the container is already the isolation
boundary.** Codex's inner sandbox is redundant here, and it is the thing failing.

## Two ways to fix, and which to pick

### Option A — give the container what bubblewrap needs (recommended)

Add to `runArgs` in the devcontainer definition:

```json
"runArgs": [
  "--cap-add=SYS_ADMIN",
  "--security-opt", "label=disable"
]
```

- `--cap-add=SYS_ADMIN` restores the capability the `devpts` mount requires.
- `--security-opt label=disable` turns off SELinux labeling for the container
  (Podman). On a Docker + AppArmor host use `--security-opt apparmor=unconfined`
  instead; adding both is harmless if one doesn't apply.
- Blunt fallback if the above still fails: `--privileged`.

**Why this is the durable choice:** it fixes Codex, the plugin, and anything else
that wants bubblewrap, and it survives Codex and plugin upgrades with no
re-patching.

**Trade-off:** it weakens the container's isolation from the host. That is
usually acceptable for a disposable per-workspace devpod, but it is a real
reduction — `SYS_ADMIN` plus disabled SELinux labeling is close to privileged.

> Unverified: `runArgs` cannot be changed from inside a running container, so I
> could not test this. Verify with the smoke test below after a rebuild.

### Option B — turn Codex's own sandbox off

For **direct `codex` CLI use**, add to `~/.codex/config.toml`:

```toml
sandbox_mode = "danger-full-access"
approval_policy = "never"
```

`danger-full-access` is a valid mode in codex-cli 0.146.0 (confirmed in the
binary alongside `read-only` and `workspace-write`).

**This alone will not fix the Claude Code plugin.** The plugin's runtime passes
the sandbox mode explicitly as an app-server thread parameter on every turn,
which overrides `config.toml`:

| File (under `~/.claude/plugins/cache/openai-codex/codex/<ver>/`) | Line | Value |
|---|---|---|
| `scripts/lib/codex.mjs` (`buildThreadParams`, `buildResumeParams`) | 68, 81 | `sandbox: options.sandbox ?? "read-only"` |
| `scripts/codex-companion.mjs` (review) | 414 | `sandbox: "read-only"` |
| `scripts/codex-companion.mjs` (task) | 491 | `sandbox: request.write ? "workspace-write" : "read-only"` |

Making the plugin run unsandboxed therefore means patching those files after
install — and they are **overwritten on every plugin update**, so the patch has
to be re-applied from `postCreateCommand` and re-checked whenever the plugin
version bumps. That is why Option A is preferred.

> Unverified: I was blocked from running the experiment that would confirm the
> thread parameter beats `config.toml`. It is how explicit per-request params
> normally behave, but treat it as strongly expected rather than proven.

There is **no environment-variable escape hatch.** `CODEX_SANDBOX_NETWORK_DISABLED`
is a variable Codex *sets inside* its sandbox to inform the model; it is not a
control knob.

## What I would add to the devcontainer definition

```json
{
  "runArgs": [
    "--dns=1.1.1.1",
    "--dns=8.8.8.8",
    "--cap-add=SYS_ADMIN",
    "--security-opt", "label=disable"
  ],
  "postCreateCommand": "<existing command> && mkdir -p ~/.codex && printf 'sandbox_mode = \"danger-full-access\"\\napproval_policy = \"never\"\\n' >> ~/.codex/config.toml"
}
```

The `runArgs` change is what actually unblocks the plugin. The `postCreateCommand`
line is a belt-and-braces addition so the plain `codex` CLI also stops sandboxing
in an environment where the container is already the boundary.

If you keep a shared base devcontainer for all devpods, both changes belong
there rather than in each repo's `.devcontainer/devcontainer.json`.

## Verifying after a rebuild

```bash
bwrap --dev-bind / / --dev /dev true && echo BWRAP_OK
```

`BWRAP_OK` means Codex's sandbox can build and the plugin will run. If it still
prints the `devpts` error, escalate to `--privileged` to confirm the diagnosis,
then narrow back down.

End-to-end check:

```bash
node ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs \
  task --fresh "Run 'echo SANDBOX_PROBE_OK' and report its exact output."
```

## Addendum: what was actually shipped (2026-08-05)

The Option A fix above (`--cap-add=SYS_ADMIN` + `--security-opt label=disable`) was **not** used. An independent second opinion (run via `codex exec` itself, deliberately not told this report's conclusion going in) flagged it as too broad for a reference devcontainer: it's a real, ongoing reduction in the container's isolation from the host for every workspace that inherits it, not a one-time cost. It also correctly pointed out the narrower fix doesn't need any container privilege change at all — the plugin's own hardcoded sandbox strings are the actual blocker, not the container's capability set.

Web research then surfaced that this is a well-known, actively-tracked upstream issue — [openai/codex-plugin-cc#482](https://github.com/openai/codex-plugin-cc/issues/482), [#505](https://github.com/openai/codex-plugin-cc/issues/505), [#240](https://github.com/openai/codex-plugin-cc/issues/240) — with an open, tested fix already written: [openai/codex-plugin-cc#508](https://github.com/openai/codex-plugin-cc/pull/508) (`cubicj/codex-plugin-cc`, branch `config-driven-sandbox`). That PR makes the plugin properly defer to `sandbox_mode` in `~/.codex/config.toml` for task-mode runs, while deliberately keeping code review pinned to `read-only` (an important distinction this report's own Option B glossed over — blanket-patching every hardcoded `"read-only"` string, as an earlier draft of this fix did, would have silently made review write-capable too). It also adds a fail-closed check that errors out if a resumed thread ever ends up write-capable when read-only was requested.

Diff reviewed line-by-line before use: no network calls, no credential access, adds 10+ new/modified tests, author account is several years old with a real commit history. Not yet merged upstream as of this writing.

**What's actually installed** (see `hapi`'s devcontainer.json for the exact commands): the codex plugin is installed from `cubicj/codex-plugin-cc`, pinned to the exact reviewed commit (`e5ce2723f7a174ba6b616c84ef8abb1771b2471e`, not the branch — immune to force-push) via a manual `git clone` + `checkout` + local-path marketplace registration, since `claude plugin marketplace add owner/repo#<ref>` only resolves branch/tag refs, not arbitrary commit SHAs. `~/.codex/config.toml` gets `sandbox_mode = "danger-full-access"` for the bare CLI, written idempotently (a guard checks for the key first — the original Option B snippet's repeated `>>` would have produced duplicate, TOML-breaking keys on every rebuild, also caught by the second-opinion review).

No `runArgs` changes. No SELinux changes. Verified end-to-end live before persisting anything: `node .../codex-companion.mjs task --fresh "echo SANDBOX_PROBE_OK"` actually executes and returns output.

**Revisit when** [openai/codex-plugin-cc#508](https://github.com/openai/codex-plugin-cc/pull/508) merges upstream — switch back to installing from `openai/codex-plugin-cc` directly and drop the pinned-fork step.
