#!/usr/bin/env ruby
# frozen_string_literal: true

# Completes things into the current tmux pane with fzf
#
#   fzf-complete.rb [PROVIDER]            Start the finder
#   fzf-complete.rb list STATE            Print the items of a provider
#   fzf-complete.rb switch STATE TARGET   Change the provider in use
#
# The last two are run by fzf itself, so that switching a provider reloads the
# list instead of closing the pane fzf runs in. STATE is the file the provider
# in use is kept in, as a key binding cannot carry it.

require 'English'
require 'shellwords'
require 'tempfile'

PROVIDERS = %w[files dirs urls paths sentences].freeze
QUOTED = %w[files dirs paths].freeze
# Providers whose items CTRL-O can open
OPENABLE = %w[files dirs urls paths].freeze

def halt(message = nil)
  system "tmux display-message #{Shellwords.escape(message)}" if message
  exit
end

def tmux(command)
  `tmux #{command}`
end

def display(format)
  tmux("display-message -p -t #{PANE} #{Shellwords.escape(format)}").chomp
end

def option(name, default)
  value = tmux("show-option -gqv #{name}").chomp
  value.empty? ? default : value
end

def executable(*commands)
  commands.find { |c| `command -v #{c.split.first.shellescape}`.empty?.! }
end

# Pipe into a command, and take its output. Straight from tmux-fzf-url.
def with(command)
  io = IO.popen(command, 'r+')
  begin
    stdout = $stdout
    $stdout = io
    begin
      yield
    rescue Errno::EPIPE
      nil
    end
  ensure
    $stdout = stdout
  end
  io.close_write
  io.readlines.map(&:chomp)
end

# Columns a character occupies. tmux counts columns, so the characters in
# front of the cursor cannot simply be counted.
WIDE = [
  0x1100..0x115F, 0x2E80..0x303E, 0x3041..0x33FF, 0x3400..0x4DBF,
  0x4E00..0x9FFF, 0xA000..0xA4CF, 0xAC00..0xD7A3, 0xF900..0xFAFF,
  0xFE30..0xFE6F, 0xFF00..0xFF60, 0xFFE0..0xFFE6, 0x1F300..0x1F64F,
  0x1F680..0x1F6FF, 0x1F900..0x1F9FF, 0x20000..0x3FFFD
].freeze

def char_columns(char)
  code = char.ord
  return 0 if code.zero? || code == 0x200D || (0x0300..0x036F).cover?(code)

  WIDE.any? { |range| range.cover?(code) } ? 2 : 1
end

def columns(string)
  # Nothing is wider than one column when there is no character above ASCII
  return string.length if string.ascii_only?

  string.each_char.sum { |char| char_columns(char) }
end

def up_to_column(string, column)
  used = 0
  string.each_char.take_while { |char| (used += char_columns(char)) <= column }.join
end

# The indentation and the decorations a program draws in front of its text
DECORATION = /\A(?:[⏺❯⎿│┃●○•▌↳⏵✻]+\s*|[*>+-]\s+)/
BOX = /[─━│┃╭╮╰╯┌┐└┘├┤┼┬┴▌▐▏▕]/

def undecorate(text)
  text = text.lstrip
  text = text.sub(DECORATION, '').lstrip while text.match?(DECORATION)
  text
end

def clean(text)
  text.gsub(BOX, ' ').squeeze(' ').strip
end

# A program may pad its output with a character like the no-break space, which
# Ruby does not count as whitespace, so every blank is made a plain space. The
# columns each of them takes stay the same.
def normalize(text)
  text.gsub(/[[:space:]&&[^\t]]/, ' ')
end

# Resolved before the working directory changes, as fzf starts this script
# again to switch a provider and to reload a list
SCRIPT = File.realpath(__FILE__)

PANE = ENV.fetch('TMUX_PANE', nil)
halt 'TMUX_PANE is not set' if PANE.nil? || PANE.empty?

# --- What the pane holds --------------------------------------------------

def rows
  @rows ||=
    tmux("capture-pane -p -J -N -S -#{option('@fzf-complete-lines', '10000')} -t #{PANE}")
    .lines.map { |line| normalize(line.chomp) }
end

# Index of the row the cursor is on. cursor_y counts from the top of the
# screen, while the rows start with the history.
def cursor_row
  height = display('#{pane_height}').to_i
  cursor_y = display('#{cursor_y}').to_i
  [[rows.size - height + cursor_y, 0].max, rows.size].min
end

def rows_above
  rows[0...cursor_row]
end

def rows_below
  rows[(cursor_row + 1)..] || []
end

# The row the cursor is on and the rows below it come last. A program with an
# input box at the bottom draws its chrome there, while the output worth
# completing from is right above the cursor.
def screen
  @screen ||= rows_above.reverse + rows_below
end

# Lazy, so that a check for the first item does not walk the whole screen
def screen_words
  screen.lazy.flat_map(&:split)
        .map { |word| word.gsub(/\A['"`(\[{<]+|['"`)\]},;:.]+\z/, '') }
        .select { |word| word.match?(/[[:alnum:]]/) }
end

# The text of the pane as paragraphs. A row whose text reaches the right edge
# was wrapped by the program, so it is joined with the row that follows.
def paragraphs(source)
  width = display('#{pane_width}').to_i
  buffer = nil
  source.each_with_object([]) do |raw, out|
    raw = raw.rstrip
    text = undecorate(raw)
    if text.empty?
      out << buffer if buffer
      buffer = nil
      next
    end
    buffer = buffer ? "#{buffer} #{text}" : text
    next if columns(raw) >= width - 8

    out << buffer
    buffer = nil
  end.tap { |out| out << buffer if buffer }
end

# --- The providers --------------------------------------------------------

# The directory part of the query is where the search starts, and the rest of
# it is left to fzf to match with
def split_query(query)
  base, _, = query.rpartition('/')
  base += '/' unless base.empty?
  [base, expand_tilde(base.chomp('/'))]
end

# The command of fzf for its own CTRL-T and ALT-C bindings, when it is set
def lister(dirs)
  command = ENV.fetch(dirs ? 'FZF_ALT_C_COMMAND' : 'FZF_CTRL_T_COMMAND', '')
  return command unless command.empty?

  type = dirs ? 'd' : 'f'
  if (fd = executable('fd', 'fdfind'))
    "#{fd} --type #{type} --hidden --follow --exclude .git --exclude node_modules"
  else
    "find -L . \\( -name .git -o -name node_modules \\) -prune -o -type #{type} -print"
  end
end

# Printed as they are found, and not collected first, so that a directory as
# large as the home directory shows up in fzf right away. The command runs in
# the directory the query names, and the base is put back in front of what it
# prints, which is what keeps the ~ the query was written with.
def print_paths(query, dirs)
  base, root, = split_query(query)
  root = '.' if root.empty?
  return unless File.directory?(root)

  IO.popen("#{lister(dirs)} 2> /dev/null", chdir: root) do |io|
    io.each_line do |line|
      item = line.chomp.delete_prefix('./')
      next if item.empty?

      item = item.sub(%r{/*\z}, '/') if dirs
      puts "#{base}#{item}"
    end
  end
end

URL = %r{(?:https?|ftp|file|ssh|git)://[^\s<>|"'`]+}

def urls
  screen.flat_map { |line| line.scan(URL).map { |url| url.sub(/[)'"`\]},;:.!?]+\z/, '') } }.uniq
end

def expand_tilde(path)
  return Dir.home if path == '~'

  path.start_with?('~/') ? File.join(Dir.home, path.delete_prefix('~/')) : path
end

# A word is offered as a path only when it is one, which is what tells a real
# name from something shaped like it, such as 12/12 or v2.42.0. A line number
# after it, as in the output of a compiler, is dropped.
def path_candidates
  screen_words.reject { |word| word.include?('://') }
              .map { |word| word.sub(/:\d+(?::\d+)?\z/, '') }
              .reject { |word| word.length < 2 || %w[.. ~/].include?(word) }
end

def screen_paths
  path_candidates.select { |word| File.exist?(expand_tilde(word)) }.uniq.to_a
end

def sentence?(line)
  text = clean(undecorate(line))
  text.match?(/[[:alpha:]]/) && text.include?(' ')
end

def sentences
  (paragraphs(rows_above).reverse + paragraphs(rows_below))
    .map { |para| clean(para) }
    .flat_map { |para| para.split(/(?<=[.!?])\s+(?=["'(\[]?[A-Z])/) }
    .select { |line| line.match?(/[[:alpha:]]/) && line.include?(' ') }
    .uniq
end

def print_items(provider, query)
  case provider
  when 'files' then print_paths(query, false)
  when 'dirs'  then print_paths(query, true)
  when 'urls'  then puts urls
  when 'paths' then puts screen_paths
  else              puts sentences
  end
end

# --- How the finder looks -------------------------------------------------

def viewer
  @viewer ||=
    executable('bat', 'batcat')
    &.then { |bat| "#{bat} --style=#{ENV.fetch('BAT_STYLE', 'numbers')} --color=always --pager=never" } ||
    'cat'
end

# An action argument ends at a parenthesis, so a label cannot hold one
def label(provider, query)
  base, = split_query(query)
  case provider
  when 'files'     then "📄 Files in #{base.empty? ? '.' : base.tr('()', '')} "
  when 'dirs'      then "📁 Directories in #{base.empty? ? '.' : base.tr('()', '')} "
  when 'urls'      then '🔗 URLs on screen '
  when 'paths'     then '📂 Paths on screen '
  when 'sentences' then '📝 Sentences on screen '
  end
end

# A path is offered with ~ in place of the home directory, and fzf quotes what
# it puts in place of {}, so the preview command has to expand it itself
TILDE = 'f={}; f=${f/#\~/$HOME};'

def preview(provider)
  case provider
  when 'files' then %(#{TILDE} [ -f "$f" ] && #{viewer} "$f" || ls -F "$f")
  when 'dirs'  then %(#{TILDE} ls -F "$f")
  when 'paths' then %(#{TILDE} [ -f "$f" ] && #{viewer} "$f" || ls -F "$f" 2> /dev/null)
  end
end

# Whether a provider has anything to offer. It stops at the first item, instead
# of building a list that may be thrown away.
def available?(provider)
  case provider
  when 'urls'      then screen.any? { |line| line.match?(URL) }
  when 'paths'     then path_candidates.any? { |word| File.exist?(expand_tilde(word)) }
  when 'sentences' then screen.any? { |line| sentence?(line) }
  else true
  end
end

def active_providers
  PROVIDERS.select { |name| available?(name) }
end

# The providers, with the letter that switches to each of them underlined. The
# one in use is bold, the rest are dimmed.
def header(current, providers)
  keys = ' · ALT+letter · CTRL-T next'
  keys += ' · CTRL-O open' if OPENABLE.include?(current)
  keys += ' · CTRL-R reload'
  providers.map do |name|
    text = "\e[4m#{name[0]}\e[24m#{name[1..]}"
    "#{current == name ? "\e[1m" : "\e[2m"}#{text}\e[22m"
  # The keys come last, as the header is truncated when a preview is shown
  end.join(' ') + "\e[2m#{keys}\e[22m"
end

def next_provider(current, providers)
  providers[(providers.index(current) + 1) % providers.length]
end

# The provider in use, and the ones to offer
def read_state(path)
  current, providers = File.read(path).lines.map(&:strip)
  [current, providers.split]
end

def write_state(path, current, providers)
  File.write(path, "#{current}\n#{providers.join(' ')}\n")
end

# --- Run as a child of fzf -----------------------------------------------

case ARGV.first
when 'open-action'
  # Nothing is printed for a provider whose items cannot be opened, so that
  # CTRL-O does not run a process and make fzf flicker for nothing
  current, = read_state(ARGV[1])
  puts "execute(#{SCRIPT.shellescape} open #{ARGV[1].shellescape} {})" if OPENABLE.include?(current)
  exit
when 'open'
  # CTRL-O, which fzf runs with the tty, so an editor can take the pane over
  current, = read_state(ARGV[1])
  item = ARGV[2].to_s
  exit if item.empty?

  if current == 'urls'
    opener = executable('open', 'xdg-open')
    halt 'No command to open a URL with' unless opener

    system("#{opener} #{item.shellescape} > /dev/null 2>&1")
  else
    system("#{ENV.fetch('EDITOR', 'vim')} #{expand_tilde(item).shellescape}")
  end
  exit
when 'list'
  current, = read_state(ARGV[1])
  print_items(current, ENV.fetch('FZF_QUERY', ''))
  exit
when 'switch'
  state = ARGV[1]
  current, providers = read_state(state)
  provider =
    case ARGV[2]
    when 'next' then next_provider(current, providers)
    when 'same' then current
    else ARGV[2]
    end
  exit unless providers.include?(provider)

  write_state(state, provider, providers)

  actions = ["change-border-label(#{label(provider, ENV.fetch('FZF_QUERY', ''))})",
             "change-header(#{header(provider, providers)})"]
  actions +=
    if (command = preview(provider))
      ["change-preview(#{command})", 'change-preview-window(right,50%)']
    else
      ['change-preview-window(hidden)']
    end
  # The list is reloaded in place, so the pane fzf runs in stays open, and the
  # cursor goes back to the top as the items are not the same
  actions << "reload(#{SCRIPT.shellescape} list #{state.shellescape})" << 'first'
  puts actions.join('+')
  exit
end

# --- Start the finder -----------------------------------------------------

provider = ARGV.first || PROVIDERS.first
halt "Unknown provider: #{provider}" unless PROVIDERS.include?(provider)

# Run in the working directory of the pane
pane_path = display('#{pane_current_path}')
Dir.chdir(pane_path) if File.directory?(pane_path)

# The word in front of the cursor, which the selection replaces. Taken from
# the screen, as the pane may be running any program. -N keeps the trailing
# spaces, without which the cursor column would point past the end of the row.
cursor_x = display('#{cursor_x}').to_i
cursor_y = display('#{cursor_y}').to_i
row = normalize(tmux("capture-pane -p -N -t #{PANE} -S #{cursor_y} -E #{cursor_y}").chomp)
before = up_to_column(row, cursor_x)
# The row ends before the cursor when the cell in front of it is blank, and a
# blank cell is not part of any word
TOKEN = columns(before) < cursor_x ? '' : before[/[^[:space:]]*\z/].to_s

providers = active_providers
state = Tempfile.new('fzf-complete')
state.close
write_state(state.path, provider, providers)

options = ['--tmux', option('@fzf-complete-popup', '90%,70%'),
           '--multi', '--layout', 'reverse', '--min-height', '10+',
           '--no-separator', '--header-border', 'horizontal',
           '--border-label-pos', '2', '--color', 'label:blue',
           '--highlight-line', '--preview-border', 'line', '--wrap',
           # The preview and the child commands below are bash
           '--with-shell', 'bash -c',
           '--bind', 'ctrl-/:change-preview-window(down,50%|hidden|)',
           '--border-label', label(provider, TOKEN),
           '--header', header(provider, providers),
           '--query', TOKEN]
options += if (command = preview(provider))
             ['--preview', command, '--preview-window', 'right,50%']
           else
             ['--preview-window', 'hidden']
           end
# CTRL-T goes to the next provider, so that it can be pressed repeatedly
options += ['--bind', "ctrl-t:transform(#{SCRIPT.shellescape} switch #{state.path.shellescape} next)"]
# CTRL-O opens the item, and fzf comes back afterwards
options += ['--bind', "ctrl-o:transform(#{SCRIPT.shellescape} open-action #{state.path.shellescape})"]
# CTRL-R lists again, from the directory in the query, or from the pane as it
# is now
options += ['--bind', "ctrl-r:transform(#{SCRIPT.shellescape} switch #{state.path.shellescape} same)"]
providers.each do |name|
  options += ['--bind',
              "alt-#{name[0]}:transform(#{SCRIPT.shellescape} switch #{state.path.shellescape} #{name})"]
end

selected = with("fzf #{options.map(&:shellescape).join(' ')}") { print_items(provider, TOKEN) }
quoted = QUOTED.include?(read_state(state.path).first)
state.unlink

exit if selected.empty?

def shell_quote(item)
  return item if item.match?(%r{\A[A-Za-z0-9_@%+=:,./~-]+\z})

  "'#{item.gsub("'", %q('\\''))}'"
end

text = selected.map { |item| quoted ? shell_quote(item) : item }.join(' ')

# Replace the word in front of the cursor with the text
if !TOKEN.empty? && text.start_with?(TOKEN)
  # Nothing to delete when the text extends the word
  text = text[TOKEN.length..]
elsif !TOKEN.empty?
  tmux("send-keys -t #{PANE} -N #{TOKEN.length} BSpace")
end
system('tmux', 'send-keys', '-t', PANE, '-l', '--', text) unless text.empty?
