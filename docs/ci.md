# Windows CI

The `CI` GitHub Actions workflow runs on pushes, pull requests and manual
dispatches. No self-hosted Windows machine, domain account or secret is required.
The Windows jobs use disposable **standard GitHub-hosted** `windows-2022` and
`windows-2025` runners (Windows Server, not Windows 10/11 desktop images).
Billing/minute allowances depend on repository/account settings; this workflow
does not request larger or paid custom runner sizes.

## Layers

| Layer | Execution | What it checks |
| --- | --- | --- |
| Build/policy | Ubuntu, Python standard library | ASCII release wrapper; byte-exact base64 payload and build marker; UTF-8 bootstrap contract; ADMX/ADML XML, missing/duplicate resources and locale parity; generated payload is not tracked |
| Workflow validation | Pinned actionlint | Workflow syntax, expressions, dependencies and runner labels |
| Core regression | PS5.1 and PS7 on Server 2022/2025; additional PS5.1 x86 | Actual temporary-file queue/snapshot transitions, deduplication, recovery, corrupt-file quarantine, catalog/required policy and request validation, size/depth/root limits and privilege/allowlist boundaries |
| Generated clients | Same engine matrix | Generate and parse the request helper and GUI, including apostrophes in paths; correct BOMs; VBS invocation; PS5.1 compiles GUI C# helpers and constructs Windows Forms controls without opening a modal dialog |
| Scope regression | Same engine matrix | Detection, identity correlation, MSI switch profiles, guarded uninstall/reinstall, recovery journal, PS5.1 JSON behavior, false-success rejection, snapshot filtering, upgrade ordering, the native NULL-SID bridge contract and a real read-only MSI lookup of a random unknown product (must return UNKNOWN_PRODUCT, not INVALID_PARAMETER) |
| SYSTEM integration | Server 2022/2025, actual SYSTEM scheduled tasks | Deploy the real built bootstrap, compare the installed payload byte-for-byte, inspect task principals/settings and generated files/shortcuts; real per-user MSI in SYSTEM AppData; native cache/component lookups; migrate to Program Files; second-pass idempotence; actual queued uninstall/reinstall; required-software restoration |
| Standard-user integration | New local non-admin token on the same disposable VM | Create requests using the generated helper; spoofed requester metadata cannot replace the real NTFS owner; tampering with privileged script/queue/journal/another owner's request and HKLM policy is denied; unapproved/oversized/array-root/required-uninstall requests are quarantined; the machine MSI executable and shared shortcut are accessible |

`fail-fast: false` keeps other matrix jobs running after a failure so their
diagnostics are not lost. The stable **`CI passed`** check only succeeds when
every build, unit and integration job succeeds; skipped/cancelled jobs do not
silently count as success. Configure that check as required in GitHub branch
protection/rulesets if merges should also be blocked. The workflow itself
cannot enforce repository merge rules without that administrator setting.

## Integration fixture and safety

`tests/windows/New-Fixture.ps1` builds a tiny executable and an isolated,
dual-context MSI using pinned WiX 5.0.2. Its product/upgrade GUIDs and install
directories are unique for each run. The executable only prints a test marker.
No ArtCraft application, vendor account or paid installer is downloaded.

`FixtureWinget.cs` is a deliberately restricted **CLI boundary adapter**, not a
claim that Microsoft's WinGet has been tested. It discovers real MSI
registrations, logs arguments and delegates install/uninstall to real
`msiexec.exe`. It accepts only the test package. MSI APIs, installer execution,
HKLM/HKCU, SYSTEM identity, standard-user token, NTFS permissions, source code,
policy/queue/worker logic and deployed payload are not mocked in this layer.
The two replaced function boundaries are CLI discovery and asynchronous worker
startup; processing is then driven synchronously through the real worker loop.

The orchestrator refuses to run unless explicitly opted in on a GitHub-hosted,
Windows x64, elevated Windows PowerShell 5.1 job. It refuses pre-existing catalog
directories/policy/tasks/shortcuts. It temporarily creates the real catalog
deployment, a local test account and test MSI registrations; cleanup is attempted
in `finally`, and the hosted VM is discarded after the job. Production polling
and upgrade tasks are stopped/disabled immediately after deployment: the runner's
other installed software must never be upgraded by the test.

**Do not remove the guard to try this on a workstation/domain member.** To adapt
these tests for self-hosting, use a fresh, isolated, throwaway VM per job, review
the cleanup boundaries and network trust, and never expose a persistent runner
or production credentials to pull-request code.

## Local commands and diagnostics

```sh
make test-static
make test                         # pwsh, isolated suites + JUnit XML
make dist
```

```powershell
# Ordinary, non-destructive tests on Windows:
powershell.exe -NoProfile -File tests\Invoke-Tests.ps1
pwsh.exe -NoProfile -File tests\Invoke-Tests.ps1
```

To exercise the destructive integration suite, use **Actions -> CI -> Run
workflow**. The workflow installs the fixture compiler and supplies its path
and the explicit opt-in. A raw integration-script invocation is intentionally
not a supported local developer command.

Artifacts (uploaded even on failures):

- `distribution`: the exact ASCII bootstrap used by SYSTEM integration, 7 days.
- `unit-<os>-<engine>`: separate stdout/stderr and per-suite JUnit XML, 14 days.
- `system-<os>`: JSON case summary, actual task XML, deployment state/service
  logs, native MSI install/uninstall logs, SYSTEM transcripts, test-user results
  and CLI argument trace, 14 days. No test password is included.

Open the failed step first; then inspect the artifact's transcript or MSI log.
An artifact-upload or fixture/tool download failure is not converted into a
passing test. Rerun transient infrastructure failures rather than weakening the
assertion or adding blanket `continue-on-error`.

## Release gate and trust boundary

Automatic releases no longer run concurrently with unverified push builds.
`Release` listens for successful `CI` completion **only for a push in this
repository to main/master**, checks out the CI run's exact `head_sha`, rebuilds
with that SHA embedded, then packages/releases it. A privileged `workflow_run`
job never downloads or executes PR/fork-produced artifacts. It rejects PR events
even when CI is green. Manual releases on main/master call the same reusable CI
first; a manual dispatch is not a test bypass.

The normal CI has only `contents: read`, no inherited release secrets, and
checkout does not persist credentials. Only the final gated release job has
`contents: write`/the existing optional release token. Actions are pinned to
verified commit SHAs. Updating those pins and WiX/actionlint versions should be
a reviewed dependency change.

## What remains outside the guarantee

- Actual WinGet source availability, installer selection, source/authentication
  behavior and all current/future third-party packages. Unit tests validate the
  expected CLI arguments; the deterministic adapter is not live WinGet.
- Interactive GUI clicking/rendering, shell sessions, reboot/power-loss rollback,
  and OS upgrades. GUI syntax/helper/control tests are not desktop UI automation.
- Windows 10/11 client-specific behavior, ARM64, domain GPO delivery/refresh,
  endpoint security products, redirected profiles and organizational policies.
- Transactional rollback across two different installers; durable repair intent
  improves recovery but cannot make uninstall+install atomic.

Pilot real package changes on an isolated Windows client in the target domain,
using SYSTEM and a second standard user. Live vendor-package smoke tests can be
added as a separate scheduled/manual lane, with explicit network/installer
allowlists, without making every PR depend on external package releases.
