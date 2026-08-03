#!/bin/sh
# DevPod dotfiles bootstrap.
#
# DevPod runs this inside every workspace container on `devpod up`, as that
# workspace's remote user (vscode on some, node on others -- hence $HOME
# rather than a hardcoded path). It runs regardless of whether the repo has
# a devcontainer.json, so it also covers stock fallback images.
#
# DevPod re-runs this on every `up` without re-pulling the repo, so keep every
# step idempotent and cheap.
set -eu

cd "$(dirname "$0")"

# Ghostty ships its own terminfo entry and it is not in the Debian/Ubuntu
# ncurses database -- `ncurses-term` does not carry it, and upstream ncurses
# only has it under the name `ghostty`, not `xterm-ghostty`. Without this,
# TERM=xterm-ghostty is unresolvable in the container and everything
# TERM-aware dies:
#
#     $ tmux a
#     missing or unsuitable terminal: xterm-ghostty
#
# Installing under $HOME/.terminfo needs no root and survives image rebuilds.
install_ghostty_terminfo() {
	if command -v tic >/dev/null 2>&1; then
		tic -x -o "$HOME/.terminfo" terminfo/xterm-ghostty.terminfo
	elif [ -f terminfo/compiled/x/xterm-ghostty ]; then
		# No tic in this image; drop the precompiled entry in place instead.
		mkdir -p "$HOME/.terminfo/x"
		cp terminfo/compiled/x/xterm-ghostty "$HOME/.terminfo/x/xterm-ghostty"
	else
		echo "dotfiles: no tic and no precompiled entry, skipping terminfo" >&2
		return 0
	fi
	echo "dotfiles: installed xterm-ghostty terminfo to $HOME/.terminfo"
}

install_ghostty_terminfo

# Without an explicit default-terminal/terminal-overrides pair, tmux only
# gets truecolor/RGB right for the client attached when its *server* first
# started -- a negotiation that sticks for the server's whole lifetime, even
# once a properly terminfo'd Ghostty client attaches later. See tmux.conf for
# the full explanation; this just needs to land at $HOME/.tmux.conf, and only
# if the user hasn't already got one of their own.
install_tmux_conf() {
	if [ -f "$HOME/.tmux.conf" ] && ! grep -q "dotfiles: managed" "$HOME/.tmux.conf" 2>/dev/null; then
		echo "dotfiles: ~/.tmux.conf already exists and isn't ours, leaving it alone" >&2
		return 0
	fi
	{
		echo "# dotfiles: managed, see pcomans/devpods dotfiles/tmux.conf"
		cat tmux.conf
	} > "$HOME/.tmux.conf"
	echo "dotfiles: installed tmux.conf to $HOME/.tmux.conf"
}

install_tmux_conf
