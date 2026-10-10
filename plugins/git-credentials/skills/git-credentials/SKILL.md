---
description: >-
  TRIGGER whenever, inside a DevPod devcontainer on this host: a git push/pull/fetch fails with an
  authentication error ("could not read Username", "Permission denied (publickey)", "dial tcp ...
  connect: connection refused" from a git credential helper, HTTP 401/403 on a git remote); a `gh`
  command fails because it's not authenticated or not installed; you're about to do your first git
  operation in a freshly created or freshly rebuilt workspace and want to avoid hitting this cold;
  or the user asks why git/gh credentials "aren't working" in this container. SKIP if the failure is
  a normal git error unrelated to auth (merge conflict, detached HEAD, etc.) or if you're not running
  inside a DevPod-managed devcontainer at all.
---

# DevPod git/gh credentials

You're inside a DevPod devcontainer. Credentials are injected automatically — you should never need
to ask the user for a token, generate one, or read any key/credential file to make git or `gh` work.
If you find yourself about to do any of those, stop and re-read this instead.

## How it actually works

DevPod installs a `credential.helper` in the container's git config that proxies `git credential
fill` calls back to the *host's* authenticated git/gh, over the same channel that carries the SSH
session. This is HTTPS-only, and — this is the part that's easy to miss — **it only works inside a
process tree that was started by `devpod ssh`** (interactively, via `devpod ssh --command "..."`, or
via an IDE's Remote-SSH connection that itself shells out to `devpod ssh --stdio`). A bare shell
attached to the container by any other means (e.g. the container runtime's own exec mechanism,
bypassing DevPod's SSH layer entirely) does **not** have this forwarding available, even though it
looks like an ordinary shell in the same container. The same is true of SSH-agent forwarding.

So: "credentials broken" inside a DevPod devcontainer usually isn't actually broken — it's that the
current process isn't running inside a `devpod ssh`-derived session. This is *the* first thing to
check, before anything else.

## Diagnostic checklist, in order

1. **Are you in a `devpod ssh` session?** If you got here via anything other than an interactive
   `devpod ssh <workspace>`, a `devpod ssh <workspace> --command "..."`, or an IDE connected through
   the documented `devpod ssh --stdio` ProxyCommand — that's very likely the whole problem. Reconnect
   through one of those paths and retry before doing anything else.
2. **Is the remote HTTPS, not SSH?** `git remote -v`. If it shows `git@github.com:...` or
   `ssh://...`, the credential helper won't apply — SSH-agent forwarding is not available to
   non-interactive/scripted git operations even inside a valid `devpod ssh` session. Fix once per
   repo checkout:
   ```
   git remote set-url origin https://github.com/<owner>/<repo>.git
   ```
3. **Confirm the helper is wired in**: `git config --get-regexp credential` should show a
   `credential.helper` pointing at the `devpod` binary. If it's missing entirely, this workspace's
   devcontainer.json likely predates `SSH_INJECT_GIT_CREDENTIALS` being enabled, or credential
   injection was explicitly disabled — that's a devcontainer/host config issue, not something to work
   around from inside the container.
4. **`gh` uses the same credential, passed per command.** `gh` doesn't read the git credential
   helper on its own, but it doesn't need its own login either: hand it the helper's token inline.
   ```
   GH_TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | sed -n 's/^password=//p') gh pr create ...
   ```
   This acts as the host's GitHub account (the bot account), like `git push` does. Prefix each `gh`
   command this way; don't `export` the token, write it to a file or print it. **Don't run `gh auth
   login`**: its device flow links whatever account the user's browser is signed in to, usually their
   personal one, so your PRs and comments would come from the wrong account. If the token comes back
   empty, it's step 1 (not a `devpod ssh` session). If `gh` isn't installed, that's a missing tool,
   not a broken credential — install it.
5. **Test without assuming**: `git fetch`/`git ls-remote` succeeding is *not* evidence that push will
   work if the target repo is public — anonymous, unauthenticated requests succeed for public repos
   over both git and the GitHub API (60 req/hour unauthenticated). Use `git push --dry-run` against a
   real branch name to actually exercise the credential path without side effects.

## What never to do here

- Never read, print, or search for SSH private keys, `~/.ssh/id_*`, token env vars, or any
  credential/config file's raw contents as a way to "figure out" what's wrong. Every check above uses
  `git config`, `git remote -v`, and dry-run git commands — none of which touch a secret. If none of
  those explain the failure, report what you found and stop; don't escalate to reading secrets.
- Never ask the user to paste a personal access token or API key into the session. If you've reached
  this point, the fix is almost always "reconnect via `devpod ssh`" — not a manually-supplied credential.
