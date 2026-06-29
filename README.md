# Softwarekatalog

Windows self-service software catalog backed by `winget`.

Users install approved software through a small GUI or request helper. A SYSTEM scheduled task runs a named-pipe daemon, authenticates the connecting Windows user, validates requests against Group Policy, then runs `winget install --scope machine`.

## What It Does

- Reads allowed software from GPO registry policy.
- Lets users install/uninstall only catalog entries allowed by policy.
- Installs required software automatically.
- Runs `winget upgrade --all` every 2 hours.
- Tracks installed state from `winget export`, not from request history.

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

Run as admin or as computer startup script:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Mode Install
```

Generated files are written to:

```text
C:\ProgramData\__Softwarekatalog\
```

## Notes

- Requires Windows, Desktop App Installer, and `winget`.
- The daemon runs as `LocalSystem`; keep catalog policy restricted to trusted admins.
- Package IDs and silent machine-scope support depend on upstream `winget` packages.
