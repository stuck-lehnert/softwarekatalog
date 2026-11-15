# Privileged file and executable trust

The service runs as SYSTEM. A filename inside ProgramData is not, by itself,
evidence that its contents or owner are trustworthy.

## Requests and diagnostic archives

- The worker opens input without following the final reparse point. One native
  handle binds size/link checks, owner/DACL inspection, bounded parsing and
  cleanup. Write and delete sharing are denied while the handle is held.
- Reparse objects, multiple hardlinks and files larger than 32 KiB are rejected
  before payload parsing. The original input is **never** moved into a trusted
  archive or given a privileged owner/DACL.
- Processed/Failed files are newly created protected files. At most 32 KiB of
  already-read UTF-8 payload is retained; otherwise a small rejection record is
  written instead. Error sidecars are limited to 2,048 characters. Cleanup
  deletes only the source name associated with the still-open handle.
- Transient queue failures leave the original request in its original input
  directory for a later authenticated retry. Old Failed archives are diagnostic
  only and are not replayed using their service-owned file identity. Submit a
  fresh request if an older failed operation still needs retrying.

## Service storage, upgrades and ArtCraft

Every privileged mode first creates or validates the service root, private
subdirectories and input boundaries. New directories receive their security
descriptor atomically. Existing objects are inspected **before** logging,
queue migration or recovery, not made trustworthy by applying new ACLs.

Only SYSTEM, built-in Administrators and TrustedInstaller may own trusted
objects. Effective untrusted write/delete/ACL/owner grants, null DACLs and
reparse points are rejected. Directory ancestor checks allow new child creation
and the standard ProgramData Users creation/EA/attribute subset (`0x116`), but
never deletion/replacement or owner/DACL changes of existing trusted children.
This exception does not apply to private leaf directories, files, executable
parents, state or cache storage. Explicit/protected child DACLs and foreign
owners are checked as well.
Request payloads themselves remain untrusted and are excluded from this private
data scan.

Journals, ArtCraft state and snapshots use checked, no-follow read handles and
protected atomic writers. ArtCraft verifies a downloaded/cached installer again
after acquiring a read-only content lease, then retains that lease through the
destructive migration/recovery and MSI invocation. The cache cannot be written,
deleted or exchanged by another process between verification and MSI use.

**Upgrade behavior:** a preoccupied service path, weak legacy child file, or
redirected cache causes a fail-closed error. Do not blindly reset permissions or
delete the state: first stop service tasks, investigate the path/owner/DACL and
contents from a trusted administrator session, and preserve recovery journals.
Only restore independently verified files or reinstall from a trusted release.
The setup deliberately does not automate promotion of questionable old data.

## WinGet provenance

PATH and AppX discovery supply candidates, not authority. Before ranking by
architecture and numeric version, the selector checks:

1. Protected local path, trusted owner/DACL and no reparse components.
2. Actual PE machine type, version and WinGet CLI product/original-file identity
   read from the locked executable, not from a plausible directory name.
3. Successful native Authenticode verification, revocation checks, Microsoft's
   production-root policy and the exact Microsoft Corporation signer
   organization. Offline/revocation/trust failures are not bypassed.
4. For AppX candidates, the exact Microsoft DesktopAppInstaller package family,
   manifest publisher/identity/version/architecture and installation containment.
   Negative AppX metadata cannot fall back to the portable path. A genuine
   portable executable still requires all executable/path provenance checks.

The chosen executable stays open without write/delete sharing until the worker
mode finishes. All rejected/unselected handles are disposed.

## Regression coverage and limits

Portable suites exercise policy masks, archive bounds, dispatch, actual bounded
PE parsing and selection/lease cleanup. Native SYSTEM scenarios on Windows
Server x64 and native Windows ARM64 additionally check real hardlinks, symbolic
links, owner/DACL preservation, preoccupied roots, writable child state and
sharing violations. The WinGet scenario downloads an official Microsoft native
MSIX bundle and verifies the real executable without registering or running it.
Existing signed MSI fixtures still test real installation/migration/recovery.

These controls protect against non-administrative callers. They do not defend
against a malicious administrator/SYSTEM principal, kernel compromise or an
already-modified deployed script. CI uses disposable hosted machines, not
enterprise endpoints, and does not claim an exploit against protected OS files.
