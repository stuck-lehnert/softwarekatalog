# Windows CI

The `CI` GitHub Actions workflow runs on pushes, pull requests and manual
dispatches. No self-hosted Windows machine, domain account or secret is required.
The Windows jobs use disposable **standard GitHub-hosted** `windows-2022` and
`windows-2025` x64 runners (Windows Server), plus **`windows-11-arm`** for native
Windows 11 ARM64. ARM64 is an additional required platform, not an x64 job
renamed after an ARM environment variable.
Billing/minute allowances depend on repository/account settings; this workflow
does not request larger or paid custom runner sizes.

## Layers

| Layer | Execution | What it checks |
| --- | --- | --- |
| Build/policy | Ubuntu, Python standard library | ASCII release wrapper; byte-exact base64 payload and build marker; UTF-8 bootstrap contract; ADMX/ADML XML, missing/duplicate resources and locale parity; generated payload is not tracked |
| Workflow validation | Pinned actionlint | Workflow syntax, expressions, dependencies and runner labels |
| Runtime architecture | Every Windows unit lane; orchestrator, every SYSTEM phase and standard-user process | Actual process and native OS machine types from `IsWow64Process2`; reject x64 emulation on ARM64; save process/OS/identity evidence; portable helper regressions distinguish native ARM64, native x64 and intentional x86-on-x64 |
| Core regression | Native PS5.1 and PS7 on Server 2022/2025 x64 and Windows 11 ARM64; additional PS5.1 x86-on-x64 | Actual temporary-file queue/snapshot transitions, deduplication, recovery, corrupt-file quarantine, catalog/required policy and request validation, size/depth/root limits and privilege/allowlist boundaries |
| Server authorization regression | Same seven engine/architecture lanes | Exact Server/domain-controller ProductType, fail-closed identity/OS lookup, elevation UX, private-input routing, current membership and old-queue rejection before shortcuts/dispatch, policy upper bounds, protected metadata, private retries/public flooding, client/Required/update/uninstall compatibility |
| Generated clients | Same engine matrix | Generate and parse the request helper and GUI, including apostrophes in paths; correct BOMs; VBS invocation; PS5.1 compiles GUI C# helpers and constructs Windows Forms controls without opening a modal dialog |
| Scope regression | Same engine matrix | Detection, identity correlation, MSI switch profiles, guarded uninstall/reinstall, recovery journal, PS5.1 JSON behavior, false-success rejection, snapshot filtering, upgrade ordering, native-before-emulated WinGet selection and numerical package-version ordering, the native NULL-SID bridge contract and a real read-only MSI lookup of a random unknown product (must return UNKNOWN_PRODUCT, not INVALID_PARAMETER) |
| SYSTEM integration | Server 2022/2025 x64 and Windows 11 ARM64, native PS5.1 and actual SYSTEM scheduled tasks | Deploy the real built bootstrap, compare the installed payload byte-for-byte, inspect task principals/settings and generated files/shortcuts; matching x64/ARM64 MSI with per-user defaults in SYSTEM AppData, inspecting its actual ARP scope; native cache/component lookups; migrate to Program Files and remove the old executable; second-pass idempotence; actual queued uninstall/reinstall; required-software restoration |
| Standard-user integration | New local non-admin token on the same disposable VM | Create requests using the generated helper; spoofed requester metadata cannot replace the real NTFS owner; tampering with privileged script/queue/journal/another owner's request and HKLM policy is denied; unapproved/oversized/array-root/required-uninstall requests are quarantined; the machine MSI executable and shared shortcut are accessible |
| Server administrator integration | Separate real local administrator account, filtered credential process and elevated Highest scheduled task | Native account/group lookup, filtered-token rejection on Server, elevated individual SID and enabled Administrators token, private admin input and real MSI install; standard-user create/move/hardlink rejection at the private input, administrator-owned public-file attack rejection, spoofed metadata and legacy queue/CLI denial; Windows 11 ARM64 retains standard-user installs |
| ArtCraft regression | Same seven native/intentional-x86 unit lanes | Exact built-in catalog and aliases, Required protection, provider dispatch without WinGet, atomic merged inventory, ownership after opt-out, release/redirect/download bounds, SHA256/publisher/MSI identity, cache failure classification, migration state/recovery and legacy repair intents |
| ArtCraft SYSTEM migration | Same three native SYSTEM platforms | Signed native fixture MSIs, healthy WinGet-to-custom adoption without reinstall/network, normal MSI upgrade, SYSTEM-AppData repair, Required shortnames without per-app GPO, WinGet exclusion after opt-out; kill the real SYSTEM worker immediately after successful uninstall and recover in a new SYSTEM process with the checkbox off |
| Real ArtCraft vendor trust | Native Server 2025 x64 and Windows 11 ARM64, actual SYSTEM | Read-only official stable download, release SHA256, Windows Authenticode Valid, exact approved publisher DN, pinned UpgradeCode and native MSI architecture/version; no fixture transport/signature override, MSI execution or vendor installation |

`fail-fast: false` keeps other matrix jobs running after a failure so their
diagnostics are not lost. The stable **`CI passed`** check only succeeds when
every build, unit and integration job succeeds; skipped/cancelled jobs do not
silently count as success. Configure that check as required in GitHub branch
protection/rulesets if merges should also be blocked. The workflow itself
cannot enforce repository merge rules without that administrator setting.

## Native ARM64 coverage and runner availability

The unit matrix has seven lanes: native PS5.1/PS7 on each of the two x64 Server
images, the deliberate PS5.1 x86-on-x64 lane, and native PS5.1/PS7 on
`windows-11-arm`. The SYSTEM matrix has three lanes, adding the same Windows 11
ARM64 image to the two x64 Server images. Standard-user security checks run in
each integration lane; ARM64 does not replace or skip the MSI lifecycle tests.

GitHub's [hosted-runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
lists `windows-11-arm` as an ARM64 standard runner for both public and private
repositories (checked 2026-11-13). The official
[Windows 11 ARM64 image manifest](https://github.com/actions/runner-images/blob/main/images/windows/Windows11-Arm64-Readme.md)
documents the installed tools. Public/private repository minute allowances,
regional capacity and account policy still apply. No larger/custom runner is
requested. If the runner or a native engine is unavailable, the lane must fail
or remain queued; it is not skipped and does not fall back to x64 emulation.

The workflow selects explicit Windows PowerShell/PowerShell 7 executable paths.
Before tests run, `tests/helpers/WindowsArchitecture.ps1` calls the real
[`kernel32!IsWow64Process2`](https://learn.microsoft.com/en-us/windows/win32/api/wow64apiset/nf-wow64apiset-iswow64process2)
API. A native ARM64 process must have `ProcessMachine=0` and
`NativeMachine=0xAA64`; pointer size and `PROCESSOR_ARCHITECTURE` alone are not
accepted as proof. Every suite is launched with that same engine and the
architecture suite independently checks its own process. The SYSTEM and
standard-user launchers perform the assertion in the very process that runs
their respective scenarios, recording the actual SID as well. The installed
fixture executable also checks its own native machine type before returning
success under the standard-user token.

Configuration/static checks on an x64 Linux developer machine are **not** a
native ARM64 execution result. Native Windows ARM64 support is verified only
when these required hosted lanes actually finish successfully. ARM32 and x64
application emulation on ARM64 are not substitutes for those lanes and are not
claimed as tested by them.

The production architecture audit also removed an architecture-blind WinGet
fallback: `Get-NativeWindowsArchitecture` identifies the host through
`IsWow64Process2` (with an older-Windows compatibility fallback), WindowsApps
discovery uses native `ProgramW6432` where available, and `Select-WingetPath`
prefers native ARM64/x64 packages before compatible emulated alternatives while
sorting package versions numerically. Scope regressions cover that selection
logic. This is not a claim that Microsoft's actual ARM64 WinGet distribution or
every vendor's ARM64 installer was exercised: the integration CLI boundary is
still the restricted MSI fixture adapter described below.

## Integration fixture and safety

`tests/windows/New-Fixture.ps1` builds a tiny executable and an isolated,
dual-context MSI using pinned WiX 5.0.2. Its product/upgrade GUIDs and install
directories are unique for each run. The executable validates its native
architecture and prints a test marker; it does not modify machine state.
WiX is installed with the lane's explicit `--arch x64` or `--arch arm64`;
the pinned tool package includes native ARM64 tooling. MSI builds use matching
`-arch x64`/`-arch arm64`, and the build reads the **actual MSI SummaryInformation
Template** to require `x64`/`Arm64`, respectively. The managed AnyCPU payload
uses the native .NET Framework CLR and refuses successful emulated execution;
this is not an x64 MSI relabeled as ARM64. Fixture configuration and architecture
evidence are retained with diagnostics.
The deterministic MSI fixture does not download or install ArtCraft applications.
The separate vendor-trust lanes download real installers but **never execute**
them. Every push/PR checks MaterialCraft (small stable package); weekly scheduled
runs and manual `all_artcraft=true` dispatches verify all 14 applications on both
native architectures. This separates reproducible migration correctness from
upstream availability and real Windows certificate-chain validation. The
`CI passed` gate includes vendor trust; network/publisher failures are not
silently accepted. Only small reports/logs, not vendor installers, are uploaded.

ArtCraft migration fixtures additionally use the production GridCraft/PdfCraft/
WordCraft family GUIDs and expected native install paths, with six small signed
MSIs for versions 1.0.0/1.1.0. The harness refuses pre-existing matching products
or directories. It trusts a disposable test certificate only on the throwaway
runner and removes it in cleanup. Only HTTP transport and the explicitly approved
fixture signer are substituted; production hash/AuthentiCode/MSI validation,
registry readers and MSI execution remain real. These fixture results are not
claims that all vendor applications have been installed or launched successfully.
Under SYSTEM, Windows Installer can register this per-user-default installation
in machine ARP despite its SYSTEM AppData payload. The test deliberately follows
the observed registration scope; install path alone is not a scope assertion.
Both registry scopes remain covered by the deterministic scope regressions.

`FixtureWinget.cs` is a deliberately restricted **CLI boundary adapter**, not a
claim that Microsoft's WinGet has been tested. It discovers real MSI
registrations, logs arguments and delegates install/uninstall to real
`msiexec.exe`. It accepts only the test package. MSI APIs, installer execution,
HKLM/HKCU, SYSTEM identity, standard-user token, NTFS permissions, source code,
policy/queue/worker logic and deployed payload are not mocked in this layer.
CLI discovery and asynchronous worker startup are replaced; processing is then
driven synchronously through the real worker loop. Additionally, the integration
inventory wrapper calls the **unmodified production registry reader** (including
its `IncludeUnnamed` option) and filters its real results to the fixture's unique
product GUID. Registry/MSI records are not fabricated. This avoids repeatedly
scanning component tables for the runner image's unrelated Visual Studio/MSI
estate; the fixture's real MSI identity, cache/component APIs and migration
assertions remain mandatory. Whole-machine inventory breadth is not claimed
by this isolated integration fixture.

The orchestrator refuses to run unless explicitly opted in on a GitHub-hosted,
native Windows x64 or ARM64, elevated Windows PowerShell 5.1 job whose process
and OS architectures both match the explicitly requested lane. It refuses pre-existing catalog
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
- `unit-<os>-<engine>`: separate stdout/stderr, per-suite JUnit XML and
  `architecture.json` with real process/OS evidence, 14 days.
- `system-<os>`: JSON case summary, actual task XML, deployment state/service
  logs, native MSI install/uninstall logs, SYSTEM transcripts, test-user results
  and CLI argument trace, plus orchestrator/builder/SYSTEM/standard-user
  architecture JSON and the fixture's actual MSI template, 14 days. No test
  password is included.

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
- Windows releases/images beyond the tested Server 2022/2025 x64 and Windows
  11 ARM64 runners, domain GPO delivery/refresh, endpoint security products,
  redirected profiles and organizational policies. The native ARM64 fixtures
  do not certify third-party ARM64 installers or emulated vendor applications.
- Transactional rollback across two different installers; durable repair intent
  improves recovery but cannot make uninstall+install atomic.

Pilot real package changes on an isolated Windows client in the target domain,
using SYSTEM and a second standard user. Live vendor-package smoke tests can be
added as a separate scheduled/manual lane, with explicit network/installer
allowlists, without making every PR depend on external package releases.
