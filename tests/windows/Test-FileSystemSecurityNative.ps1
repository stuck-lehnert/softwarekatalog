# Disposable CI only; inherits production functions from the deployed payload.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
    throw 'Native filesystem tests require the actual SYSTEM token.'
}

if (-not ('Softwarekatalog.Tests.RequestDirectoryProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Softwarekatalog.Tests {
    public static class RequestDirectoryProbe {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeviceIoControl(SafeFileHandle file, uint code,
            byte[] input, uint size, IntPtr output, uint outputSize, out uint returned, IntPtr overlapped);

        public static SafeFileHandle OpenWrite(string path) {
            // FILE_WRITE_DATA on a directory: required to set a reparse point.
            SafeFileHandle handle = CreateFileW(path, 2, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (!handle.IsInvalid) return handle;

            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error);
        }

        public static void SetJunction(string path, string target) {
            string substitute = @"\??\" + target;
            byte[] names = System.Text.Encoding.Unicode.GetBytes(substitute + "\0" + target + "\0");
            byte[] buffer = new byte[16 + names.Length];
            // REPARSE_DATA_BUFFER header: tag, data length, reserved (zero).
            BitConverter.GetBytes(0xa0000003u).CopyTo(buffer, 0);
            BitConverter.GetBytes(checked((ushort)(8 + names.Length))).CopyTo(buffer, 4);

            // MountPoint: substitute offset 8 stays zero; its length is at10,
            // print offset/length at12/14. All offsets refer to PathBuffer16.
            BitConverter.GetBytes(checked((ushort)(substitute.Length * 2))).CopyTo(buffer, 10);
            BitConverter.GetBytes(checked((ushort)(substitute.Length * 2 + 2))).CopyTo(buffer, 12);
            BitConverter.GetBytes(checked((ushort)(target.Length * 2))).CopyTo(buffer, 14);
            names.CopyTo(buffer, 16);
            SetReparseData(path, 0x900a4, buffer);
        }

        public static void ClearJunction(string path) {
            byte[] buffer = new byte[8];
            BitConverter.GetBytes(0xa0000003u).CopyTo(buffer, 0);
            SetReparseData(path, 0x900ac, buffer);
        }

        private static void SetReparseData(string path, uint code, byte[] buffer) {
            using (SafeFileHandle handle = OpenWrite(path)) {
                uint returned;
                if (!DeviceIoControl(handle, code, buffer, (uint)buffer.Length,
                    IntPtr.Zero, 0, out returned, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }
}
'@
}

function Check-Security($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Expect-SecurityRejection([scriptblock]$Body) {
    try { & $Body | Out-Null }
    catch { return }

    throw 'An untrusted filesystem object was accepted.'
}

function Invoke-FixtureAcl([string[]]$Arguments) {
    & "$env:SystemRoot\System32\icacls.exe" @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the isolated ACL fixture.' }
}

function Expect-SharingViolation([scriptblock]$Body) {
    try { & $Body }
    catch {
        $cause = $_.Exception.GetBaseException()
        if (($cause.HResult -band 0xffff) -eq 32) { return }

        throw "Expected sharing violation 32, not '$cause'."
    }

    throw 'A live content lease allowed mutation or replacement.'
}

Assert-TrustedFileSystemPath -Path $Root -Directory
$work = Join-Path $Root ('NativeSecurity-' + [guid]::NewGuid().ToString('N'))
New-TrustedDirectory -Path $work
$junction = $null
try {
    $BaseDir = Join-Path $work 'Service'
    Initialize-ServiceStorage
    $RequestsDir = Join-Path $BaseDir 'Requests'
    $FailedRequestsDir = Join-Path $BaseDir 'Failed'
    Assert-TrustedFileSystemPath -Path $RequestsDir -Directory -PublicDrop
    Assert-TrustedFileSystemPath -Path $FailedRequestsDir -Directory
    Write-Output 'PASS FileSystemNative atomic storage has trusted private and public-drop ACLs'

    $target = Join-Path $work 'protected-target.json'
    Write-TrustedText -Path $target -Value ('x' * 65536)
    $beforeHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    $beforeAcl = (Get-Acl -LiteralPath $target).Sddl
    $hardlink = Join-Path $RequestsDir 'hardlink.json'
    New-Item -ItemType HardLink -Path $hardlink -Target $target | Out-Null
    $stream = Open-RequestFileRead -Path $hardlink
    try {
        $info = Get-OpenRequestFileInformation -Stream $stream
        Check-Security ($info.Links -eq 2 -and $stream.Length -gt 32768) 'Hardlink/size fixture was not real.'
        Complete-RequestFile -Path $hardlink -DestinationDir $FailedRequestsDir -Stream $stream -Raw $null -ErrorMessage 'Rejected multi-link oversized input'
    }
    finally { $stream.Dispose() }

    $archive = Join-Path $FailedRequestsDir 'hardlink.json'
    Check-Security (-not (Test-Path -LiteralPath $hardlink)) 'Handle-bound source deletion failed.'
    Check-Security ((Get-Item -LiteralPath $archive).Length -lt 1024) 'Rejected input was copied without a bound.'
    Check-Security (-not (Read-TrustedText $archive | ConvertFrom-Json).PayloadRetained) 'Rejected payload was retained.'
    Check-Security ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $beforeHash) 'Hardlink target bytes changed.'
    Check-Security ((Get-Acl -LiteralPath $target).Sddl -eq $beforeAcl) 'Hardlink target owner/DACL changed.'
    Write-Output 'PASS FileSystemNative hardlink archive is new/bounded; target bytes and owner/DACL stay unchanged'

    $link = Join-Path $RequestsDir 'reparse.json'
    New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null
    $stream = $null
    try {
        try { $stream = Open-RequestFileRead -Path $link }
        catch { Write-Output 'PASS FileSystemNative OS refused opening the reparse object itself' }

        if ($null -ne $stream) {
            Check-Security (Get-OpenRequestFileInformation -Stream $stream).ReparsePoint 'The reader followed a symbolic link.'
            Complete-RequestFile -Path $link -DestinationDir $FailedRequestsDir -Stream $stream -Raw $null -ErrorMessage 'Rejected reparse input'
        }
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }

    Check-Security ((Get-Acl -LiteralPath $target).Sddl -eq $beforeAcl) 'Reparse target owner/DACL changed.'
    Check-Security ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $beforeHash) 'Reparse target bytes changed.'
    Write-Output 'PASS FileSystemNative rejected symbolic link never changes its target'

    $valid = Join-Path $RequestsDir 'valid.json'
    [IO.File]::WriteAllText($valid, '{"Command":"GetStatus"}')

    $directoryWriter = [Softwarekatalog.Tests.RequestDirectoryProbe]::OpenWrite($RequestsDir)
    try {
        $bound = Open-RequestFileRead -Path $valid
        $bound.Dispose()
    }
    finally { $directoryWriter.Dispose() }

    $stream = Open-RequestFileRead -Path $valid
    try {
        $writer = [Softwarekatalog.Tests.RequestDirectoryProbe]::OpenWrite($RequestsDir)
        $writer.Dispose()

        $newSubmission = Join-Path $RequestsDir 'submitted-during-lease.json'
        [IO.File]::WriteAllText($newSubmission, '{"Command":"GetStatus"}')
        [IO.File]::Delete($newSubmission)

        Expect-SharingViolation {
            $writer = [IO.File]::Open($valid, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            $writer.Dispose()
        }
        Expect-SharingViolation { [IO.File]::Move($valid, "$valid.exchanged") }
        Complete-RequestFile -Path $valid -DestinationDir $FailedRequestsDir -Stream $stream -Raw '{"Command":"GetStatus"}'
    }
    finally { $stream.Dispose() }

    $directoryWriter = [Softwarekatalog.Tests.RequestDirectoryProbe]::OpenWrite($RequestsDir)
    $directoryWriter.Dispose()

    Check-Security ((Read-TrustedText (Join-Path $FailedRequestsDir 'valid.json')) -eq '{"Command":"GetStatus"}') 'Valid bounded content was not retained.'
    Write-Output 'PASS FileSystemNative relative binding permits directory writers/new submissions while the file lease blocks content/name exchange'

    $raceDrop = Join-Path $work 'ReparseRaceDrop'
    $raceTarget = Join-Path $work 'ReparseRaceTarget'
    New-TrustedDirectory -Path $raceDrop -PublicDrop
    New-TrustedDirectory -Path $raceTarget
    $victim = Join-Path $raceTarget 'victim.json'
    Write-TrustedText -Path $victim -Value 'protected unrelated target'
    $victimHash = (Get-FileHash -LiteralPath $victim -Algorithm SHA256).Hash
    $victimAcl = (Get-Acl -LiteralPath $victim).Sddl
    $directoryLease = [Softwarekatalog.TrustedFileSystemNative]::OpenRequestDirectory($raceDrop)
    $redirected = $false
    try {
        Assert-TrustedOpenFile -Handle $directoryLease -Directory -PublicDrop
        try {
            [Softwarekatalog.Tests.RequestDirectoryProbe]::SetJunction($raceDrop, $raceTarget)
            $redirected = $true
            Check-Security ([bool]([Softwarekatalog.TrustedFileSystemNative]::Information($directoryLease).Attributes -band 0x400)) 'The real reparse race was not established.'
        }
        catch {
            $cause = $_.Exception.GetBaseException()
            if ($cause -isnot [ComponentModel.Win32Exception] -or $cause.NativeErrorCode -notin @(5, 32)) { throw }

            Write-Output "Native filesystem itself blocked the reparse race ($($cause.NativeErrorCode))."
        }

        $unexpected = $null
        try { $unexpected = [Softwarekatalog.TrustedFileSystemNative]::OpenRequestRead('victim.json', $directoryLease) }
        catch {
            $cause = $_.Exception.GetBaseException()
            # STATUS_REPARSE_POINT_NOT_RESOLVED (0xC0000280) maps to
            # ERROR_CANT_RESOLVE_FILENAME (1921): the bound open refused it.
            if ($cause -isnot [ComponentModel.Win32Exception] -or $cause.NativeErrorCode -notin @(2, 3, 1920, 1921, 4395)) { throw }
        }

        if ($null -ne $unexpected) {
            $unexpected.Dispose()
            throw 'A relative request open escaped the pinned directory into its new reparse target.'
        }
    }
    finally {
        try { if ($redirected) { [Softwarekatalog.Tests.RequestDirectoryProbe]::ClearJunction($raceDrop) } }
        finally { $directoryLease.Dispose() }
    }

    Check-Security ((Get-FileHash -LiteralPath $victim -Algorithm SHA256).Hash -eq $victimHash) 'Reparse race changed unrelated target bytes.'
    Check-Security ((Get-Acl -LiteralPath $victim).Sddl -eq $victimAcl) 'Reparse race changed unrelated target owner/DACL.'
    Write-Output 'PASS FileSystemNative an actual post-validation reparse change cannot redirect the handle-relative request open'

    $cache = Join-Path $BaseDir 'ArtCraft\Cache\lease.msi'
    Write-TrustedText -Path $cache -Value 'isolated installer bytes'
    $stream = Open-TrustedFileRead -Path $cache
    try {
        Expect-SharingViolation {
            $writer = [IO.File]::Open($cache, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            $writer.Dispose()
        }
        Expect-SharingViolation { [IO.File]::Delete($cache) }
    }
    finally { $stream.Dispose() }
    Write-Output 'PASS FileSystemNative installer content lease prevents write and delete until disposal'

    $statePath = Join-Path $BaseDir 'ArtCraft\State.json'
    Write-TrustedText -Path $statePath -Value '{"SchemaVersion":1,"Records":[]}'
    Invoke-FixtureAcl @($statePath, '/grant:r', '*S-1-5-32-545:M')
    $weakStateAcl = (Get-Acl -LiteralPath $statePath).Sddl
    Expect-SecurityRejection { Read-ArtCraftState }
    Expect-SecurityRejection { Initialize-ServiceStorage }
    Check-Security ((Get-Acl -LiteralPath $statePath).Sddl -eq $weakStateAcl) 'Preflight promoted a writable state file to trusted.'
    Remove-Item -LiteralPath $statePath -Force
    Write-Output 'PASS FileSystemNative writable child state is rejected before recovery, never ACL-promoted'

    $foreign = Join-Path $work 'ForeignRoot'
    New-TrustedDirectory -Path $foreign
    Invoke-FixtureAcl @($foreign, '/setowner', '*S-1-5-32-545')
    $foreignAcl = (Get-Acl -LiteralPath $foreign).Sddl
    $BaseDir = $foreign
    Expect-SecurityRejection { Initialize-ServiceStorage }
    Check-Security ((Get-Acl -LiteralPath $foreign).Sddl -eq $foreignAcl) 'A preoccupied root was silently repaired.'
    Check-Security (-not (Test-Path -LiteralPath (Join-Path $foreign 'Logs'))) 'Preflight used a foreign root before rejecting it.'
    Write-Output 'PASS FileSystemNative preoccupied root fails before logging, migration or child creation'

    $junction = Join-Path $work 'RedirectedRoot'
    New-Item -ItemType Junction -Path $junction -Target $foreign | Out-Null
    $BaseDir = $junction
    Expect-SecurityRejection { Initialize-ServiceStorage }
    Write-Output 'PASS FileSystemNative redirected service root is rejected without traversing it'
}
finally {
    if ($junction -and (Test-Path -LiteralPath $junction)) { [IO.Directory]::Delete($junction) }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
