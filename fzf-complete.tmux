#!/usr/bin/env bash
#
# tmux key binding for completing things into the current pane with fzf
#
# Add this line to your ~/.tmux.conf
#
#   run-shell ~/github/tmux-fzf-complete/fzf-complete.tmux
#
# Options, set before run-shell:
#
#   set -g @fzf-complete-bind C-t       # Key to press after the prefix key
#   set -g @fzf-complete-popup 90%,70%  # Size of the fzf pane (width,height)
#   set -g @fzf-complete-lines 10000    # Lines of the pane to scan

script=$(dirname "${BASH_SOURCE[0]:-$0}")/fzf-complete.rb
script=$(readlink -f "$script" 2> /dev/null || /usr/bin/ruby --disable-gems -e 'puts File.expand_path(ARGV.first)' "$script" 2> /dev/null)

[[ -x $script ]] || { tmux display-message "fzf-complete.rb not found"; exit 1; }

key=$(tmux show-option -gqv @fzf-complete-bind)

# tmux expands formats in a run-shell command, so '#' has to be doubled there
quoted="'${script//\'/\'\\\'\'}'"
quoted=${quoted//#/##}

tmux bind-key "${key:-C-t}" run-shell -b "TMUX_PANE=#{pane_id} $quoted files"
