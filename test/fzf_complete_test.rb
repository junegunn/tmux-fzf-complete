# frozen_string_literal: true

# What the providers find on a screen
#
#   ruby test/fzf_complete_test.rb

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fzf-complete'

class FzfCompleteTest < Minitest::Test
  BASE = 'https://git.example.com/org/charts/blob/8f44f20964d7ec7e8b0603bc184b770afa358880/custom'

  # A pane that shows the text, with the cursor on an empty row below it. \e]8
  # starts a hyperlink, which only a capture with -e keeps.
  def show(text, width: 80)
    @text = text
    @width = width
  end

  def tmux(command)
    rows = @text.lines.size
    case command
    when /capture-pane.* -e / then "#{@text}\n"
    when /capture-pane/       then "#{@text.gsub(/\e\]8;[^\e\a]*(?:\e\\|\a)/, '')}\n"
    when /pane_width/         then "#{@width}\n"
    when /pane_height/        then "#{rows + 1}\n"
    when /cursor_y/           then "#{rows}\n"
    else ''
    end
  end

  def link(url, text)
    "\e]8;;#{url}\e\\#{text}\e]8;;\e\\"
  end

  def test_urls_of_links_broken_across_rows
    opencost = "#{BASE}/opencost/usage-cost-mpc-prod1-tky.rules.yaml#L89"
    trace = "#{BASE}/trace/talk.rules.yaml#L3"
    show(<<~TEXT, width: 130)
      10m   OpenCost (#{link(opencost, "#{BASE}/opencost/usage-cost-mpc-prod1-")}
            #{link(opencost, 'tky.rules.yaml#L89')}), daily
      30m   Trace (#{link(trace, "#{BASE}/trace/")}
            #{link(trace, 'talk.rules.yaml#L3')}), 24h
      Plain https://example.com/plain/url. See #{link('https://github.com/junegunn/fzf/pull/1', 'PR #1')}
    TEXT
    assert_equal ['https://github.com/junegunn/fzf/pull/1', 'https://example.com/plain/url', trace, opencost], urls
  end

  def test_urls_broken_across_rows
    show(<<~TEXT, width: 130)
      10m   OpenCost (#{BASE}/opencost/usage-cost-
            mpc-prod1-tky.rules.yaml#L89), daily

      30m   Trace and RPC summaries (#{BASE}/trace/
            talk.rules.yaml#L3), 24h

      Long: https://example.com/#{'a' * 95}/
            #{'b' * 118}/
            c.html and more
    TEXT
    assert_equal ["https://example.com/#{'a' * 95}/#{'b' * 118}/c.html",
                  "#{BASE}/trace/talk.rules.yaml#L3",
                  "#{BASE}/opencost/usage-cost-mpc-prod1-tky.rules.yaml#L89"], urls
  end

  def test_urls_not_joined_with_next_row
    show(<<~TEXT, width: 130)
      Short row https://example.com/short
      notes.txt is a file

      Edge row with a link that ends near the right edge of the pane, so it looks wrapped https://example.com/edge/path
      including more words here

      Edge row with a link that ends near the right edge of the pane, followed by a file https://example.com/edge2
      README.md has more
    TEXT
    assert_equal %w[https://example.com/edge2 https://example.com/edge/path https://example.com/short], urls
  end

  def test_paths
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        %w[README.md src/main.rb src/lib/util.rb my\ docs/notes.txt very/long/directory/name/file.txt].each do |path|
          FileUtils.mkdir_p(File.dirname(path))
          FileUtils.touch(path)
        end
        show(<<~TEXT)
          ● Read(README.md)
            ⎿  Read 12 lines
          src/main.rb:12:3: error: undefined method
          See "my docs/notes.txt" for details, and src/lib/util.rb.
          Version v2.42.0 on 12/12, not nope/missing.rb or https://example.com/src/main.rb
          The file is in very/long/directory/
          name/file.txt and nowhere else
        TEXT
        assert_equal ['very/long/directory/', 'my docs/notes.txt', 'src/lib/util.rb', 'src/main.rb',
                      'README.md', 'very/long/directory/name/file.txt'], screen_paths
      end
    end
  end

  def test_sentences
    show(<<~TEXT)
      ● The quick brown fox jumps over the lazy dog. It was a sunny day in the park
        and everyone was happy. Nobody expected what came next!

        - First item of the list, which is long enough that the program has to wrap
          it onto the next row.
        - Second item.

        > A quote that the program wraps because it is too long to fit on a single
        > row of the pane.

        Done
    TEXT
    assert_equal ['A quote that the program wraps because it is too long to fit on a single row of the pane.',
                  'Second item.',
                  'First item of the list, which is long enough that the program has to wrap it onto the next row.',
                  'The quick brown fox jumps over the lazy dog.',
                  'It was a sunny day in the park and everyone was happy.',
                  'Nobody expected what came next!'], sentences
  end

  def test_word_before_cursor
    assert_equal '~/github', word_before('> @~/github', 11)
    assert_equal 'src/foo', word_before('❯@src/foo', 9)
    assert_equal 'user@host', word_before('$ ssh user@host', 15)
    assert_equal '', word_before('$ ls ', 5)
    assert_equal '', word_before('$ ls', 6)
  end
end
