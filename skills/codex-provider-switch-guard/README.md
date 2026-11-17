# Codex Provider Switch Guard

**Experimental** implementation of guarded OpenAI and DeepSeek provider switching for Windows PowerShell 5.1 and Codex Desktop Stable. The code includes the switching and recovery workflow. This release exposes read-only Status and Backups, plus synthetic tests in disposable Homes.

The shipped [compatibility list](scripts/verified-desktop.json) is empty ([]) and has no RoundTripVerified record. The admission gate rejects production preflight, switching, and restore writes in this release. Compatibility with other Codex versions is unverified.

## Implemented switching and recovery

1. **Preflight.** Inspect the selected Home and its TOML structure, build the proposed configuration, and report the managed changes, destination provider, and applicable backup. Preflight performs no writes and launches no CLI.
2. **Identity and admission.** Discover the CLI from the current user's registered Stable package. Check package identity, CLI hash, and the admitted catalog identity. The exact tuple must have a RoundTripVerified record for production changes.
3. **Explicit approval.** Present the plan for user confirmation. The approval token is bound to the operation, config and candidate hashes, CLI identity, catalog identity, and any selected backup. Recheck the plan before writing.
4. **Protected write.** Require Codex processes to be closed, take an exclusive writer lock, and parse the candidate with the verified CLI in a disposable Home. Verify the live config hash before an atomic replacement that retains the previous config as a checkpoint.
5. **Selective recovery.** Validate the selected checkpoint and its hash, then restore the supported provider fields against the current file. Preserve unrelated settings and apply the same confirmation and write safeguards.

These mechanisms are implemented and exercised by the synthetic tests below. The shipped admission gate keeps the production write path locked.

## Install and inspect

Place this folder in a Skill location supported by your agent, or run the script directly from this folder. Installation requires no changes to daily Codex configuration or system permissions. Use an explicitly selected Home. Both operations below are read-only and require an existing config.toml.

~~~powershell
$guard = '.\scripts\Switch-Provider.ps1'
$inspectHome = Read-Host 'Absolute path of the Codex Home to inspect'
& $guard -HomePath $inspectHome -Action Status
& $guard -HomePath $inspectHome -Action Backups
~~~

Status reports the configured provider separately from the installed Stable package identity and compatibility. Backups lists existing checkpoints and validates their integrity. The configuration reader supports ordinary tables, single-line scalars, and simple single-line arrays for unmanaged fields. It rejects unsupported structures rather than guessing.

## Verified evidence

- The candidate passed 40 synthetic isolation checks, including preflight, simulated bidirectional changes, preservation of unmanaged fields, and checkpoint recovery.
- A separate acceptance copy passed 23 synthetic checks for its restricted test entry. That copy and entry are excluded from this release.
- The real CLI shipped with Stable 26.1111.2228.0 was tested offline using features list, separate temporary Homes, and manually disconnected networking. It accepted valid TOML and a synthetic catalog and rejected their malformed controls. A separate two-case run accepted the independently authored DeepSeek catalog and rejected its damaged copy. The recorded fixture hashes remained unchanged. These results establish CLI parsing and catalog loading for the tested inputs only. The runs used environment-scoped Homes without a host-wide access audit.

## Not yet verified

A real Desktop round trip from OpenAI to DeepSeek and back, including Desktop Home selection, authentication, effective provider routing, and live model requests, has yet to be verified. Offline CLI parsing does not establish these behaviors.

## Run the synthetic suite

To run the synthetic suite in a separate Windows PowerShell 5.1 process, install Python 3.11+ for the independent TOML checks. The harness creates disposable fixture Homes and compiles a mock CLI. It uses synthetic credentials and does not require access to daily Codex configuration.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run.ps1
~~~

The execution-policy setting above applies only to that PowerShell process.

## Source and license

The switch core in [Common.ps1](scripts/Common.ps1) comes from this project's locally maintained FINAL-v6 tool. The repository's [MIT License](../../LICENSE) covers this Skill. Windows PowerShell, Python, and Codex Desktop are external dependencies. The release includes only the synthetic catalog fixture. Historical and independently authored live catalog candidates, real configuration, credentials, and internal test artifacts remain outside the release.
