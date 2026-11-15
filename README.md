# Softwarekatalog

Windows self-service software catalog with WinGet and direct ArtCraft providers.

Users install approved software through a small GUI or request helper. User tools write request files to a controlled drop directory. A SYSTEM scheduled task validates those requests against Group Policy, queues approved work, then runs the appropriate SYSTEM provider.

## What It Does

- Reads allowed software from GPO registry policy.
- Lets users install/uninstall only catalog entries allowed by policy.
- Installs required software automatically.
- Blocks user removal of required software.
- Queues install, uninstall, and upgrade actions.
- Shows current queue task and progress in the GUI.
- Checks software updates every 2 hours, separately for each provider.
- Tracks installed state from WinGet export and verified ArtCraft MSI inventory, not request history.
- Detects registered applications installed into SYSTEM's AppData and repairs
  unambiguously identified, policy-approved packages by uninstalling/reinstalling.
- Polls user request files every minute; no long-lived user-facing daemon is required.

## Policy

ADMX templates live in `PolicyDefinitions/`.

Copy them to your domain Central Store:

```text
\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions\Softwarekatalog.admx
\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions\de-DE\Softwarekatalog.adml
\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions\en-US\Softwarekatalog.adml
```

Policy registry path:

```text
HKLM\Software\Policies\STL\Softwarekatalog
```

Catalog entries:

```text
HKLM\Software\Policies\STL\Softwarekatalog\Catalog
alias = PackageId|DisplayName|Description
```

Required software:

```text
HKLM\Software\Policies\STL\Softwarekatalog\Required
alias = 1
```

The client reads up to 500 catalog entries and 500 required entries.

## ArtCraft: current vendor releases and migration

Enable **ArtCraft-Anwendungen anbieten** in the Softwarekatalog GPO
(`EnableArtCraft` DWORD = `1` at the policy root; default off). Global `Enabled`
must also be on. This offers all 14 applications with the supplied German
descriptions, without individual `Catalog` registry entries. Enabling the
checkbox does **not** install all applications.

Use these existing **Required software / Verpflichtende Programme** aliases:

```text
photocraft vectorcraft filmcraft lightcraft pdfcraft effectcraft designcraft
texturecraft materialcraft wordcraft soundcraft deckcraft cadcraft gridcraft
```

For example, `Required\gridcraft = 1` installs GridCraft automatically when
required-software enforcement is enabled. The full application table and
security/migration design are in [the provider design](docs/artcraft-provider-plan.md).

The provider resolves the latest stable release in each official `storytold/*`
repository; it does not wait for WinGet manifests. It selects the **native x64
or ARM64 MSI**, requires the release SHA256, Windows Authenticode `Valid`, the
approved full publisher identity, the pinned MSI UpgradeCode and matching MSI
version/architecture. Missing or invalid releases fail closed, without silently
using emulation or an untrusted installer. Dual-context installers receive
`ALLUSERS=1`; TextureCraft and MaterialCraft use their per-machine profiles.

**Existing WinGet-managed installations migrate automatically on the next
SYSTEM queue pass after opt-in:**

- A verified healthy machine installation is adopted without network access or
  unnecessary uninstall/reinstall. Subsequent updates use the direct provider.
- A proven SYSTEM-AppData or wrong-architecture copy is removed using its exact
  registered MSI identity only **after** the new installer has been downloaded
  and completely verified. A machine install is then verified against the real
  registry/MSI scope, native architecture and expected Program Files executable.
- Ownership and recovery stages are atomically retained under
  `C:\ProgramData\__Softwarekatalog\ArtCraft\State.json`. The next SYSTEM worker
  resumes an interrupted migration, even if the old product is already gone.
  Earlier `Scope-Repairs.json` intents are bridged into this migration as well.
- WinGet upgrades run per package, never `upgrade --all`, and skip custom-owned
  ArtCraft IDs. Old policy aliases still resolve to the same application.

Disabling the checkbox removes built-in offers and stops new installs/updates;
it does not uninstall applications, discard ownership or let WinGet take them
back. Already-destructive recovery is still completed safely. Explicit old
WinGet policy entries that have never been adopted remain compatible.

Verified cached installers support transport-outage recovery; hash, signer,
identity or missing-native-asset errors never become a cache bypass. The GUI
shows provider, installed/target version, last check, stale metadata/error and
restart status. No downgrade, forced reboot, arbitrary registry uninstall
command, directory deletion or migration of ordinary users' installations is
performed. Do not delete either recovery journal after a failed migration.
Pilot production rollout: the CI exercises real Windows/MSI/security boundaries
with signed small fixtures, while real vendor downloads are verified read-only.

## Install

Build the ASCII-only distribution wrapper:

```sh
make dist
```

Use `dist/setup.ps1` for deployment. It is ASCII-only and decodes the UTF-8 payload at runtime, avoiding Windows PowerShell 5.1 encoding issues with downloaded scripts.

Run as admin or as computer startup script:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\dist\setup.ps1 -Mode Install
```

Generated files are written to:

```text
C:\ProgramData\__Softwarekatalog\
```

Runtime request files are written below:

```text
C:\ProgramData\__Softwarekatalog\Requests\
C:\ProgramData\__Softwarekatalog\AdminRequests\
C:\ProgramData\__Softwarekatalog\Processed\
C:\ProgramData\__Softwarekatalog\Failed\
```

### Additional installations on Windows Server

For privileged filesystem, archive, ArtCraft cache/state and WinGet provenance
hardening, including fail-closed upgrades of questionable existing service
paths, see [Privileged file and executable trust](docs/filesystem-security.md).

On Windows Server (including domain controllers), only administrators may
request additional package installations. **Start the catalog or
`Request-App.ps1` as administrator**: a UAC-filtered administrator session is
not sufficient. The existing `AllowUserInstalls` policy remains an upper bound;
disabling it also blocks these administrator requests.

Elevated server clients submit installations through `AdminRequests`, a
SYSTEM/Administrators-writable directory. The SYSTEM worker additionally checks
the actual NTFS file owner and current administrator membership, rather than
trusting requester names/SIDs or privileged queue metadata from request JSON.
All server installations submitted through the ordinary `Requests` directory or
legacy `-Mode ProcessRequest` CLI are rejected, even with a claimed admin/SYSTEM
identity. Existing user-install queue entries without the new authorization
provenance must be requested again as administrator. Membership is rechecked
before execution, including when a package appears already installed.

Deploy the updated setup with `-Mode Install` to create/protect the new input
directory and regenerate both clients. Required-software enforcement and
automatic SYSTEM updates remain operational; required aliases are checked
against current policy. Windows client editions retain ordinary-user self
service. Status requests and the existing uninstall policy are unchanged.

## Machine Scope and Existing SYSTEM-profile Installations

All normal installs, uninstalls and upgrades already use `--scope machine`.
This selects an eligible WinGet installer; it is not a universal instruction
that converts every installer into an all-users installation.

For `ArtCraft.GridCraft` and `ArtCraft.PdfCraft`, the vendor's dual-context MSI defaults to per-user.
The client therefore **appends** `--custom "ALLUSERS=1"` to its machine install
and upgrade commands. It does not use `--override`, change WinGet settings,
or send MSI properties to unrelated EXE installers. These verified MSI packages
are upgraded individually with that property. All remaining WinGet packages
are also upgraded individually, excluding IDs owned by the ArtCraft provider.
This legacy WinGet path applies only where the direct provider has not adopted
the package; the opt-in ArtCraft provider above is preferred for current releases.

References checked for GridCraft 0.16.0 and PDFCraft 0.18.1:

- [Vendor installation policy](https://github.com/storytold/gridcraft/blob/v0.16.0/packaging/windows/INSTALLATION.md)
- [Vendor WiX scope and cross-context checks](https://github.com/storytold/gridcraft/blob/v0.16.0/packaging/windows/install-policy.wxi)
- [WinGet installer manifest](https://github.com/microsoft/winget-pkgs/blob/master/manifests/a/ArtCraft/GridCraft/0.16.0/ArtCraft.GridCraft.installer.yaml)
- [PDFCraft 0.18.1 installation policy](https://github.com/storytold/pdfcraft/blob/v0.18.1/packaging/windows/INSTALLATION.md)
- [PDFCraft WinGet manifest and stable MSI identity](https://github.com/microsoft/winget-pkgs/blob/master/manifests/a/ArtCraft/PdfCraft/0.18.1/ArtCraft.PdfCraft.installer.yaml)

### Automatic repair

Deploy the rebuilt `dist/setup.ps1` using the usual `-Mode Install` command.
Deployment starts a SYSTEM queue worker even if no requests are pending. Each
subsequent worker pass (including the two-hour upgrade task) also checks for
repairs, **before** installed-state shortcuts and upgrades.

The repair pass:

1. Reads the 32-bit and 64-bit uninstall registrations in HKLM and SYSTEM's
   `HKEY_USERS\S-1-5-18` hive. It checks paths beneath
   `%SystemRoot%\System32\config\systemprofile\AppData` and the WOW64 aliases.
   MSI packages without an ARP install location are checked through executable
   component paths in the read-only cached MSI, preferring context-aware MSI APIs.
   Some legacy SYSTEM installations are invisible to extended component APIs;
   a classic current-user/machine lookup is allowed only for a single registered
   scope, including hidden/unnamed records. Conflicting user/machine registrations
   are never disambiguated by guessing. Cached
   icons and ordinary AppData settings are not treated as executable payloads.
   It does not use `Win32_Product`.
2. Maps a suspect installation to a currently allowed catalog package. GridCraft
   and PDFCraft have verified stable MSI UpgradeCodes; other packages require an unambiguous
   registration and exact WinGet name/source correlation to a catalog package ID.
   Catalog display labels do not have to match the registered application name.
3. Resolves and downloads a machine-scope installer **before removing anything**.
   If this fails (unsupported scope, source/network/hash failure, etc.), the old
   installation is retained and the error is logged.
4. Writes a durable repair intent to `Scope-Repairs.json`, then uninstalls the
   exact registered product in its original scope. If WinGet cannot find the
   correlated MSI/uninstall metadata, it uses `msiexec /x {validated-product-guid}
   /qn /norestart`. It never executes arbitrary registry uninstall command lines.
5. Checks that the old registration disappeared, reinstalls with machine scope,
   and verifies the result. For the verified ArtCraft MSI profiles this includes checking
   `ArtCraft\GridCraft\gridcraft.exe` (or `ArtCraft\PdfCraft\pdfcraft.exe`) under the applicable Program Files directory.
   An already valid machine copy is kept when only a stray SYSTEM-user copy
   needs removal.

This is a real uninstall/reinstall, **not** a folder move. Application data is
not copied into other users' profiles, and program directories are not manually
deleted. Ordinary users' installations and packages outside catalog policy are
not modified. Unregistered directories, ambiguous registrations and unidentified
packages are not safe to auto-migrate; detected registration-based suspects are
logged for review. There is no heuristic directory-only inventory/cleanup.

There is no transactional rollback across two installers. A failed reinstall or
an interrupted worker retains its repair intent, so the next worker can resume
even if the old product is already uninstalled. Machine-scope verification
failures also create an intent rather than reporting success. Do not delete
`Scope-Repairs.json` after a failure unless intentionally cancelling recovery.
Entries no longer allowed by policy are retained but not executed. Failed
repairs are excluded from the installed snapshot and block the general upgrade
pass so they are not silently treated as usable machine installations.

Review `C:\ProgramData\__Softwarekatalog\Logs\service.log` for
`SYSTEM-profile installation detected`, `repair completed`, or `repair failed`.
Each pass also logs an inventory summary with suspect/package counts and failed
MSI inspections. `Install/update completed successfully` refers to the catalog
service deployment, **not** to an application repair. A `Cannot inspect MSI`
warning is an incomplete inspection, not evidence that the package is healthy;
the warning includes its scope, attempted contexts and native Windows error codes.
The native MSI bridge deliberately supplies a true NULL SID inside C#: passing
PowerShell `$null` to a .NET string parameter would produce an empty string and
break context-sensitive MSI lookup. Repair journals are also normalized across
the different JSON-array pipeline behavior of Windows PowerShell 5.1 and PS7.
Failed attempts retain their downloaded installer under
`Scope-Repair-Download-<package-id>` for diagnosis/recovery; successful repairs
remove that temporary download directory. No reboot is triggered; if an MSI
requires one, restart the device before retrying. A repair can temporarily make
the application unavailable, so pilot the deployment on a test device first.

To request an immediate retry, an administrator can start the existing SYSTEM
task (do not run profile migration in an administrator's own user context):

```powershell
Start-ScheduledTask -TaskName 'Softwarekatalog - Queue'
```

## Tests

```sh
make test                       # requires pwsh
make test-static                # Python 3 + bash; distribution and policy XML
make dist
```

Or run `powershell.exe -NoProfile -File tests\Invoke-Tests.ps1` on Windows.
Each suite runs in its own child process with a timeout; logs and JUnit XML are
written to `test-results/`. The ordinary unit tests need no Pester/module install.

The [Windows CI](docs/ci.md) covers Windows Server 2022/2025 x64 and native Windows
11 ARM64, Windows PowerShell 5.1 and PowerShell 7, plus a deliberate x86-on-x64
PowerShell pass. Process/OS architectures are verified through the Windows API,
not inferred from runner labels or pointer width. In addition to file-backed
queue/policy/request and scope-repair regression tests, disposable hosted runners
test the actual deployment bootstrap, real SYSTEM tasks, MSI migration and a
real standard user's NTFS/registry permissions and application access. Releases
are gated on successful CI for their exact commit, including manual releases.

The deterministic integration fixture uses a controlled CLI adapter to isolate
upstream WinGet/network behavior; the MSI engine and OS security boundaries are
real, and registry inventory is restricted to real registrations of the fixture's
GUID. Production WinGet discovery prefers the native architecture and orders
package versions numerically. CI does not certify arbitrary third-party installers, domain GPO delivery,
or an interactive desktop GUI. See the coverage/limitations and safe invocation
instructions in [docs/ci.md](docs/ci.md); do not run the destructive integration
harness on a normal workstation.

## Notes

- Requires Windows. WinGet packages additionally require Desktop App Installer
  and `winget`; direct ArtCraft operations can continue if WinGet is unavailable.
- Catalog installs, uninstalls, exports, and automatic upgrades explicitly target
  the `winget` community source, so an unavailable Microsoft Store source does not block them.
- SYSTEM scheduled tasks validate and execute requests; keep catalog policy restricted to trusted admins.
- Package IDs and silent machine-scope support depend on upstream `winget` packages.
- Automatic scope repair additionally requires a WinGet version supporting
  `download --scope machine`; an unsupported command fails before uninstalling.
