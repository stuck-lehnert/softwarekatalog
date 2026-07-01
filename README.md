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

## Notes

- Requires Windows, Desktop App Installer, and `winget`.
- SYSTEM scheduled tasks validate and execute requests; keep catalog policy restricted to trusted admins.
- Package IDs and silent machine-scope support depend on upstream `winget` packages.
