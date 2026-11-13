# Softwarekatalog

Windows self-service software catalog backed by `winget`.

Users install approved software through a small GUI or request helper. User tools write request files to a controlled drop directory. A SYSTEM scheduled task validates those requests against Group Policy, queues approved work, then runs a SYSTEM `winget` worker.

## What It Does

- Reads allowed software from GPO registry policy.
- Lets users install/uninstall only catalog entries allowed by policy.
- Installs required software automatically.
- Blocks user removal of required software.
- Queues install, uninstall, and upgrade actions.
- Shows current queue task and progress in the GUI.
- Runs `winget upgrade --all` every 2 hours.
- Tracks installed state from `winget export`, not from request history.
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
C:\ProgramData\__Softwarekatalog\Processed\
C:\ProgramData\__Softwarekatalog\Failed\
```

## Machine Scope and Existing SYSTEM-profile Installations

All normal installs, uninstalls and upgrades already use `--scope machine`.
This selects an eligible WinGet installer; it is not a universal instruction
that converts every installer into an all-users installation.

For `ArtCraft.GridCraft`, the vendor's dual-context MSI defaults to per-user.
The client therefore **appends** `--custom "ALLUSERS=1"` to its machine install
and upgrade commands. It does not use `--override`, change WinGet settings,
or send MSI properties to unrelated EXE installers. GridCraft is upgraded
individually with that property before the general `upgrade --all` pass.

References checked for GridCraft 0.16.0:

- [Vendor installation policy](https://github.com/storytold/gridcraft/blob/v0.16.0/packaging/windows/INSTALLATION.md)
- [Vendor WiX scope and cross-context checks](https://github.com/storytold/gridcraft/blob/v0.16.0/packaging/windows/install-policy.wxi)
- [WinGet installer manifest](https://github.com/microsoft/winget-pkgs/blob/master/manifests/a/ArtCraft/GridCraft/0.16.0/ArtCraft.GridCraft.installer.yaml)

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
   component paths in the read-only cached MSI, using context-aware MSI APIs
   to distinguish user/machine copies even with the same product GUID. Cached
   icons and ordinary AppData settings are not treated as executable payloads.
   It does not use `Win32_Product`.
2. Maps a suspect installation to a currently allowed catalog package. GridCraft
   has a verified stable MSI UpgradeCode; other packages require an unambiguous
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
   and verifies the result. For GridCraft this includes checking
   `ArtCraft\GridCraft\gridcraft.exe` under the applicable Program Files directory.
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
make dist
```

Or run `powershell.exe -NoProfile -File tests\Test-ScopeRepairs.ps1` on Windows.
The dependency-free regression suite uses mocked registry/MSI/WinGet boundaries;
CI runs it with Windows PowerShell 5.1 and PowerShell 7. It covers detection,
policy/identity guards, uninstall/reinstall order, durable recovery, MSI fallback,
machine-scope verification and installer/upgrade arguments. It does not replace
a real SYSTEM-context installation/uninstallation test on Windows. In particular,
verify the all-users Start menu entry and launch GridCraft as a standard second
user after deployment.

## Notes

- Requires Windows, Desktop App Installer, and `winget`.
- Catalog installs, uninstalls, exports, and automatic upgrades explicitly target
  the `winget` community source, so an unavailable Microsoft Store source does not block them.
- SYSTEM scheduled tasks validate and execute requests; keep catalog policy restricted to trusted admins.
- Package IDs and silent machine-scope support depend on upstream `winget` packages.
- Automatic scope repair additionally requires a WinGet version supporting
  `download --scope machine`; an unsupported command fails before uninstalling.
