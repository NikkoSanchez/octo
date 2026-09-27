# Adding a harness

1. Add an identifier and title to OctoCore/HarnessID. Changing persisted enum values requires a migration.
2. Implement MainActor AgentHarness in OctoAgents. Map provider streaming, activity, session identity, approvals, failure and completion into AgentEvent.
3. Register executable detection, capabilities and construction in HarnessRegistry. Show missing capabilities in the UI instead of emulating authorization.
4. Keep provider process/transport details out of OctoApp. Respect the supplied working directory, preserve remote session IDs, and implement interrupt and shutdown. Handle AgentSettings explicitly: forward supported model/reasoning choices or reject unsupported overrides; never silently ignore them. Keep model discovery and supported-effort decoding in OctoAgents. Advertise supported permission options and their default in HarnessDescriptor, map AgentSettings.permissionMode inside the adapter, and apply it on every new/resumed/subsequent turn; reject unsupported overrides instead of broadening access. Expose account windows via HarnessRegistry.usage/AgentUsage and optional usage events only when a documented provider endpoint exists. Preserve unknown values and reset dates, and never estimate account quotas from conversation token counts. Emit provider-supplied reasoning summaries as reasoningDelta and commentary as activity/activityDelta so the common chat UI can collapse details without hiding final answers or approval requests.
5. Add a local fake-process fixture for fragmented frames, completion, errors and approvals. Never make billable requests in the test suite.
6. Verify locally with an authenticated CLI only when authorized. Record tested versions in STATUS.md.

Current registry is compiled in, not a runtime plugin system. A future external adapter API needs versioning, stable capability IDs, persistence migration and explicit trust/permission boundaries.

References: [Codex app-server](https://developers.openai.com/codex/app-server) and [Claude Code headless usage](https://code.claude.com/docs/en/headless). Codex protocol schemas can be regenerated from the locally installed CLI with `codex app-server generate-json-schema --out /tmp/octo-schema`.

## Tool activity and native interactions

Extend the existing adapter; no plugin framework or SwiftUI provider switch is needed:

1. Declare `HarnessCapabilities` individually. Inventory, forms, questions, app access, text results, and structured results are independent. False means unimplemented in this adapter; true does not mean the user's account has a tool installed. Keep unsupported controls/diagnostics honest.
2. Map provider tool start/progress/completion/failure into `AgentEvent.toolActivity(ToolActivity)`. Assign a connection/turn/item identity, deduplicate events and cap/redact details before emitting them. Never expose arguments, credentials or arbitrary binary data in activity. Persisted `ChatMessage.toolActivity` is optional for old archives.
3. Decode provider requests into `AgentInteraction` and typed fields/options. The common `InteractionCard` handles text, boolean, number/integer and single-choice fields. Emit `interactionUnavailable` for unsupported schemas; do not hide a required decision in work details or silently drop constraints. Avoid secret-input forms; use the CLI's auth workflow.
4. Implement `respond(to:with:)`, validating the response against the original request again. Preserve advertised values, scopes and distinctions between submit/decline/cancel. The provider adapter owns exact wire encoding. Never infer persistent permission from generic approval or submit a preselected default.
5. Bind fresh UI IDs to connection, local turn generation, remote thread/turn and typed provider request ID. Reject stale/wrong-owner/duplicate responses. Emit `interactionResolved` on user response or provider resolution; invalidate on interrupt, disconnect, completion and shutdown. Protect asynchronous startup from cancellation and prior-turn errors.
6. Keep configuration, MCP connections, authentication, execution and permission policies in the CLI. Launch the supplied executable with argument arrays in the supplied checkout/environment. Do not implement separate MCP transport or credentials in Octo, and do not restart active work to inspect configuration.
7. Record selected-executable schema/version evidence and explicit experimental opt-ins. Add fake-process fixtures for the supported schemas and lifecycle, including app identity and each access scope. Test concurrency, malformed constraints, provider resolution and backward-compatible persistence. Native fixture smoke tests must use a separate app identity/archive and no real authorization changes.

See [the current Codex bridge and protocol references](CLI_MCP.md). `Scripts/fixtures/codex-interactions.py` is an offline app-server stand-in, not an MCP server or model. Claude's inherited print workflow remains unchanged; it must not advertise interactive forms until its adapter implements and verifies a corresponding provider protocol.
