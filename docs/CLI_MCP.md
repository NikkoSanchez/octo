# CLI-owned integrations

Octo is the native interaction layer. Each CLI owns configuration, discovery, connections, authentication, credentials, execution, and permission policy. Octo does not implement an MCP client, server setup UI, credential store, shared tool pool, or computer-control engine. Inventory is not required to run tools and is not implemented.

## Implemented support

| Capability | Codex adapter | Claude print adapter |
| --- | --- | --- |
| MCP call name, progress, completion, failure | Yes, stable identity and bounded details | Existing generic tool-use activity only |
| Text / structured result summaries | Yes; limits and redaction below | No new result handling |
| Primitive forms | Strings, booleans, finite numbers/integers, single string choices | Unavailable |
| Computer Use app-access decisions | Validated forms; exact choices and explicit submission | Unavailable |
| Tool questions | CLI 0.158+ experimental opt-in; choices and text | Unavailable |
| Inventory, URL auth, device verification | Unavailable | Unavailable |
| Images/audio/resources or embedded MCP apps | Omitted from result details | Unavailable |

Schema support, Octo UI support, and actual tool availability are different. The generated schema supports more forms than this UI. Arrays, nested objects, formats, patterns, unknown constraints, oversized fields, secret questions, URL elicitation, and device verification are rejected explicitly. No unsupported field is silently dropped to approve a request. Unsupported MCP requests receive decline with null content and a visible notice. Unsupported questions receive an empty answer map and a notice.

Forms have at most 16 fields and 32 choices per field. Responses validate field identity, types, required values, advertised choices, finite/integral numbers and supported bounds. No provider default is selected or submitted automatically. Requests and form answers are session-only; Octo does not archive them. The provider may independently retain answers in its own history.

Computer Use requests show the provider's message and app identity from its metadata (or the narrowly recognized `Allow ChatGPT to use …?` message). Enum/oneOf values are returned unchanged. The adapter recognizes exact `session` and `always` choices on `approval`/`persist` fields and explicit boolean `session`/`always` fields, adding the corresponding `_meta.persist` only for that explicit selection. Metadata alone never creates a choice. Generic `allow` never becomes persistent consent. Other scope conventions remain ordinary exact form values; Octo does not infer persistence from substrings. Conflicting durations cannot be submitted. Cancel and Decline remain distinct MCP actions. Tool questions have no protocol decline/cancel action: Cancel sends `answers: {}` and the UI explains this; Stop interrupts the turn.

## Ownership and lifecycle

`HarnessCapabilities`, `AgentInteraction`, `InteractionField`, and `AgentInteractionResponse` extend the existing contract. `ToolActivity` lives in Core and is optional on persisted messages; legacy archives still load. Views consume these neutral types and call generic AppStore actions. Codex wire types and mappings are entirely in OctoAgents.

Each harness owns its connection. Pending requests have fresh local UUIDs bound to the connection, turn generation, and typed wire request ID. Requests for another thread/turn are not presented. Duplicate IDs on a connection are ignored, including after resolution; a provider must use fresh IDs. Responses revalidate current ownership and values. Resolution, interruption, disconnect, completion, and shutdown invalidate pending UI. A prior card cannot answer a later request, even if remote thread/turn/request IDs repeat on a new connection. Startup checks after async version/initialize/thread calls prevent shutdown from launching a new server. AppStore also guards late send failures with the local run generation.

MCP activity uses connection/turn/item identity and updates one transcript entry. Duplicate starts, repeated progress/completion, and progress after terminal status are ignored. Unfinished calls become interrupted when the connection/turn ends. Restored running activity becomes historical interrupted activity on archive load, and shutdown writes activity after harness cleanup. Command/file approval closures now also check current identity before responding. Existing sandbox and reviewer mapping is retained; no permissive launch flags were introduced.

Result details are literal text, bounded to roughly 8 KiB of characters per update (plus truncation marker), with up to 16 content blocks, 16 array elements, 32 object keys per level and five structured levels. Arguments, `_meta`, binary content, and embedded app resources are omitted. Common credential keys and bearer/token patterns are redacted before display/persistence. Arbitrary prose can still contain unrecognized sensitive material; this is not a general secret detector. Raw request bodies and responses are not logged by the bridge.

## Configuration and setup

`CodexExecutable` chooses a custom executable first, otherwise the supported desktop bundle path and then PATH. The selected executable is used for model discovery and generation. `JSONLineProcess` starts `["app-server"]` in the thread checkout, inheriting Octo's process environment, including HOME/CODEX_HOME, with only the existing PATH augmentation and NO_COLOR override. It does not source a login shell or alter config/auth files. Fixture assertions verify cwd (including macOS `/tmp` canonicalization), inherited HOME, argv and unchanged permission/reviewer parameters.

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

## Protocol evidence and verification

Checked 2026-09-27 against the automatically selected bundled CLI **0.158.0-alpha.2.1**, app-server v2, using local `app-server generate-json-schema --experimental`. Relevant schemas: `McpServerElicitationRequestParams/Response`, `ToolRequestUserInputParams/Response`, `ItemStarted/CompletedNotification` (`mcpToolCall`), `McpToolCallProgressNotification`, `ServerRequestResolvedNotification`, and v1 `InitializeParams`. The form schema references MCP **2025-11-25**. No generated schema inspection starts a model turn.

The adapter probes the selected executable before connection startup. CLI 0.158+ opts into `experimentalApi` for questions and the documented compatibility flag `mcpServerOpenaiFormElicitation` for extended forms. Current generated schemas also describe an `extensions` map, but the documented compatibility flag remains available. Older/unrecognized installations retain stable form handling without the experimental opt-in; incoming unsupported extended requests are declined. A version check is an implementation baseline, not a promise about installed services or future schemas. Strict runtime form validation remains mandatory.

Primary references:

- [Official app-server documentation](https://learn.chatgpt.com/docs/app-server#mcp-server-elicitation-requests): request shapes, accept/decline/cancel and initialization capabilities.
- [Official MCP setup](https://learn.chatgpt.com/docs/extend/mcp?surface=cli): host/project configuration and CLI-owned login.
- [T3 Code PR #8058](https://github.com/pingdotgg/t3code/pull/8058), final patch `d232e13`: inspected runtime and test patches for app metadata, oneOf/enum choices, boolean persistence and exact response metadata. Feasibility evidence; Octo uses its own stricter form validation and neutral UI.
- [T3 Code issue #8318](https://github.com/pingdotgg/t3code/issues/8318): Windows native-pipe failure before app approval. No Windows workaround or configuration mutation was applied on macOS.

Verification: **67 Swift tests pass**, including fragmented fixture frames, tool deduplication/redaction/bounds, exact choices, generic Allow, persistent scopes, malformed forms, validation, decline/cancel, provider resolution, wrong thread/turn, concurrent connections, stale/duplicate responses, shutdown during version probing, disconnect, unsupported Claude behavior, and archive compatibility. Existing transport framing/resource-limit tests remain green.

Isolated native smoke used a separate app bundle identity, archive and repository, with `Scripts/fixtures/codex-interactions.py` selected as the executable. Verified visible app identity/choices outside collapsed work, no preselection, disabled Submit before selection, exact session and persistent responses, fresh unset next request, cancellation with null content, tool completion in the work disclosure, and question submission returning the selected answer. An initial fixture cwd assertion failed on `/tmp` versus `/private/tmp`; canonical-path comparison fixed it, then the flow passed.

**Real Computer Use availability through Octo: unknown. End-to-end real Computer Use/MCP/model call: not exercised.** The smoke test used the test runner's existing native UI access; that does not establish tool availability inside an Octo-launched Codex process. No integrations were installed, accounts authenticated, OS permissions granted, real target-app decisions submitted, or personal conversations/terminals modified. Claude is compile/fixture checked only. No live model calls were made.
