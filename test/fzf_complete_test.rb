# frozen_string_literal: true

# What the providers find on a screen
#
#   ruby test/fzf_complete_test.rb

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fzf-complete'

class FzfCompleteTest < Minitest::Test
  BASE = 'https://git.example.com/org/charts/blob/8f44f20964d7ec7e8b0603bc184b770afa358880/custom'

  # A pane that shows the text, with the cursor on an empty row below it
  def show(text, width: 80)
    @text = text
    @width = width
  end

  # The commands that change something are kept, to be checked
  def tmux(command)
    rows = @text.to_s.lines.size
    case command
    when /set-option/         then (@changes ||= []) << command and ''
    when /capture-pane/       then "#{@text}\n"
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

  def test_urls_broken_after_scheme
    show(<<~'TEXT', width: 105)
      and the proposed topology before passing this checkpoint.</p></td><td><ul><li><a href=\"https://
      wiki.example.com/download/attachments/4491095462/message-03-hbase.ny-snapshot-query-
      results.json\">Captured New Year traffic results</a></li><li><a href=\"https://
      host1502.example.com:26010/master-status\">HBase RegionServer population</a></li></ul></td></tr></
      tbody></table><h2>Unresolved Risks</h2><table class=\"wrapped\"><thead><tr><th scope=\"col\">#</th><th

      A scheme alone at the end of a short row is not a URL: https://
      nothing.here follows it
    TEXT
    assert available?('urls')
    assert_equal ['https://host1502.example.com:26010/master-status',
                  'https://wiki.example.com/download/attachments/4491095462/' \
                  'message-03-hbase.ny-snapshot-query-results.json'], urls
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

  def test_urls_in_colors
    show("\e[32mhttps://a.com/x\e[0m and \e[1mhttps://a.com/y\e[0m\n")
    assert_equal %w[https://a.com/x https://a.com/y], urls
  end

  def test_urls_end_at_backslash
    show(<<~'TEXT')
      "body": "https://issues.apache.org/jira/browse/HBASE-30473\n\nBackport from",
    TEXT
    assert_equal ['https://issues.apache.org/jira/browse/HBASE-30473'], urls
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

  # Without the empty rows at the bottom
  def test_context_keeps_colors
    rows = ["\e[32mgreen\e[0m see https://a.com/x here", 'next', '', '  ']
    assert_equal ["\e[32mgreen\e[0m see \e[7mhttps://a.com/x\e[27m here\e[0m", "next\e[0m"],
                 context(rows, 2, 'https://a.com/x', 20, 80)
  end

  def test_context_of_item_broken_across_rows
    rows = ['(https://example.com/aaa/', '    bbb.html), more']
    assert_equal ["(\e[7mhttps://example.com/aaa/\e[0m", "    \e[7mbbb.html\e[27m), more\e[0m"],
                 context(rows, 2, 'https://example.com/aaa/bbb.html', 20, 80)

    rows = ['  > A quote that', '  > wraps across rows. Next one.']
    assert_equal ["  > \e[7mA quote that\e[0m", "  > \e[7mwraps across rows.\e[27m Next one.\e[0m"],
                 context(rows, 2, 'A quote that wraps across rows.', 20, 80)
  end

  def test_context_of_link
    rows = ["See #{link('https://x.com/1', 'PR #1')} now"]
    assert_equal ["See \e]8;;https://x.com/1\e\\\e[7mPR #1\e]8;;\e\\\e[7m\e[27m now\e[0m"],
                 context(rows, 1, 'https://x.com/1', 20, 80)
  end

  def test_context_around_nearest_occurrence
    rows = (0..20).map { |i| "row #{i}#{' https://a.com/1' if [3, 15].include?(i)}#{' https://a.com/10' if i == 16}" }
    assert_equal ['row 13', 'row 14', "row 15 \e[7mhttps://a.com/1", 'row 16 https://a.com/10', 'row 17'],
                 context(rows, 18, 'https://a.com/1', 5, 80).map { |line| line.delete_suffix("\e[0m") }
  end

  def test_context_wraps_at_width
    rows = ["\e[1m#{'x' * 30} https://a.com/long #{'y' * 10}"]
    assert_equal ["\e[1m#{'x' * 20}", "#{'x' * 10} \e[7mhttps://a", ".com/long\e[27m #{'y' * 10}\e[0m"],
                 context(rows, 1, 'https://a.com/long', 10, 20)
  end

  def test_context_of_row_longer_than_preview
    rows = ["#{'x' * 200} https://a.com/end"]
    assert_equal ['x' * 40, 'x' * 40, " \e[7mhttps://a.com/end\e[0m"],
                 context(rows, 1, 'https://a.com/end', 5, 40)
  end

  def test_context_of_item_not_on_screen
    assert_empty context(['nothing'], 1, 'missing', 20, 80)
  end

  def test_hidden_preview_stays_hidden
    Tempfile.create('state') do |file|
      write_state(file.path, 'files', %w[files urls], true)
      assert_includes switch_actions('urls', file.path, %w[files urls]), 'change-preview-window(up,40%,hidden)'
      assert_equal ['urls', %w[files urls], true], read_state(file.path)

      write_state(file.path, 'urls', %w[files urls])
      assert_includes switch_actions('files', file.path, %w[files urls]), 'change-preview-window(right,50%)+'
    end
  end

  def test_switch_remembers_provider
    Tempfile.create('state') do |file|
      write_state(file.path, 'files', %w[files urls])
      switch_actions('urls', file.path, %w[files urls])
      # CTRL-R lists the same provider again
      switch_actions('urls', file.path, %w[files urls])
      assert_equal ['set-option -g @fzf-complete-last-provider urls'], @changes
    end
  end

  def test_word_before_cursor
    assert_equal '~/github', word_before('> @~/github', 11)
    assert_equal 'src/foo', word_before('❯@src/foo', 9)
    assert_equal 'user@host', word_before('$ ssh user@host', 15)
    assert_equal '', word_before('$ ls ', 5)
    assert_equal '', word_before('$ ls', 6)
  end
end
