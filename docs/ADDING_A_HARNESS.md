# Adding a harness

1. Add an identifier and title to OctoCore/HarnessID. Changing persisted enum values requires a migration.
2. Implement MainActor AgentHarness in OctoAgents. Map provider streaming, activity, session identity, approvals, failure and completion into AgentEvent.
3. Register executable detection, capabilities and construction in HarnessRegistry. Show missing capabilities in the UI instead of emulating authorization.
4. Keep provider process/transport details out of OctoApp. Respect the supplied working directory, preserve remote session IDs, and implement interrupt and shutdown. Handle AgentSettings explicitly: forward supported model/reasoning choices or reject unsupported overrides; never silently ignore them. Keep model discovery and supported-effort decoding in OctoAgents. Advertise supported permission options and their default in HarnessDescriptor, map AgentSettings.permissionMode inside the adapter, and apply it on every new/resumed/subsequent turn; reject unsupported overrides instead of broadening access. Expose account windows via HarnessRegistry.usage/AgentUsage and optional usage events only when a documented provider endpoint exists. Preserve unknown values and reset dates, and never estimate account quotas from conversation token counts. Emit provider-supplied reasoning summaries as reasoningDelta and commentary as activity/activityDelta so the common chat UI can collapse details without hiding final answers or approval requests.
5. Add a local fake-process fixture for fragmented frames, completion, errors and approvals. Never make billable requests in the test suite.
6. Verify locally with an authenticated CLI only when authorized. Record tested versions in STATUS.md.

Current registry is compiled in, not a runtime plugin system. A future external adapter API needs versioning, stable capability IDs, persistence migration and explicit trust/permission boundaries.

References: [Codex app-server](https://developers.openai.com/codex/app-server) and [Claude Code headless usage](https://code.claude.com/docs/en/headless). Codex protocol schemas can be regenerated from the locally installed CLI with `codex app-server generate-json-schema --out /tmp/octo-schema`.
