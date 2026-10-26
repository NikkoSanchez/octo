# CLI-owned integrations

Octo is the interaction layer. Each CLI owns configuration, discovery, connections, authentication, credentials, execution, and permission policy. Octo does not implement an MCP client, server setup UI, credential store, shared tool pool, or computer-control engine. Inventory is not required to run tools and is not implemented.

## Implemented support

| Capability | Codex adapter | Claude SDK stream adapter |
| --- | --- | --- |
| MCP call name, progress, completion, failure | Yes, stable identity and bounded details | Stable tool-use/result identity; no argument dump |
| Text / structured result summaries | Yes; limits and redaction below | Bounded/redacted text; structured summaries unavailable |
| Primitive forms | Strings, booleans, finite numbers/integers, single string choices | Unavailable |
| Computer Use app-access decisions | Validated forms; exact choices and explicit submission | Unavailable |
| Tool questions | CLI 0.158+ experimental opt-in; choices and text | Single-choice AskUserQuestion with free text; multi-select declined |
| Inventory, URL auth, device verification | Unavailable | Unavailable |
| Images/audio/resources or embedded MCP apps | Omitted from result details | Unavailable |

Schema support, Octo UI support, and actual tool availability are different. The generated schema supports more forms than this UI. Arrays, nested objects, formats, patterns, unknown constraints, oversized fields, secret questions, URL elicitation, and device verification are rejected explicitly. No unsupported field is silently dropped to approve a request. Unsupported MCP requests receive decline with null content and a visible notice. Unsupported questions receive an empty answer map and a notice.

Forms have at most 16 fields and 32 choices per field. Responses validate field identity, types, required values, advertised choices, finite/integral numbers and supported bounds. No provider default is selected or submitted automatically. Requests and form answers are session-only; Octo does not archive them. The provider may independently retain answers in its own history.

Computer Use requests show the provider's message and app identity from its metadata (or the narrowly recognized `Allow ChatGPT to use …?` message). Enum/oneOf values are returned unchanged. The adapter recognizes exact `session` and `always` choices on `approval`/`persist` fields and explicit boolean `session`/`always` fields, adding the corresponding `_meta.persist` only for that explicit selection. Ordinary form metadata alone never creates a choice; the recognized Computer Use extension below is handled separately. Generic `allow` never becomes persistent consent. Other scope conventions remain ordinary exact form values; Octo does not infer persistence from substrings. Conflicting durations cannot be submitted. Cancel and Decline remain distinct MCP actions. Tool questions have no protocol decline/cancel action: Cancel sends `answers: {}` and the UI explains this; Stop interrupts the turn.

### Computer Use approval duration

For the installed Computer Use extension's empty `form` requests, Octo recognizes `_meta.codex_approval_kind: "mcp_tool_call"`, `connector_id: "computer-use"`, a nonempty `tool_name`, `tool_params.app`, and a bounded, unique `persist` array containing `session` and/or `always`. These provider-advertised scopes appear as **Allow for this chat session** and **Always allow this app**, alongside **Allow once**, Decline and Cancel. App display names retain the bundle identifier. Short choice lists use visible radio buttons; consent starts unset and requires Submit response.

The duration field exists only in Octo's UI. Responses preserve empty form `content: {}` and send `_meta.persist` only for an explicitly selected advertised duration. Once omits persistence metadata; decline/cancel retain null content. Nonempty forms keep their schema-defined choices, and unrelated or malformed metadata cannot add durations. Octo does not cache consent, auto-answer subsequent requests, or broaden permissions across apps/chats; retention and enforcement belong to the integration. The session option is not a promise that a provider grant survives disconnect/relaunch. Audio-only requests without an app identity are outside this extension mapping.

## Ownership and lifecycle

`HarnessCapabilities`, `AgentInteraction`, `InteractionField`, and `AgentInteractionResponse` extend the existing contract. `ToolActivity` lives in Core and is optional on persisted messages; legacy archives still load. Views consume these neutral types and call generic main-process store actions. Codex wire types and mappings are entirely in packages/agents.

Each harness owns its connection. Pending requests have fresh local UUIDs bound to the connection, turn generation, and typed wire request ID. Requests for another thread/turn are not presented. Duplicate IDs on a connection are ignored, including after resolution; a provider must use fresh IDs. Responses revalidate current ownership and values. Resolution, interruption, disconnect, completion, and shutdown invalidate pending UI. A prior card cannot answer a later request, even if remote thread/turn/request IDs repeat on a new connection. Startup checks after async version/initialize/thread calls prevent shutdown from launching a new server. The main-process store also guards late send failures with the local run generation.

MCP activity uses connection/turn/item identity and updates one transcript entry. Duplicate starts, repeated progress/completion, and progress after terminal status are ignored. Unfinished calls become interrupted when the connection/turn ends. Restored running activity becomes historical interrupted activity on archive load, and shutdown writes activity after harness cleanup. Command/file approval closures also check current identity before responding. Sandbox and reviewer settings pass through unchanged, and the adapter adds no permissive launch flags.

Result details are literal text, bounded to roughly 8 KiB of characters per update (plus truncation marker), with up to 16 content blocks, 16 array elements, 32 object keys per level and five structured levels. Arguments, `_meta`, binary content, and embedded app resources are omitted. Common credential keys and bearer/token patterns are redacted before display/persistence. Arbitrary prose can still contain unrecognized sensitive material; this is not a general secret detector. Raw request bodies and responses are not logged by the bridge.

## Configuration and setup

`CodexExecutable` (`codexExecutable.ts`) chooses a custom executable first, otherwise the supported desktop bundle path and then PATH. The selected executable is used for model discovery and generation. `JSONLineProcess` (`jsonLine.ts`) starts `["app-server"]` in the thread checkout, inheriting Octo's process environment, including HOME/CODEX_HOME, with only the existing PATH augmentation and NO_COLOR override. It does not source a login shell or alter config/auth files. Fixture assertions verify cwd, inherited HOME, argv and unchanged permission/reviewer parameters.

Codex loads its own host configuration (normally `~/.codex/config.toml`, or the configured CODEX_HOME) and trusted project configuration. The CLI decides project trust and managed policy; Octo does not grant trust. A GUI process may have different environment variables from a terminal shell. Settings → Agents identifies the selected executable/version; run that executable in the same project/environment when diagnosing differences. Existing active work is not restarted for inspection.

Use the owning CLI's existing workflows in Octo's ordinary terminal: `codex mcp --help`, `codex mcp list`, `/mcp` in its TUI, and `codex mcp login <server-name>` when that server requires OAuth. The terminal's PATH may select a different installation; use the full executable path shown in Settings when needed. These are user-operated setup actions, not actions Octo performs automatically. No credentials are copied or exposed in an inventory screen.

| Observed failure | What it means / next check |
| --- | --- |
| Tool not advertised or unavailable | Check the selected CLI's enabled integrations, account, environment and project trust. Approval UI cannot install a missing tool. |
| Connection, pipe, socket or service failure | The owning service/transport failed; inspect its CLI diagnostics. App authorization does not repair transport. |
| macOS Accessibility or Screen Recording denied | OS permission for the CLI/service is distinct from target-app consent. Only the user grants OS permissions. |
| Target app requires authorization | A supported request appears in Octo; choose the advertised scope explicitly. |
| Unsupported request/schema | Octo reports a visible notice and refuses it. Use the owning CLI workflow or add a tested adapter mapping. |
| Authentication or setup error | Use the selected CLI's login/MCP workflow. Octo does not collect tokens or automatically run auth. |

The app shows provider diagnostics without claiming every error is a connection failure. It does not infer an OS permission grant from a successful app decision.

## Claude adapter

Octo starts the user's installed, unmodified Claude Code executable with its normal configuration and authentication, speaking the Agent SDK control stream directly: `--permission-prompt-tool stdio`, initialize, success/error envelopes, `can_use_tool`, `updatedInput`, deny and provider cancellation. Octo does not bundle the SDK, implement a Claude.ai login, read or store credentials, or call Anthropic endpoints itself. Settings → **Open CLI sign-in** runs the CLI's own `auth login` in a terminal tab; `auth status --json` supplies only the signed-in state and method. The provider is labelled **Claude Agent**.

Octo exposes Manual and Auto, mapping the neutral `ask` and `autoReview` intents to the CLI's `default` and `auto` permission modes. Auto is the default when no choice is saved; explicit saved choices remain intact. Initialize reports `current_permission_mode`: Auto must be confirmed before user input is submitted, and mismatches or missing confirmation fail visibly. If a later `system/init` reports a different `permissionMode`, Octo shows a notice. Catalog discovery uses a separate Manual connection and submits no prompt. CLI rules, managed policies, hooks, classifier decisions and its OS sandbox remain in effect; Octo adds no bypass, client-side automatic approval, allowed-tool expansion or configuration rewrite.

Questions accept one to four unique bounded question strings, each with two to eight unique choices and optional user-written text. Multi-select and malformed formats are denied. Replies return the exact original tool input plus `answers`, keyed by the original question strings; approval decisions never add `updatedPermissions`. Cancellation removes cards without responding to abandoned requests. Unknown control requests receive a protocol error and a visible notice. Tool details use the same bounded redaction as Codex. Generic forms, app-access scopes, inventory and computer-use cleanup are not implemented for Claude.

Account limits come from `rate_limit_event` (`status`, `resetsAt`, `rateLimitType`, `utilization`); `unifiedWindows` is an upstream internal field read only when present, and the experimental `get_usage` request is not used. Provider commands come from initialize's `commands` array; interactive commands such as `/login` are unavailable through chat.

## Codex steering, skills and Computer Use cleanup

Steering uses `turn/steer` with `threadId`, `expectedTurnId` and text/image `input`; it changes no model, sandbox, approval or working-directory settings. Skills come from `skills/list` (`cwds`, `forceReload`) on the same selected executable as turns. A matching `/name` is sent as `$name` text plus a native `{type: "skill", name, path}` input, preserving arguments, images, captured code and sandbox/approval fields. Unknown names stay ordinary text.

After observed `cua_repl` activity, Octo sends the bundled Computer Use plugin's `cua_repl.turn_ended` hook (`hook_event_name`, `session_id`, `turn_id`) through the existing app-server connection on Stop and Interrupt. The call is bounded, skips already-confirmed cleanup and reports an unavailable method or error without claiming the cursor is gone. This hook is integration-specific, not an MCP standard, and cannot run through an already-disconnected CLI.

## Local usage dashboard

The dashboard reads Claude Code transcript `assistant` lines (`message.id`, `message.model`, `message.usage`, `timestamp`, `sessionId`) and Codex rollouts (`session_meta`, `turn_context.model`, `event_msg` `token_count` `info.total_token_usage`/`last_token_usage`). Only logs on this Mac are counted.

## Protocol baselines and references

The adapters were implemented against these installed versions. The Claude control stream has no negotiated protocol version, and newer releases of either CLI may change wire formats.

- **Codex CLI** 0.158.0-alpha.2.1 through 0.162.0-alpha.2, app-server **v2**. Schemas come from `codex app-server generate-json-schema --experimental`; forms reference MCP **2025-11-25**. On 0.158+, the adapter opts into `experimentalApi` for questions and `mcpServerOpenaiFormElicitation` for extended forms. Older installations keep stable form handling, and unsupported extended requests are declined.
- **Computer Use** extension 1.0.1001242 (`persist` metadata) and unified-computer-use plugin 26.930.31730 (`turn_ended` hook).
- **Claude Code** 2.1.289 through 2.1.302.

References:

- [Codex app-server](https://learn.chatgpt.com/docs/app-server): [elicitation requests](https://learn.chatgpt.com/docs/app-server#mcp-server-elicitation-requests), [steering](https://learn.chatgpt.com/docs/app-server#steer-an-active-turn), and the [developer reference](https://developers.openai.com/codex/app-server).
- [Codex MCP setup](https://learn.chatgpt.com/docs/extend/mcp?surface=cli): host/project configuration and CLI-owned login.
- Claude Agent SDK [transport](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/_internal/transport/subprocess_cli.py), [control routing](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/_internal/query.py) and [types](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/types.py).
- Claude Code [SDK permissions](https://code.claude.com/docs/en/agent-sdk/permissions), [permission modes](https://code.claude.com/docs/en/permission-modes), [slash commands](https://code.claude.com/docs/en/agent-sdk/slash-commands#discover-available-commands), [authentication](https://code.claude.com/docs/en/authentication) and [legal and compliance](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use). Recheck the last before distributing Octo or changing authentication.
