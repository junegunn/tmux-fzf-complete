tmux-fzf-complete
=================

Makes the <kbd>CTRL-T</kbd> of [fzf][fzf] available in every tmux pane.

<kbd>CTRL-T</kbd> completes a file path, but only on the command line of a
shell. Bound as a tmux key instead, it works whatever the pane is running, and
completes more than files. The selection is sent to the pane as key strokes, so
an editor or an interactive AI agent takes it as typed.

[fzf]: https://github.com/junegunn/fzf

Installation
------------

* [fzf][fzf] 0.74.0 or later, and Ruby
* (Optional) [fd](https://github.com/sharkdp/fd) to list files with, and
  [bat](https://github.com/sharkdp/bat) for file previews

Install the plugin with [TPM][tpm],

```sh
# ~/.tmux.conf
set -g @plugin 'junegunn/tmux-fzf-complete'
```

or run `fzf-complete.tmux` from your .tmux.conf yourself, with
`fzf-complete.rb` next to it.

```sh
# ~/.tmux.conf
run-shell ~/github/tmux-fzf-complete/fzf-complete.tmux
```

[tpm]: https://github.com/tmux-plugins/tpm

Usage
-----

<kbd>PREFIX</kbd><kbd>CTRL-T</kbd> starts the file finder in a floating pane, in
the working directory of the pane, or in a popup on tmux 3.6 or older. The word
in front of the cursor becomes the query, and the selection replaces it.

```
~/github/fzf-g      ->      ~/github/fzf-git.sh/README.md
```

Inside fzf, <kbd>CTRL-T</kbd> goes to the next provider, and these keys switch
to one directly. <kbd>CTRL-O</kbd> opens what is under the cursor, a URL in the
browser and anything else in `$EDITOR`, and comes back to the finder after.
<kbd>CTRL-R</kbd> lists again, from the directory in the query, or from the pane
as it is now. The header is a row of labels, so clicking one of them does what it
says.

| Key | Provider | |
| --- | -------- | - |
| <kbd>ALT-F</kbd> | Files | the search starts at the directory in the query |
| <kbd>ALT-D</kbd> | Directories | |
| <kbd>ALT-U</kbd> | URLs | on the screen |
| <kbd>ALT-P</kbd> | Paths | on the screen |
| <kbd>ALT-S</kbd> | Sentences | on the screen |

Paths are the words on the screen that exist as a path, with a line number
after them dropped. Sentences are the text of the pane without its indentation,
with the rows the program wrapped joined back together, which is what makes the
output of an AI agent usable. A provider that finds nothing is not offered.

Paths are quoted when they are inserted, prose is not.

Options
-------

Set them before the plugin is loaded, which with TPM is above the line that
runs it.

| Option                | Description                         | Default   |
| --------------------- | ----------------------------------- | --------- |
| `@fzf-complete-bind`  | Key to press after the prefix key   | `C-t`     |
| `@fzf-complete-popup` | Size of the fzf pane (width,height) | `90%,70%` |
| `@fzf-complete-lines` | Lines of the pane to scan           | `10000`   |

Files and directories come from `$FZF_CTRL_T_COMMAND` and `$FZF_ALT_C_COMMAND`
when those are set, as in the shell integration of fzf, and from `fd` or `find`
otherwise. Set them with `set-environment -g`, as the plugin does not read your
shell configuration file.

A provider can be bound to a key of its own as well.

```sh
bind-key u run-shell -b "TMUX_PANE=#{pane_id} \
  ~/github/tmux-fzf-complete/fzf-complete.rb urls"
```

> [!NOTE]
> A program that draws a full screen, such as an AI agent, keeps no scrollback
> in tmux, so only what is on the screen can be completed from.

See also
--------

[fzf-git.sh][fzf-git] does the same for Git objects, with its own tmux bindings
under <kbd>PREFIX</kbd><kbd>g</kbd>.

[fzf-git]: https://github.com/junegunn/fzf-git.sh
