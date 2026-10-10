# SousVide Flow

A codebase as a flow chart you work on together with an agent:
http://127.0.0.1:8760/flow (the dashboard serves it).

## Maps (`.flyke`)

A map is JSON in a `flow/` folder of a mod, or of any monorepo folder:
blocks (`nodes`), edges (`call`, `http`, `sql`, `file`, `mirror`), and for
traced maps a `timeline`.

- **Trace maps** (`tools/flyke/build_flyke.py`): what one real run went
  through, from a SousVide trace. Paths are relative to the monorepo.
- **Static maps** (`tools/flyke/polyglot.py`): a whole repo across languages
  with tree-sitter. Cross-language edges come from literals (HTTP path ↔
  route, SQL ↔ table, file writer ↔ reader, shared check ids). Paths are
  relative to the folder holding `flow/`; `--also DIR:Repo@branch` adds files
  read out of git, served back with `git show`. Deterministic: a
  `flow/regen.sh --check` works as a lockfile in CI.

Call edges inside one language come from name matching, so they can be wrong
(a `.get(...)` matched to an unrelated `get`). Contract edges are literal
matches.

## Selection and summaries

Shift-click or shift-drag to select blocks, then **summarize selection**. The
agent reads the selection with the MCP tool `flow_selection`: each block's
code, doc and current summary, plus the edges inside the selection and the
boundary (edges crossing in and out). It writes summaries back with
`flow_summarize`. They are stored in `flow/<name>.summaries.json`, each keyed
to a hash of its block's code, so a summary shows as **stale** once its code
changes.

## Live: operator and agent on the same map

With the hooks below, every Read / Edit / Write the agent makes is mapped onto
blocks and pushed to the viewer (server-sent events, `/api/flow/events`):

- blocks glow blue while read and orange while edited; the **Agent, live**
  feed lists it all, and an edited block keeps its diff in the block panel
- a map with a `flow/regen.sh` is rebuilt about 3 s after edits; edges that
  appeared are drawn green and listed in the feed with the ones that vanished

The operator, from the block panel:

- **notes**: arrive as context on the agent's next tool call or prompt. The
  agent answers with `flow_notes` (`reply`, `done`)
- **lock**: an Edit or Write touching a locked block is **denied** by the
  PreToolUse hook. Enforced, not requested
- **plan**: the agent calls `flow_plan` with the blocks it intends to touch.
  They are outlined on the chart; the operator approves, unticks blocks
  (which become locked) or rejects, and the answer reaches the agent on its
  next step

**Waking an idle agent.** Hooks only fire while the agent is working. An
idle agent listens instead: it runs `node dashboard/flow-wait.js` as a
background command, which blocks on `/api/flow/wait` until the operator sends
a note or answers a plan, prints it and exits. The exit wakes the agent
(about 0.3 s after the click), it acts on the note, and it starts the listener
again. The viewer shows "agent listening" while one is waiting.

Notes, locks and the plan persist in `dashboard/.cache/flow-collab.json`;
activity and diffs are in memory. Edits made through Bash (sed, scripts) are
invisible to the hooks.

### Hooks

`dashboard/flow-hook.js` relays the hook to the dashboard and prints its
answer. With no dashboard running it prints nothing and exits 0, so the hook
never gets in the way. In the monorepo's `.claude/settings.local.json`:

```json
"hooks": {
  "PreToolUse":  [{ "matcher": "Read|Edit|Write|NotebookEdit", "hooks": [{ "type": "command", "command": "node \"C:/Users/Khalen/Code/pz-mods/pz-test-kit/dashboard/flow-hook.js\"", "timeout": 5 }] }],
  "PostToolUse": [{ "matcher": "Read|Edit|Write|NotebookEdit", "hooks": [{ "type": "command", "command": "node \"C:/Users/Khalen/Code/pz-mods/pz-test-kit/dashboard/flow-hook.js\"", "timeout": 5 }] }],
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "node \"C:/Users/Khalen/Code/pz-mods/pz-test-kit/dashboard/flow-hook.js\"", "timeout": 5 }] }]
}
```

Project settings come from the folder Claude Code starts in: a session
started inside a submodule needs the same block in that submodule's settings,
or in the user settings.

## Endpoints

| Endpoint | |
|---|---|
| `GET /api/flyke[?mod&name]` | list maps / one map, summaries merged in |
| `GET /api/flow/source?mod&name&file` | a block's file (map folder, monorepo, or git) |
| `GET/POST /api/flow/selection` | the operator's selection / its context pack |
| `POST /api/flow/summaries` | `{mod, name, summaries: {id: text}, by}` |
| `POST /api/flow/hook` | Claude Code hook payloads (flow-hook.js) |
| `GET /api/flow/events` | live event stream for the viewer |
| `GET /api/flow/collab?mod&name` | notes, locks, edits, plan, recent activity |
| `POST /api/flow/note`, `/api/flow/notes`, `/api/flow/lock`, `/api/flow/plan` | operator and agent actions |
