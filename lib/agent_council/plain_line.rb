# frozen_string_literal: true

# AgentCouncil.plain_line, in a file of its own so agent-council-ps, which
# doesn't load lib/agent_council.rb, can use it too.

module AgentCouncil
  # Text on one line with no control characters: every run of whitespace
  # or control characters (newlines, carriage returns, the ESC that starts
  # a terminal escape sequence) becomes one space; the rest of an escape
  # sequence, such as "[2J", stays as harmless text. Warnings can quote a
  # model's refused command, so this keeps one from moving the cursor or
  # clearing the screen when printed, or from breaking the line it appears
  # on in a report. Text in any encoding is read as UTF-8 (a SystemCallError's
  # message can be binary). Invisible format characters (Unicode category Cf, such
  # as bidirectional overrides and zero-width spaces) are removed, so text
  # can't display reordered or hide characters. Invalid bytes become U+FFFD,
  # since this also runs in rescue clauses and must not raise.
  module_function def plain_line(text)
    # Alternation, not one bracket class: the two overlap, which ruby -w
    # warns of.
    String.new(text.to_s, encoding: Encoding::UTF_8).scrub.gsub(/\p{Cf}/, '')
      .gsub(/(?:[[:space:]]|[[:cntrl:]])+/, ' ').strip
  end
end
