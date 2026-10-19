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
require 'set'
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

# What a program draws its interface with, and never a part of a word: bullets
# and angle quotes, arrows, technical and geometric shapes, dingbats, braille,
# the private use area where the glyphs of a patched font live, and emoji
# /x would not leave a space out of a character class, so this stays on one line
DECORATION = /[\u2022\u2039\u203A\u2190-\u21FF\u2300-\u23FF\u2500-\u25FF\u2600-\u27BF\u2800-\u28FF\u{E000}-\u{F8FF}\u{1F300}-\u{1FAFF}]/
# The same, and the indentation, in front of the text of a row
LEADING = /\A(?:#{DECORATION}+[[:space:]]*|[*>+-][[:space:]]+)/

def undecorate(text)
  text = text.lstrip
  text = text.sub(LEADING, '').lstrip while text.match?(LEADING)
  text
end

# The vertical bar a program draws in front of every row of a quote
QUOTE = /\A[[:space:]]*(?:[>\u2502\u2503\u2506\u2507\u250A\u250B\u254E\u254F\u2551\u2589-\u258F][[:space:]]*)+/

# A row that starts with a bullet starts an item, and never continues one
def marker?(row)
  row.sub(QUOTE, '').lstrip.match?(LEADING)
end

# The column the text of a row begins at, past its indentation and bullet
def text_column(row, text)
  columns(row) - columns(text)
end

def clean(text)
  text.gsub(DECORATION, ' ').squeeze(' ').strip
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

# --- What the pane holds --------------------------------------------------

def capture(flags)
  tmux("capture-pane -p #{flags} -J -N -S -#{option('@fzf-complete-lines', '10000')} -t #{PANE}").lines
end

# The rows with the escape sequences of their colors and hyperlinks, which the
# preview shows. The text of the rows comes from the same capture, so that the
# two cannot differ.
def escaped_rows
  @escaped_rows ||= capture('-e').map(&:chomp)
end

def rows
  @rows ||= escaped_rows.map { |row| normalize(row.gsub(ESCAPE, '')) }
end

# Index of the row the cursor is on. cursor_y counts from the top of the
# screen, while the rows start with the history.
def cursor_row
  @cursor_row ||= begin
    height = display('#{pane_height}').to_i
    cursor_y = display('#{cursor_y}').to_i
    [[rows.size - height + cursor_y, 0].max, rows.size].min
  end
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
def screen_indices
  @screen_indices ||= (0...cursor_row).to_a.reverse + ((cursor_row + 1)...rows.size).to_a
end

def screen
  @screen ||= screen_indices.map { |index| rows[index] }
end

# The punctuation a word can be written in the middle of is not part of it,
# and neither is a name in front of a parenthesis that the word does not close,
# as in Read(README.md)
def trim(word)
  word.gsub(/\A['"`(\[{<]+|['"`)\]},;:.]+\z/, '').sub(/\A[[:alpha:]]+\((?![^(]*\))/, '')
end

# The parts of the names in a directory that a space follows
def spaced_prefixes(dir)
  (@spaced_prefixes ||= {})[dir] ||=
    begin
      Dir.children(dir).each_with_object(Set.new) do |name, set|
        parts = name.split(/ /, -1)
        (1...parts.size).each { |count| set << parts.take(count).join(' ') }
      end
    rescue SystemCallError
      Set.new
    end
end

def continues?(path)
  (@continues ||= {}).fetch(path) do
    @continues[path] =
      !path.empty? && !path.end_with?('/') &&
      expand_tilde(path).then { |full| spaced_prefixes(File.dirname(full)).include?(File.basename(full)) }
  end
end

# A name with a space in it is split into words, so a word is joined with the
# words after it for as long as a name in its directory goes on with them. The
# program may have broken the path at a space, so the words can be on the next
# two rows.
def spaced_paths(index)
  words = rows[index].split
  following = rows[(index + 1)..(index + 2)].to_a.flat_map { |row| undecorate(row).split }
  words.each_index.flat_map do |start|
    path = trim(words[start])
    (words[(start + 1)..] + following).each_with_object([]) do |word, found|
      break found unless continues?(path)

      path = trim("#{path} #{word}")
      found << path
    end
  end
end

# Lazy, so that a check for the first item does not walk the whole screen
def screen_words
  screen_indices.lazy.flat_map { |index| spaced_paths(index) + rows[index].split }
                .map { |word| trim(word) }.select { |word| word.match?(/[[:alnum:]]/) }
end

# A path too long for the row it is on is broken across two rows, so the end
# of a row and the start of the next are offered as one word as well. Only
# the ones that exist are kept, so a join that is not a path costs nothing.
def broken_words(source)
  source.each_cons(2).filter_map do |first, second|
    tail = first.rstrip[/\S+\z/]
    next unless tail&.include?('/')

    head = undecorate(second)[/\A\S+/]
    trim("#{tail}#{head}") if head
  end
end

def screen_broken_words
  @screen_broken_words ||= broken_words(rows_above).reverse + broken_words(rows_below)
end

# Whether the program ran out of room on the row and put the rest on the next
# one: the row reaches the right edge, or the first word of the text that
# follows would not have fit on it. A row wider than the pane is one the
# terminal wrapped and -J joined back together, so it holds a whole line.
def wrapped?(row, text, width)
  return false if row.nil? || columns(row) > width
  return true if columns(row) >= width - 8

  # A word wider than the pane says nothing, as it has to be broken anywhere
  word = columns(text[/\A\S+/])
  word < width && columns(row) + word >= width
end

# A path too long for its row is broken after a slash, so the two parts are
# put back together with nothing in between. A row that ends with a directory
# name, as a listing does, is not a path cut in two.
def append(text, more)
  text.match?(%r{/[^/[:space:]]+/\z}) ? text + more : "#{text} #{more}"
end

# The text of the pane as paragraphs. A row the program wrapped is joined with
# the row that follows it, and so are the rows of a list item, which the
# program indents under the text of the item.
def paragraphs(source)
  width = display('#{pane_width}').to_i
  buffer = indent = previous = quoted = nil
  source.each_with_object([]) do |raw, out|
    raw = raw.rstrip
    text = undecorate(raw)
    if text.empty?
      out << buffer if buffer
      buffer = indent = previous = nil
      next
    end
    item = marker?(raw)
    column = text_column(raw, text)
    quote = raw.match?(QUOTE)
    if buffer && !item && quote == quoted && (wrapped?(previous, text, width) || column == indent)
      buffer = append(buffer, text)
    else
      out << buffer if buffer
      buffer = text
      indent = item ? column : nil
    end
    previous = raw
    quoted = quote
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

# A backslash is never in a URL, but starts an escape like \n in JSON
URL = %r{(?:https?|ftp|file|ssh|git)://[^\s<>|"'`\\]+}
# The start of a hyperlink, and the URL it points to
LINK = %r{\e\]8;[^;\e\a]*;([^\e\a]*://[^\e\a]*)(?:\e\\|\a)}

# The URLs of the hyperlinks on each row. A link holds the whole URL, even when
# the program broke its text across rows.
def link_rows
  @link_rows ||= escaped_rows.map { |line| line.scan(LINK).flatten }
end

def screen_links
  screen_indices.lazy.flat_map { |index| link_rows[index] || [] }
end

# What can only be a part of a URL, and not a word of the text
URL_PART = %r{\A[^\s<>|"'`\\]*[/.#?=&%][^\s<>|"'`\\]*\z}

# The start of the next row, when it is the rest of a URL the program broke at
# the end of the row
def url_rest(index, width)
  text = undecorate(rows[index + 1].to_s)
  head = text[/\A\S+/]
  head if head&.match?(URL_PART) && wrapped?(rows[index].rstrip, text, width)
end

# A URL at the end of a row is joined with the rest of it on the rows below
def text_urls(index, width)
  urls = rows[index].scan(URL)
  return urls unless urls.any? && rows[index].rstrip.end_with?(urls.last)

  while (rest = url_rest(index, width))
    urls[-1] += rest
    index += 1
    # The row goes on with the text after the URL
    break unless undecorate(rows[index]).rstrip == rest
  end
  urls
end

# The text of a link broken across rows is the start of its URL, and is left out
def urls
  width = display('#{pane_width}').to_i
  screen_indices.flat_map do |index|
    links = link_rows[index] || []
    shown = text_urls(index, width).map { |url| url.sub(/[)'"`\]},;:.!?]+\z/, '') }
    links + shown.reject { |url| links.any? { |link| link.start_with?(url) } }
  end.uniq
end

def expand_tilde(path)
  return Dir.home if path == '~'

  path.start_with?('~/') ? File.join(Dir.home, path.delete_prefix('~/')) : path
end

# A word is offered as a path only when it is one, which is what tells a real
# name from something shaped like it, such as 12/12 or v2.42.0. A line number
# after it, as in the output of a compiler, is dropped.
def path_candidates
  screen_words.chain(screen_broken_words).lazy
              .reject { |word| word.include?('://') }
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

# A paragraph of one word is not text, but a sentence of one word in a longer
# paragraph is, as in "Done."
def sentences
  (paragraphs(rows_above).reverse + paragraphs(rows_below))
    .map { |para| clean(para) }
    .select { |para| para.match?(/[[:alpha:]]/) && para.include?(' ') }
    .flat_map { |para| para.split(/(?<=[.!?])\s+(?=["'(\[]?[A-Z])/) }
    .select { |line| line.match?(/[[:alpha:]]/) }
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

# --- Where an item is on the screen --------------------------------------

# Providers whose preview shows the rows around the item
CONTEXT = %w[urls sentences].freeze

# An escape sequence of a color or a hyperlink
ESCAPE = %r{\e\][^\e\a]*(?:\e\\|\a)|\e\[[0-9;:?<=>]*[ -/]*[@-~]|\e.}m
OSC8 = /\A\e\]8;[^;\e\a]*;([^\e\a]*)/

# The rows of the screen are saved for the preview, which shows them as they
# were when the list was made. Renamed into place, so that the preview never
# reads a half-written file. Only the user can read it, as it holds what the
# terminal showed.
def screen_file(state)
  "#{state}.screen"
end

def save_screen(state)
  File.open("#{screen_file(state)}.tmp", 'w', 0o600) { |file| file.write(([cursor_row] + escaped_rows).join("\n")) }
  File.rename("#{screen_file(state)}.tmp", screen_file(state))
end

# A row as its pieces, each an escape sequence or a character with its index in
# the text of the row, and the ranges of the text each link covers
def parse(row)
  pieces = []
  links = []
  length = 0
  row.scan(/(#{ESCAPE})|(.)/m) do |escape, char|
    if char
      pieces << [char, length]
      length += 1
      next
    end

    pieces << [escape, nil]
    next unless (url = escape[OSC8, 1])

    links.last[2] = length if links.last && links.last[2].nil?
    links << [url, length, nil] unless url.empty?
  end
  links.last[2] = length if links.last && links.last[2].nil?
  [pieces, links]
end

# The item as it can be broken across rows. A space stands for any blank,
# decoration, or quote marker in between, and a row can end after any
# character, with the next one going on after its indentation.
def item_pattern(item)
  blank = /(?:[[:space:]]|#{DECORATION}|>)+/
  broken = /(?:[^\S\n]*\n(?:[^\S\n]|#{DECORATION}|>)*)?/
  words = item.split.map { |word| word.chars.map { |char| Regexp.escape(char) }.join(broken.to_s) }
  # Not a part of a longer word, as page/5 is of page/59
  before = item.match?(/\A[[:alnum:]]/) ? '(?<![[:alnum:]])' : ''
  after = item.match?(/[[:alnum:]]\z/) ? '(?![[:alnum:]])' : ''
  Regexp.new(before + words.join(blank.to_s) + after)
end

# The rows of the item and the ranges of it on each, at the occurrence nearest
# to the cursor. A link is found by its URL when its text is something else.
def find_item(rows, texts, cursor, item)
  nearest = ->(row) { row < cursor ? [0, cursor - row] : [1, row] }
  starts = texts.each_with_object([0]) { |text, out| out << (out.last + text.length + 1) }
  row_of = ->(offset) { starts.bsearch_index { |start| start > offset } - 1 }
  matches = texts.join("\n").to_enum(:scan, item_pattern(item)).map { Regexp.last_match.offset(0) }
  unless matches.empty?
    first, last = matches.min_by { |from, _| nearest.(row_of.(from)) }
    return (row_of.(first)..row_of.(last - 1)).to_h do |row|
      # The indentation a row goes on after is not a part of the item
      from = [first - starts[row], texts[row][/\A(?:[[:space:]]|#{DECORATION}|>)*/].length].max
      [row, [[from, [last - starts[row], texts[row].length].min]]]
    end
  end

  linked = rows.each_index.select { |row| rows[row].include?(item) && parse(rows[row])[1].any? { |url,| url == item } }
  return {} if linked.empty?

  # The rows next to the nearest one that the link goes on to
  group = [linked.min_by(&nearest)]
  group.unshift(group.first - 1) while linked.include?(group.first - 1)
  group.push(group.last + 1) while linked.include?(group.last + 1)
  group.to_h { |row| [row, parse(rows[row])[1].select { |url,| url == item }.map { |_, from, to| [from, to] }] }
end

# A row as the lines of the preview, broken at its width, with the ranges in
# reverse video, and the line the first of them starts on. Spaces at the end
# are dropped. The colors go on to the next line, so they are reset only at the
# end of the row.
def render(row, ranges, width)
  pieces, = parse(row)
  last = pieces.rindex { |piece, index| index && piece.match?(/\S/) } || -1
  lines = [+'']
  start = nil
  column = 0
  inside = false
  pieces.each_with_index do |(piece, index), position|
    if index.nil?
      lines.last << piece
      lines.last << "\e[7m" if inside
      next
    end
    next if position > last

    now = ranges.any? { |from, to| index >= from && index < to }
    lines.last << (now ? "\e[7m" : "\e[27m") if now != inside
    inside = now
    used = char_columns(piece)
    if column + used > width && column.positive?
      lines << +''
      column = 0
    end
    start ||= lines.size - 1 if now
    lines.last << piece
    column += used
  end
  lines.last << "\e[0m"
  [lines, start]
end

# The rows around the item, as many as fit in the preview, with the item in
# the middle
def context(rows, cursor, item, height, width)
  return [] if item.strip.empty?

  texts = rows.map { |row| normalize(row.gsub(ESCAPE, '')) }
  # The empty rows at the bottom of the screen
  rows = rows.take((texts.rindex { |text| text.match?(/\S/) } || -1) + 1)
  found = find_item(rows, texts, cursor, item)
  return [] if found.empty?

  lines = ->(row) { render(rows[row], found.fetch(row, []), width)[0] }
  top, bottom = found.keys.minmax
  shown = (top..bottom).flat_map(&lines)
  # A row too long for the preview is shown from around the line the item is on
  if shown.size > height
    _, start = render(rows[top], found[top], width)
    return shown.drop([start.to_i - (height / 2), 0].max)
  end

  loop do
    added = false
    if top.positive? && (more = lines.(top - 1)).size + shown.size <= height
      top -= 1
      shown = more + shown
      added = true
    end
    if bottom < rows.size - 1 && (more = lines.(bottom + 1)).size + shown.size <= height
      bottom += 1
      shown += more
      added = true
    end
    break unless added
  end
  shown
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

def preview(provider, state)
  case provider
  when 'files' then %(#{TILDE} [ -f "$f" ] && #{viewer} "$f" || ls -F "$f")
  when 'dirs'  then %(#{TILDE} ls -F "$f")
  when 'paths' then %(#{TILDE} [ -f "$f" ] && #{viewer} "$f" || ls -F "$f" 2> /dev/null)
  else              "#{SCRIPT.shellescape} context #{state.shellescape} {}"
  end
end

# The rows of the screen are as wide as the pane, so they wrap less at the
# bottom
def preview_window(provider)
  CONTEXT.include?(provider) ? 'down,40%' : 'right,50%'
end

# Whether a provider has anything to offer. It stops at the first item, instead
# of building a list that may be thrown away.
def available?(provider)
  case provider
  when 'urls'      then screen.any? { |line| line.match?(URL) } || screen_links.any?
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
  keys += ' · CTRL-Y copy · CTRL-R reload'
  providers.map do |name|
    text = "\e[4m#{name[0]}\e[24m#{name[1..]}"
    "#{current == name ? "\e[1m" : "\e[2m"}#{text}\e[22m"
  # The keys come last, as the header is truncated when a preview is shown
  end.join(' ') + "\e[2m#{keys}\e[22m"
end

def next_provider(current, providers)
  providers[(providers.index(current) + 1) % providers.length]
end

# What fzf is told to do when a provider is switched to. The list is reloaded in
# place, so the pane fzf runs in stays open, and the cursor goes back to the top
# as the items are not the same.
def switch_actions(provider, state, providers)
  _, _, hidden = read_state(state)
  write_state(state, provider, providers, hidden)
  actions = ["change-border-label(#{label(provider, ENV.fetch('FZF_QUERY', ''))})",
             "change-header(#{header(provider, providers)})",
             "change-preview(#{preview(provider, state)})",
             "change-preview-window(#{preview_window(provider)}#{',hidden' if hidden})"]
  actions << "reload(#{SCRIPT.shellescape} list #{state.shellescape})" << 'first'
  actions.join('+')
end

def open_action(current, state)
  return nil unless OPENABLE.include?(current)

  "execute(#{SCRIPT.shellescape} open #{state.shellescape} {+})"
end

def copy_action(state)
  "execute-silent(#{SCRIPT.shellescape} copy #{state.shellescape} {+})"
end

# A path is inserted as it can be typed on a command line. gsub is given a
# block, as a backslash in a replacement string stands for a part of the item
# instead of itself.
def shell_quote(item)
  return item if item.match?(%r{\A[A-Za-z0-9_@%+=:,./~-]+\z})

  "'#{item.gsub("'") { "'\\''" }}'"
end

# What the items amount to as one line of text
def text_of(items, provider)
  quoted = QUOTED.include?(provider)
  items.map { |item| quoted ? shell_quote(item) : item }.join(' ')
end

# Commands that take what goes in the clipboard from their input. tmux comes
# last, as the terminal has to be willing to take what it sends.
def clipboard(text)
  command = executable('pbcopy', 'wl-copy', 'xclip -selection clipboard', 'xsel -ib')
  IO.popen(command || 'tmux load-buffer -w -', 'w') { |io| io.write(text) }
end

# The provider in use, the ones to offer, and whether the preview is hidden
def read_state(path)
  current, providers, hidden = File.read(path).lines.map(&:strip)
  [current, providers.split, hidden == 'hidden']
end

def write_state(path, current, providers, hidden = false)
  File.write(path, "#{current}\n#{providers.join(' ')}\n#{'hidden' if hidden}\n")
end

# The word in front of the cursor, which the selection replaces. The row ends
# before the cursor when the cell in front of it is blank, and a blank cell is
# not part of any word. What a program decorates its prompt with is not part of
# one either, and is left where it is. So is the @ that a program like Claude
# Code puts in front of a path to mention a file.
def word_before(row, cursor_x)
  before = up_to_column(row, cursor_x)
  return '' if columns(before) < cursor_x

  before[/[^[:space:]]*\z/].to_s.sub(/\A#{DECORATION}+/, '').delete_prefix('@')
end

# The functions above are what the tests load
return unless __FILE__ == $PROGRAM_NAME

halt 'TMUX_PANE is not set' if PANE.nil? || PANE.empty?

# --- Run as a child of fzf -----------------------------------------------

case ARGV.first
when 'open-action'
  # Nothing is printed for a provider whose items cannot be opened, so that
  # CTRL-O does not run a process and make fzf flicker for nothing
  current, = read_state(ARGV[1])
  puts open_action(current, ARGV[1])
  exit
when 'open'
  # CTRL-O, which fzf runs with the tty, so an editor can take the pane over.
  # It opens the items that are marked, or the one under the cursor when none
  # are.
  current, = read_state(ARGV[1])
  items = ARGV[2..].reject(&:empty?)
  exit if items.empty?

  if current == 'urls'
    opener = executable('open', 'xdg-open')
    halt 'No command to open a URL with' unless opener

    # xdg-open takes one URL
    items.each { |item| system("#{opener} #{item.shellescape} > /dev/null 2>&1") }
  else
    system("#{ENV.fetch('EDITOR', 'vim')} #{items.map { |item| expand_tilde(item).shellescape }.join(' ')}")
  end
  exit
when 'copy'
  # CTRL-Y, with the items that are marked, or the one under the cursor when
  # none are
  current, = read_state(ARGV[1])
  items = ARGV[2..]
  exit if items.empty?

  clipboard(text_of(items, current))
  halt "Copied #{items.length == 1 ? items.first : "#{items.length} items"}"
when 'list'
  current, = read_state(ARGV[1])
  save_screen(ARGV[1]) if CONTEXT.include?(current)
  print_items(current, ENV.fetch('FZF_QUERY', ''))
  exit
when 'toggle-preview'
  current, providers, hidden = read_state(ARGV[1])
  write_state(ARGV[1], current, providers, !hidden)
  puts 'toggle-preview'
  exit
when 'context'
  # The preview of an item of the screen
  path = screen_file(ARGV[1])
  exit unless File.exist?(path)

  cursor, *rows = File.read(path).split("\n", -1)
  puts context(rows, cursor.to_i, ARGV[2].to_s,
               ENV.fetch('FZF_PREVIEW_LINES', '20').to_i, ENV.fetch('FZF_PREVIEW_COLUMNS', '80').to_i)
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

  puts switch_actions(provider, state, providers)
  exit
when 'click'
  # A word in the header was clicked on, and the words are the names of the
  # providers and the keys that are listed after them
  state = ARGV[1]
  current, providers = read_state(state)
  case ENV.fetch('FZF_CLICK_HEADER_WORD', '')
  when *providers          then puts switch_actions(ENV['FZF_CLICK_HEADER_WORD'], state, providers)
  when 'CTRL-T', 'next'    then puts switch_actions(next_provider(current, providers), state, providers)
  when 'CTRL-R', 'reload'  then puts switch_actions(current, state, providers)
  when 'CTRL-O', 'open'    then puts open_action(current, state)
  when 'CTRL-Y', 'copy'    then puts copy_action(state)
  end
  exit
end

# --- Start the finder -----------------------------------------------------

provider = ARGV.first || PROVIDERS.first
halt "Unknown provider: #{provider}" unless PROVIDERS.include?(provider)

# Run in the working directory of the pane
pane_path = display('#{pane_current_path}')
Dir.chdir(pane_path) if File.directory?(pane_path)

# Taken from the screen, as the pane may be running any program. -N keeps the
# trailing spaces, without which the cursor column would point past the end of
# the row.
cursor_y = display('#{cursor_y}').to_i
row = normalize(tmux("capture-pane -p -N -t #{PANE} -S #{cursor_y} -E #{cursor_y}").chomp)
TOKEN = word_before(row, display('#{cursor_x}').to_i)

providers = active_providers
state = Tempfile.new('fzf-complete')
state.close
write_state(state.path, provider, providers)

options = ['--tmux', option('@fzf-complete-popup', '90%,70%'),
           '--multi', '--layout', 'reverse', '--min-height', '10+',
           # Items are ordered by how close to the cursor they were found, and
           # this scheme keeps that order instead of sorting by length
           '--scheme', 'history',
           '--no-separator', '--header-border', 'horizontal',
           '--border-label-pos', '2', '--color', 'label:blue',
           '--highlight-line', '--preview-border', 'rounded', '--wrap=word',
           # The preview and the child commands below are bash
           '--with-shell', 'bash -c',
           # The preview stays hidden when the provider changes
           '--bind', "ctrl-/:transform(#{SCRIPT.shellescape} toggle-preview #{state.path.shellescape})",
           '--border-label', label(provider, TOKEN),
           '--header', header(provider, providers),
           '--query', TOKEN,
           '--preview', preview(provider, state.path),
           '--preview-window', preview_window(provider)]
# CTRL-T goes to the next provider, so that it can be pressed repeatedly
options += ['--bind', "ctrl-t:transform(#{SCRIPT.shellescape} switch #{state.path.shellescape} next)"]
# CTRL-O opens the item, and fzf comes back afterwards
options += ['--bind', "ctrl-o:transform(#{SCRIPT.shellescape} open-action #{state.path.shellescape})"]
# CTRL-Y copies the items, and says so in a tmux message
options += ['--bind', "ctrl-y:#{copy_action(state.path)}"]
# CTRL-R lists again, from the directory in the query, or from the pane as it
# is now
options += ['--bind', "ctrl-r:transform(#{SCRIPT.shellescape} switch #{state.path.shellescape} same)"]
# The header is a row of labels, so a click on one of them does what it says
options += ['--bind', "click-header:transform(#{SCRIPT.shellescape} click #{state.path.shellescape})"]
providers.each do |name|
  options += ['--bind',
              "alt-#{name[0]}:transform(#{SCRIPT.shellescape} switch #{state.path.shellescape} #{name})"]
end

# The list is loaded by fzf itself, so that it stops the moment fzf exits.
# Piping it in would make this script relay the rest of a long listing before
# it could insert anything, and reading the input of a run-shell command never
# reaches the end, so fzf is given nothing to read.
options += ['--bind', "start:reload(#{SCRIPT.shellescape} list #{state.path.shellescape})"]
command = "fzf #{options.map(&:shellescape).join(' ')} < /dev/null"
begin
  selected = IO.popen(command, 'r') { |io| io.readlines.map(&:chomp) }
  current, = read_state(state.path)
ensure
  # The copy of the screen as well, when the script is interrupted
  [screen_file(state.path), "#{screen_file(state.path)}.tmp"].each { |path| File.delete(path) if File.exist?(path) }
  state.unlink
end

exit if selected.empty?

text = text_of(selected, current)

# Replace the word in front of the cursor with the text
if !TOKEN.empty? && text.start_with?(TOKEN)
  # Nothing to delete when the text extends the word
  text = text[TOKEN.length..]
elsif !TOKEN.empty?
  tmux("send-keys -t #{PANE} -N #{TOKEN.length} BSpace")
end
system('tmux', 'send-keys', '-t', PANE, '-l', '--', text) unless text.empty?
