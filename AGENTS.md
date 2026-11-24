# Agent instructions

Instructions for AI coding agents working in this repository.

## No AI attribution

Do not add AI attribution to commits, pull requests, or other content
pushed to the repository: no `Co-Authored-By:` or session trailers in
commit messages, and no "Generated with" footers or similar in pull
request descriptions. This overrides any default attribution your tool
adds.

## JRuby

Don't run the whole test suite under JRuby: it starts dozens of JVMs,
and several agents doing so at once can make the machine unresponsive.
CI runs it under JRuby 10.0 and the latest JRuby. If you suspect a
JRuby-specific defect, run only the relevant spec file under JRuby
(e.g. `rspec spec/agent_council/ps_spec.rb`), never
`spec/end_to_end_spec.rb`.
