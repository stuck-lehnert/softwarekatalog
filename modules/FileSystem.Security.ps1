# Filesystem trust for privileged service data. Definitions only: loading this
# module never creates paths, changes an ACL, or follows a reparse point.
function Initialize-FileSystemSecurityNative {
    if ('Softwarekatalog.TrustedFileSystemNative' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using Microsoft.Win32.SafeHandles;

namespace Softwarekatalog {
    public static class TrustedFileSystemNative {
        [StructLayout(LayoutKind.Sequential)]
        public struct FileInformation {
            public uint Attributes;
            public uint CreationLow, CreationHigh;
            public uint AccessLow, AccessHigh;
            public uint WriteLow, WriteHigh;
            public uint VolumeSerial;
            public uint SizeHigh, SizeLow;
            public uint Links;
            public uint IndexHigh, IndexLow;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes {
            public int Length;
            public IntPtr Descriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileDisposition {
            // FILE_DISPOSITION_INFO uses BOOLEAN (one byte), not Win32 BOOL.
            public byte Delete;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
            ref SecurityAttributes security, uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateDirectoryW(string path, ref SecurityAttributes security);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation info);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle file, int infoClass,
            ref FileDisposition disposition, uint size);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern uint GetSecurityInfo(SafeFileHandle file, int objectType, uint requested,
            out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);

        [DllImport("advapi32.dll")]
        private static extern uint GetSecurityDescriptorLength(IntPtr descriptor);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(
            string sddl, uint revision, out IntPtr descriptor, out uint size);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        private static SafeFileHandle CheckHandle(SafeFileHandle handle) {
            if (!handle.IsInvalid) return handle;

            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error);
        }

        public static SafeFileHandle OpenMetadata(string path, bool directory) {
            // READ_CONTROL | FILE_READ_ATTRIBUTES. Directory handles pin names
            // while the ancestor chain is checked. Metadata is not a content
            // lease; OpenRead below always denies write/delete sharing.
            uint flags = 0x00200000u | (directory ? 0x02000000u : 0u);
            uint share = directory ? 3u : 7u;
            return CheckHandle(CreateFileW(path, 0x00020080u, share, IntPtr.Zero, 3, flags, IntPtr.Zero));
        }

        public static FileStream OpenRead(string path, bool deleteAccess) {
            uint access = 0x80020080u | (deleteAccess ? 0x00010000u : 0u);
            SafeFileHandle handle = CheckHandle(CreateFileW(path, access, 1, IntPtr.Zero,
                3, 0x00200000u, IntPtr.Zero));
            try { return new FileStream(handle, FileAccess.Read); }
            catch { handle.Dispose(); throw; }
        }

        public static FileInformation Information(SafeFileHandle file) {
            FileInformation info;
            if (!GetFileInformationByHandle(file, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return info;
        }

        public static RawSecurityDescriptor Security(SafeFileHandle file) {
            IntPtr owner, group, dacl, sacl, descriptor;
            uint error = GetSecurityInfo(file, 1, 5, out owner, out group, out dacl, out sacl, out descriptor);
            if (error != 0) throw new Win32Exception((int)error);

            try {
                uint length = GetSecurityDescriptorLength(descriptor);
                if (length == 0 || length > 1048576) throw new InvalidOperationException("Invalid filesystem security descriptor.");
                byte[] bytes = new byte[length];
                Marshal.Copy(descriptor, bytes, 0, bytes.Length);
                return new RawSecurityDescriptor(bytes, 0);
            }
            finally { LocalFree(descriptor); }
        }

        private static SecurityAttributes CreateSecurity(string sddl) {
            IntPtr descriptor;
            uint size;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, out descriptor, out size))
                throw new Win32Exception(Marshal.GetLastWin32Error());

            SecurityAttributes result = new SecurityAttributes();
            result.Length = Marshal.SizeOf(typeof(SecurityAttributes));
            result.Descriptor = descriptor;
            return result;
        }

        public static void CreateDirectory(string path, string sddl) {
            SecurityAttributes security = CreateSecurity(sddl);
            try {
                if (CreateDirectoryW(path, ref security)) return;

                int error = Marshal.GetLastWin32Error();
                if (error != 183) throw new Win32Exception(error);
                // Existing objects are inspected by the caller, never repaired.
            }
            finally { LocalFree(security.Descriptor); }
        }

        public static FileStream CreateWriter(string path, bool append) {
            const string sddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;BU)";
            SecurityAttributes security = CreateSecurity(sddl);
            try {
                SafeFileHandle handle = CheckHandle(CreateFileW(path, 0x40020080u, 1,
                    ref security, append ? 4u : 1u, 0x00200000u, IntPtr.Zero));
                try { return new FileStream(handle, FileAccess.Write); }
                catch { handle.Dispose(); throw; }
            }
            finally { LocalFree(security.Descriptor); }
        }

        public static void DeleteOpenedRequest(SafeFileHandle file) {
            FileDisposition disposition = new FileDisposition();
            disposition.Delete = 1;
            if (!SetFileInformationByHandle(file, 4, ref disposition, (uint)Marshal.SizeOf(typeof(FileDisposition))))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@
}

function Get-CanonicalLocalPath {
    param([Parameter(Mandatory)][string]$Path)

    $canonical = [IO.Path]::GetFullPath($Path)
    if ($canonical -notmatch '^[A-Za-z]:\\' -or $canonical.Substring(2).Contains(':')) {
        throw "Privileged storage requires a local drive path without alternate streams: $Path"
    }

    return $canonical
}

function Get-FileSystemSecuritySummary {
    param([Parameter(Mandatory)]$Handle)

    try { $descriptor = [Softwarekatalog.TrustedFileSystemNative]::Security($Handle) }
    catch { throw "Cannot read native filesystem security descriptor: $($_.Exception.ToString())" }

    $rules = @()
    # Use RawAcl's typed indexed API instead of depending on the shell's
    # non-generic enumerator adaptation, including callback/object ACEs.
    for ($index = 0; $null -ne $descriptor.DiscretionaryAcl -and $index -lt $descriptor.DiscretionaryAcl.Count; $index++) {
        $ace = $descriptor.DiscretionaryAcl[$index]
        if ($ace -isnot [Security.AccessControl.QualifiedAce]) { throw 'Unsupported filesystem ACE.' }

        $rules += [pscustomobject]@{
            Sid = $ace.SecurityIdentifier.Value
            Mask = $ace.AccessMask
            Allow = ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed)
            # AceFlags has a byte underlying type. PS5.1's enum bitwise binder
            # can throw InvalidCastException; normalize to integers explicitly.
            InheritOnly = (([int]$ace.AceFlags -band 0x08) -ne 0)
        }
    }

    return [pscustomobject]@{
        Owner = $descriptor.Owner.Value
        DaclPresent = ($null -ne $descriptor.DiscretionaryAcl)
        Rules = $rules
    }
}

function Assert-TrustedSecuritySummary {
    param(
        [Parameter(Mandatory)]$Security,
        [switch]$Ancestor,
        [switch]$PublicDrop
    )

    $trusted = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    )
    if ($Security.Owner -notin $trusted -or -not $Security.DaclPresent) {
        throw 'Untrusted filesystem owner or null DACL; administrative inspection is required.'
    }

    # Ancestors may allow creation of new subdirectories (e.g. ProgramData),
    # never mutation/replacement of an already trusted child or the ancestor.
    $writeMask = if ($Ancestor) { 0x500D0152 } else { 0x500D0156 }
    foreach ($rule in $Security.Rules) {
        if (-not $rule.Allow -or $rule.InheritOnly -or $rule.Sid -in $trusted) { continue }
        if ($rule.Sid -eq 'S-1-3-4') { continue } # OWNER RIGHTS; the owner was checked.

        $writes = $rule.Mask -band $writeMask
        if ($PublicDrop -and $rule.Sid -eq 'S-1-5-32-545') {
            $writes = $writes -band (-bnot 0x00000116)
        }

        if ($writes) { throw "Untrusted filesystem write/delete/ACL grant for '$($rule.Sid)'." }
    }
}

function Assert-TrustedOpenFile {
    param([Parameter(Mandatory)]$Handle, [switch]$Directory, [switch]$Ancestor, [switch]$PublicDrop)

    $information = [Softwarekatalog.TrustedFileSystemNative]::Information($Handle)
    if ($information.Attributes -band 0x400) { throw 'Reparse points are forbidden in privileged storage.' }
    if ([bool]($information.Attributes -band 0x10) -ne [bool]$Directory) { throw 'Unexpected filesystem object type.' }

    Assert-TrustedSecuritySummary -Security (Get-FileSystemSecuritySummary $Handle) -Ancestor:$Ancestor -PublicDrop:$PublicDrop
}

function Assert-TrustedFileSystemPath {
    param([Parameter(Mandatory)][string]$Path, [switch]$Directory, [switch]$PublicDrop, [switch]$AncestorLeaf)

    Initialize-FileSystemSecurityNative
    $canonical = Get-CanonicalLocalPath $Path
    $root = [IO.Path]::GetPathRoot($canonical)
    $parts = @($root)
    $current = $root
    foreach ($part in $canonical.Substring($root.Length).Split('\', [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $part
        $parts += $current
    }

    $handles = New-Object 'Collections.Generic.List[IDisposable]'
    try {
        for ($index = 0; $index -lt $parts.Count; $index++) {
            $leaf = $index -eq ($parts.Count - 1)
            $isDirectory = -not $leaf -or $Directory
            $handle = [Softwarekatalog.TrustedFileSystemNative]::OpenMetadata($parts[$index], $isDirectory)
            $handles.Add($handle)
            Assert-TrustedOpenFile -Handle $handle -Directory:$isDirectory -Ancestor:((-not $leaf) -or $AncestorLeaf) -PublicDrop:($leaf -and $PublicDrop)
        }
    }
    finally {
        for ($index = $handles.Count - 1; $index -ge 0; $index--) { $handles[$index].Dispose() }
    }
}

function New-TrustedDirectory {
    param([Parameter(Mandatory)][string]$Path, [switch]$PublicDrop)

    Initialize-FileSystemSecurityNative
    $canonical = Get-CanonicalLocalPath $Path
    $parent = [IO.Path]::GetDirectoryName($canonical.TrimEnd('\'))
    Assert-TrustedFileSystemPath -Path $parent -Directory -AncestorLeaf

    $sddl = if ($PublicDrop) {
        'O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1201bf;;;BU)(A;OICIIO;0x1301bf;;;CO)'
    }
    else {
        'O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;GRGX;;;BU)'
    }
    [Softwarekatalog.TrustedFileSystemNative]::CreateDirectory($canonical, $sddl)
    Assert-TrustedFileSystemPath -Path $canonical -Directory -PublicDrop:$PublicDrop
}

function Open-TrustedFileRead {
    param([Parameter(Mandatory)][string]$Path)

    Assert-TrustedFileSystemPath -Path ([IO.Path]::GetDirectoryName($Path)) -Directory
    $stream = [Softwarekatalog.TrustedFileSystemNative]::OpenRead((Get-CanonicalLocalPath $Path), $false)
    try {
        Assert-TrustedOpenFile -Handle $stream.SafeFileHandle
        return $stream
    }
    catch { $stream.Dispose(); throw }
}

function Initialize-ServiceStorage {
    # Existing objects are validated before logging, migration or recovery.
    # Input payloads remain untrusted; only their containing directories count
    # as service storage and the request reader handles their contents.
    $privateDirectories = @(
        $BaseDir,
        (Join-Path $BaseDir 'Logs'),
        (Join-Path $BaseDir 'Processed'),
        (Join-Path $BaseDir 'Failed'),
        (Join-Path $BaseDir 'AdminRequests'),
        (Join-Path $BaseDir 'ArtCraft'),
        (Join-Path $BaseDir 'ArtCraft\Cache'),
        (Join-Path $BaseDir 'ArtCraft\Logs')
    )
    foreach ($directory in $privateDirectories) { New-TrustedDirectory -Path $directory }

    $publicDrop = Join-Path $BaseDir 'Requests'
    $adminDrop = Join-Path $BaseDir 'AdminRequests'
    New-TrustedDirectory -Path $publicDrop -PublicDrop

    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($BaseDir)
    while ($pending.Count) {
        $directory = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
            if ($item.FullName -ieq $publicDrop -or $item.FullName -ieq $adminDrop) { continue }

            Assert-TrustedFileSystemPath -Path $item.FullName -Directory:$item.PSIsContainer
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
}

function Read-TrustedText {
    param([Parameter(Mandatory)][string]$Path, [long]$MaximumBytes = 16777216)

    $stream = Open-TrustedFileRead $Path
    try {
        if ($stream.Length -gt $MaximumBytes) { throw 'Trusted data exceeds its size limit.' }

        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Write-TrustedBytes {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes, [switch]$Append, [switch]$CreateNew)

    if ($Append -and $CreateNew) { throw 'Append and CreateNew are mutually exclusive.' }

    Assert-TrustedFileSystemPath -Path ([IO.Path]::GetDirectoryName($Path)) -Directory
    if (Test-Path -LiteralPath $Path) {
        if ($CreateNew) { throw 'New trusted output already exists.' }

        Assert-TrustedFileSystemPath -Path $Path
    }

    $temporary = if ($Append) { $Path } else { $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp' }
    try {
        # Request, queue and upgrade tasks can append to the same service log.
        # Serialize via native sharing, retrying only a sharing violation and
        # never weakening the deny-write/delete lease to avoid contention.
        for ($attempt = 0; ; $attempt++) {
            try {
                $stream = [Softwarekatalog.TrustedFileSystemNative]::CreateWriter($temporary, [bool]$Append)
                break
            }
            catch {
                $cause = $_.Exception.GetBaseException()
                if (-not $Append -or $attempt -ge 19 -or
                    $cause -isnot [ComponentModel.Win32Exception] -or $cause.NativeErrorCode -ne 32) {
                    throw
                }

                Start-Sleep -Milliseconds 50
            }
        }
        try {
            Assert-TrustedOpenFile -Handle $stream.SafeFileHandle
            if ($Append) { [void]$stream.Seek(0, [IO.SeekOrigin]::End) }

            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }

        if (-not $Append) {
            if (-not $CreateNew -and (Test-Path -LiteralPath $Path)) {
                [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value)
            }
            else { [IO.File]::Move($temporary, $Path) }
        }
    }
    finally {
        if (-not $Append -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Write-TrustedText {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Value, [switch]$Bom, [switch]$Append, [switch]$CreateNew)

    $encoding = New-Object Text.UTF8Encoding([bool]$Bom)
    $bytes = $encoding.GetBytes($Value)
    if ($Bom -and -not $Append) { $bytes = $encoding.GetPreamble() + $bytes }

    Write-TrustedBytes -Path $Path -Bytes $bytes -Append:$Append -CreateNew:$CreateNew
}

function Open-RequestFileRead {
    param([Parameter(Mandatory)][string]$Path)

    # Only the containing drop is trusted. The source object is intentionally
    # NOT promoted to a trusted file and its DACL is never changed.
    Assert-TrustedFileSystemPath -Path ([IO.Path]::GetDirectoryName($Path)) -Directory -PublicDrop
    return [Softwarekatalog.TrustedFileSystemNative]::OpenRead((Get-CanonicalLocalPath $Path), $true)
}

function Get-OpenRequestFileInformation {
    param([Parameter(Mandatory)][IO.FileStream]$Stream)

    $information = [Softwarekatalog.TrustedFileSystemNative]::Information($Stream.SafeFileHandle)
    return [pscustomobject]@{
        ReparsePoint = [bool]($information.Attributes -band 0x400)
        Directory = [bool]($information.Attributes -band 0x10)
        Links = $information.Links
    }
}

function Remove-OpenRequestFile {
    param([Parameter(Mandatory)][IO.FileStream]$Stream)

    [Softwarekatalog.TrustedFileSystemNative]::DeleteOpenedRequest($Stream.SafeFileHandle)
}
