---
name: codex-provider-switch-guard
description: Experimental OpenAI and DeepSeek provider switching guard for Windows Codex Desktop Stable. This release supports read-only status and checkpoint inspection.
---

The implementation includes guarded preflight, explicit approval, backup, atomic configuration replacement, and selective recovery. The released entry supports only the read-only operations below. Use Windows PowerShell 5.1 and [scripts/Switch-Provider.ps1](scripts/Switch-Provider.ps1). See the [README](README.md) for setup and the independent synthetic test command. Installation requires no changes to daily Codex configuration or system permissions.

- Use Status to report the configured provider, Stable package identity, and compatibility. Use Backups to inspect existing checkpoints and their integrity. Pass the absolute HomePath explicitly. Clarify which Home to inspect if ambiguous.
- The official compatibility list is empty ([]). This release has no RoundTripVerified record. If asked to preview or apply a production switch or restore, explain that the admission gate rejects production preflight and all writes in this release.
- Run synthetic checks only with the supplied harness, which creates independent temporary Homes. Real Desktop round trips, model requests, and compatibility with other Codex versions remain unverified.
