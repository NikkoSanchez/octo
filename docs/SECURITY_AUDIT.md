# Security and privacy review

Reviewed 2026-09-26. The original pre-publication audit found no credential matches in the proposed source upload. Its actionable application findings have now been remediated as described below. This is source review and targeted testing, not a guarantee that the app or its dependencies have no vulnerabilities.

## Conversation storage policy

Conversations belong to the current Mac, in `~/Library/Application Support/Octo/workspace.json`, outside all source checkouts. Cloning Octo does not copy conversations, project paths, preferences, CLI credentials or editor configuration. Octo has no archive upload or conversation-sync feature. Workspace archives are refused inside Git repositories, including through symlinked parent directories.

Sending a message is still an explicit transmission to the selected CLI/provider of the message and attached code/images. Provider-side history, tools, hooks, MCP services and environment credentials follow the user's CLI configuration and approval policies. Local archive storage does not make cloud inference offline or prevent approved tools from reading local files.

The archive remains plaintext. Owner-only permissions prevent ordinary cross-account reads; they do not encrypt data or isolate it from processes running as the same account. Standard storage and archive files are excluded from macOS backups. This does not erase earlier backups or control third-party backup/sync software. Users should not relocate the storage directory into a cloud-sync folder.

## Findings and remediation

| Original finding | Implemented protection | Verification |
| --- | --- | --- |
| Transcript archive was `0644` in a `0755` directory | Default directory `0700`; files created `0600` before writing, atomic replacement, legacy tightening on load, backup exclusion; unsafe parent paths, symlinks and multiply-linked archives rejected | Persistence, migration, replacement, backup attribute and link rejection tests |
| Neovim socket directly in shared `/tmp` | `mkdtemp` creates a short, unique `0700` parent; socket retained for tab reuse and directory released with editor exit/tab lifetime | Private-directory permissions/path-length/cleanup unit test; native UI verification status below |
| Unbounded subprocess capture and waits | Nonblocking bounded pipe I/O; 8 MB combined output and 30-second default deadline for finite commands; 36 MiB outbound queue and 15-second stalled-write limit; process-group TERM then KILL after 300 ms; unrelated inherited descriptors closed | Dual-pipe/input tests, output cap, TERM-resistant deadline and cancellation/descendant tests |
| Complete protocol lines could bypass frame cap | Every complete, fragmented and final frame checked before decoding; background I/O waits for MainActor delivery instead of accumulating unbounded queued output | Complete, fragmented, EOF, Unicode and existing protocol fixture tests |
| Untracked previews had weaker containment | Both preview paths walk directory descriptors using `openat`/`O_NOFOLLOW`, reject symlink components and non-regular files, and bound reads to 2 MB even if a file grows | Both preview paths tested against traversal and ancestor links, plus file-type checks |
| Personal checkout path in docs | Removed | Source privacy scan |
| Personal Git author email | The initial local commit uses the account's GitHub noreply identity; setup configures it on new checkouts when authenticated `gh` is available and no local email is set; global identity remains independent | Inspect initial commit author and committer before publication |
| Accidental archive/credential commit | Ignore rules, staged-blob pre-commit check, history-aware pre-push check and CI check; archive detection examines JSON structure regardless of filename | Four Python tests, including an archive deleted in a later commit |
| Mutable CI action and implicit token access | Checkout pinned to `11d5960a326750d5838078e36cf38b85af677262` (current v4 reference, verified 2026-09-26); `contents: read`; `persist-credentials: false`; job timeout | Pinned reference verified through GitHub API; workflow inspected |

Default storage permissions on the development Mac were tightened without reading or editing conversation contents. A previously running app may still contain the old code: restart it after ending any active agent/terminal work to use the hardened persistence implementation.

## Upload contents

The original 60 candidate files (about 3 MB) contained source, tests, docs, build scripts, CI, Xcode project metadata, lockfiles and artwork. Build products, local Xcode state and actual conversation archives are excluded. Additional remediation files are source, tests and documentation only.

The retained original logo contains C2PA AI-generation provenance: generation timestamps, asset identifiers and provider attribution. No personal account identifier or credential was found. Derived icons contain color-space and dimension EXIF. The historical HTML prototype labels its conversation/terminal contents as illustrative; its form does not transmit them.

Local Codex checkpoint refs are not application history and must not be published. Push only the reviewed `main` branch; never mirror this working repository. Git metadata must also be reviewed because author/committer emails are part of commits.

The repository's privacy checker detects known key formats, credential filenames, personal home paths and Octo archive JSON. It prints file names and issue categories, never matched secret values. It cannot recognize every possible credential, encrypted/compressed archive, screenshot of private data or manually transformed transcript. Hooks can be bypassed by Git options, and CI runs after upload; review the exact content before pushing.

## Dependency review

Both lockfiles are retained. The community Ghostty wrapper remains pinned to `b7f888e3baf8585ea9d590ab1a45b49475e00d1c`, MSDisplayLink to 2.2.0 at `87eb0af130744c8cbe2e31b6e1a5bcd659f1c220`. The wrapper manifest fixes the binary archive SHA-256 to `804d4c92cad153eb8d85ed86f4c98ca587e90ff47ac0a62c846c985ece02a9c3`. No binary dependency was upgraded.

The [binary release metadata](https://github.com/Lakr233/libghostty-spm/releases/tag/upstream.3c47ca159368-2) names upstream commit `3c47ca159368eb4a860ffe5333abdf4a85b2767b`. GitHub's [source comparison with v1.3.0](https://github.com/ghostty-org/ghostty/compare/v1.3.0...3c47ca159368eb4a860ffe5333abdf4a85b2767b) reported 2,783 commits ahead and zero behind. That establishes source ancestry, not reproducibility of the downloaded binary.

[Ghostty's published advisories](https://github.com/ghostty-org/ghostty/security/advisories) were checked. The latest listed [paste/control-character issue](https://github.com/ghostty-org/ghostty/security/advisories/GHSA-4jxv-xgrp-5m3r) affects versions through 1.2.3 and is fixed in 1.3.0; the earlier listed advisories have earlier fix releases. The pinned source descends from that fix release. The wrapper and MSDisplayLink advisory pages could not be retrieved in this review, so absence of advisories for those projects is not established.

This is not an independent binary/source reproducibility audit, a comprehensive transitive vulnerability scan or a distribution-license review. The app is intentionally unsandboxed to operate local developer tools and uses ad-hoc signing. Provider tool sandboxing remains a separate boundary. Public distribution, notarization and a release license remain separate work.

## Validation and remaining limits

- 37 Swift tests passed after hardening, plus four privacy-check tests. No paid model calls.
- `Scripts/build-app.sh` and strict code-signature verification passed with the hardened process/terminal changes. `make setup` also built successfully from a clean, single-branch local clone.
- Native UI automation initially reported “Computer Use was not approved to use Octo.” An isolated app launched with a disposable archive, but this alone does not verify terminal UI behavior. Final verification is recorded in STATUS.md.
- All provider protocol policies remain unchanged: Codex app-server v2 requests `workspace-write`/`on-request`; Claude requests its default permission mode. Unsupported permission expansion is declined. Protocol framing and lifecycle were tested with local fake providers.
- Process groups cover ordinary descendants. Deliberately detached sessions are not contained; lifecycle cleanup is not a security sandbox. Long-lived agent sessions have frame/queue bounds but no total conversation-size limit. Whole-archive persistence and screenshot growth remain known scalability limits.
- Descriptor-relative previews deny symlink paths and avoid the earlier path-resolution race. A hostile process able to mutate the checkout or run as this user remains outside a complete filesystem sandbox.
- The external Gitleaks release lookup was declined during the initial audit. No Gitleaks or TruffleHog scan is claimed.

Before publication: scan the exact commit and its history, verify noreply commit identity, create the repository explicitly private, push only `main`, and verify GitHub visibility afterwards.
