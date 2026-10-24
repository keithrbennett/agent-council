# Review Notes

Findings raised by code review — including multi-agent review via this
tool itself (`pi` provider routes like `kimi-coding`, `openai-codex`,
`opencode-go`) — that were considered and don't need to be raised again.
Two kinds of entry live here:

- **Accepted risk**: a real issue, deliberately left unaddressed. Not a
  TODO list — if the decision changes, remove the entry and fix it
  instead of leaving both.
- **Non-issue**: something that looks like a bug or gap on a quick read
  but isn't, for reasons a reviewer wouldn't have context for. Explains
  why it's fine so it stops getting re-flagged.

## Non-issue: MCP tools are unreachable in agent-council runs

Reviewers have claimed that pi's MCP extension auto-activates `codemode`
(or `tool_search`) and so makes MCP tools callable despite the
`--tools read,grep,find,ls,bash` allowlist. Checked against pi 1.4.0's
source (`dist/core/agent-session.js` and `dist/extensions/mcp/index.js`):

- `--tools` filters the tool registry, not just the active set
  (`_isAllowedTool`), so unlisted `codemode` and `tool_search` are never
  registered.
- `ensureDiscoveryActive` activates only a registered tool that
  `reachesTools`, finds none, and warns that MCP tools are unreachable.
- MCP tools themselves stay registered only for those two tools to
  reach, and aren't declared to the model while neither is registered.

MCP servers still start, which the README's Safety section says.
