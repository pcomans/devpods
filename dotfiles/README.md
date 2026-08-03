# dotfiles

Bootstrap run by [DevPod](https://devpod.sh) inside every workspace container.
Part of [devpods](..) — see [Wire up dotfiles](../README.md#6-wire-up-dotfiles)
in the main README for the `devpod context set-options` wiring.

DevPod clones this repo to `~/dotfiles` in the container (via `DOTFILES_URL`)
and runs the script named by `DOTFILES_SCRIPT` — `dotfiles/install.sh`, since
it's nested here rather than at repo root — on every `devpod up`, as that
workspace's remote user. It runs independently of `devcontainer.json`, so
workspaces on stock fallback images are covered too.

## What it does

### `xterm-ghostty` terminfo

Ghostty ships its own terminfo entry that is **not** in the Debian/Ubuntu
ncurses database — `ncurses-term` does not carry it, and upstream ncurses only
has the entry under the name `ghostty`, not `xterm-ghostty`. So a Ghostty user
SSHing into a container gets an unresolvable `TERM` and everything TERM-aware
breaks:

```
$ tmux a
missing or unsuitable terminal: xterm-ghostty
```

`terminfo/xterm-ghostty.terminfo` is dumped from
`Ghostty.app/Contents/Resources/terminfo` via `infocmp -x`. It is
self-contained — all `use=` references are resolved — so it compiles on any
ncurses host. `install.sh` compiles it into `$HOME/.terminfo`, which needs no
root and survives image rebuilds.

`terminfo/compiled/x/xterm-ghostty` is the precompiled form, used as a fallback
for images that somehow lack `tic`.

Setting `TERM=xterm-256color` would also stop the error, but it lies about the
terminal and gives up Ghostty's extended capabilities — styled underlines
(`Smulx`), colored underlines (`Setulc`), and others that tmux and neovim probe
via terminfo.

### `tmux.conf`

`install.sh` also drops `tmux.conf` at `$HOME/.tmux.conf` (skipped if one
already exists there and isn't ours — marked with a `# dotfiles: managed`
first line so re-runs can tell).

Without it, tmux only gets truecolor/RGB right for whichever client was
attached when its *server* first started — that negotiation sticks for the
server's entire lifetime, even once a properly terminfo'd Ghostty client
attaches to the same long-lived session later. Symptom: garbled/garbage
characters, often right at the left margin where redraws and prompt lines
land, because tmux emits truecolor SGR codes the attached client was never
told to expect. `tmux.conf` fixes this by being explicit regardless of
server-start-time negotiation:

```tmux
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-ghostty:RGB,xterm-256color:RGB"
```

If you're already hitting this in a long-lived session, the config alone
won't fix an already-running server — kill it (`tmux kill-server`) so the
next attach renegotiates fresh, or `devpod up <workspace> --recreate`.

## Gotchas

DevPod skips the clone if `~/dotfiles` already exists, and it does **not**
`git pull` — only `install.sh` re-runs. Changes pushed here reach existing
containers only after `rm -rf ~/dotfiles` followed by `devpod up`, or a
workspace recreate — the whole `devpods` repo gets re-cloned to `~/dotfiles`
in that case, not just this subdirectory.

Because of that, keep every step in `install.sh` idempotent.
