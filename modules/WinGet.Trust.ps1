# Authenticate candidates as data, never by running them (including AppExecLink
# aliases). Dependencies: FileSystem.Security.ps1's protected no-follow reader.
# Exact upstream source identity: microsoft/winget-cli's
# https://github.com/microsoft/winget-cli/blob/master/src/binver/binver/version.h
# defines VER_PRODUCTNAME_STR "WinGet CLI", and both original/internal names
# "winget.exe". Microsoft's shipped DesktopAppInstaller PE uses a DIFFERENT
# exact pair: InternalName "AppInstallerCLI", ProductName "Microsoft Desktop
# App Installer", still OriginalFilename "winget.exe". Read from original x64
# and ARM64 winget.exe members of the official v1.29.380 release MSIX bundle:
# https://github.com/microsoft/winget-cli/releases/tag/v1.29.380
# x64 SHA256 ce0bb2b4871cb7f41f40d34ad47e8414a426dc5f6a303c14cee335a71d8602ed
# ARM64 SHA256 b5fd38f58a202f33c6dd00d0802c8ad09c6129cedd37c83507579bd89ed95fac
# Match whole profiles, never arbitrary combinations. Resource identity alone
# NEVER authorizes a candidate: Microsoft Authenticode, root/publisher, held
# protected read handle and any package provenance remain mandatory below.

function Initialize-WinGetTrustNativeApi {
    if ('Softwarekatalog.WinGetTrustNative' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Softwarekatalog {
    public sealed class WinGetMetadata {
        public string Architecture;
        public Version Version;
        public string OriginalFilename;
        public string InternalName;
        public string ProductName;
    }

    public sealed class WinGetSignatureEvidence {
        public int AuthenticodeStatus = -1;
        public uint MicrosoftRootStatus = UInt32.MaxValue;
        public string SignerOrganization;
    }

    public sealed class WinGetCandidateLease : IDisposable {
        public string Path { get; private set; }
        public string Architecture { get; private set; }
        public Version Version { get; private set; }
        public string PackageFamilyName { get; private set; }
        public FileStream Stream { get; private set; }

        public WinGetCandidateLease(string path, WinGetMetadata metadata, string family, FileStream stream) {
            Path = path;
            Architecture = metadata.Architecture;
            Version = metadata.Version;
            PackageFamilyName = family;
            Stream = stream;
        }

        public void Dispose() {
            if (Stream == null) { return; }

            Stream.Dispose();
            Stream = null;
        }
    }

    public static class WinGetTrustNative {
        [StructLayout(LayoutKind.Sequential)]
        struct TrustFile {
            public uint Size;
            public IntPtr Path;
            public IntPtr File;
            public IntPtr Subject;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct TrustData {
            public uint Size;
            public IntPtr Policy;
            public IntPtr Sip;
            public uint UI;
            public uint Revocation;
            public uint Choice;
            public IntPtr File;
            public uint StateAction;
            public IntPtr State;
            public IntPtr URL;
            public uint Flags;
            public uint UIContext;
            public IntPtr SignatureSettings;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ProviderSigner {
            public uint Size;
            public System.Runtime.InteropServices.ComTypes.FILETIME VerifyAsOf;
            public uint CertificateCount;
            public IntPtr Certificates;
            public uint SignerType;
            public IntPtr Signer;
            public uint Error;
            public uint CounterSignerCount;
            public IntPtr CounterSigners;
            public IntPtr Chain;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ProviderCertificate {
            public uint Size;
            public IntPtr Certificate;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ChainPolicyParameters {
            public uint Size;
            public uint Flags;
            public IntPtr Extra;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ChainPolicyStatus {
            public uint Size;
            public uint Error;
            public int ChainIndex;
            public int ElementIndex;
            public IntPtr Extra;
        }

        [DllImport("wintrust.dll", ExactSpelling = true)]
        static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);

        [DllImport("wintrust.dll", ExactSpelling = true)]
        static extern IntPtr WTHelperProvDataFromStateData(IntPtr state);

        [DllImport("wintrust.dll", ExactSpelling = true)]
        static extern IntPtr WTHelperGetProvSignerFromChain(IntPtr provider, uint signer, bool counterSigner, uint counterIndex);

        [DllImport("wintrust.dll", ExactSpelling = true)]
        static extern IntPtr WTHelperGetProvCertFromChain(IntPtr signer, uint index);

        [DllImport("crypt32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool CertVerifyCertificateChainPolicy(IntPtr policy, IntPtr chain,
            ref ChainPolicyParameters parameters, ref ChainPolicyStatus status);

        [DllImport("crypt32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        static extern uint CertGetNameStringW(IntPtr certificate, uint type, uint flags,
            IntPtr attribute, StringBuilder name, uint characters);

        static uint CheckMicrosoftRoot(IntPtr chain, uint flags) {
            var parameters = new ChainPolicyParameters();
            parameters.Size = (uint)Marshal.SizeOf(typeof(ChainPolicyParameters));
            parameters.Flags = flags;

            var status = new ChainPolicyStatus();
            status.Size = (uint)Marshal.SizeOf(typeof(ChainPolicyStatus));
            if (!CertVerifyCertificateChainPolicy(new IntPtr(7), chain, ref parameters, ref status)) {
                return UInt32.MaxValue;
            }

            return status.Error;
        }

        public static WinGetSignatureEvidence VerifySignature(FileStream stream, string path) {
            // WINTRUST_FILE_INFO.hFile binds Authenticode to the SAME protected,
            // write/delete-denying handle from which PE metadata is read.
            // https://learn.microsoft.com/windows/win32/api/wintrust/ns-wintrust-wintrust_file_info
            var evidence = new WinGetSignatureEvidence();
            var action = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");
            var data = new TrustData();
            data.Size = (uint)Marshal.SizeOf(typeof(TrustData));
            data.UI = 2;             // WTD_UI_NONE
            data.Revocation = 1;     // WTD_REVOKE_WHOLECHAIN
            data.Choice = 1;         // WTD_CHOICE_FILE
            data.StateAction = 1;    // WTD_STATEACTION_VERIFY
            data.Flags = 0x80 | 0x2000; // CHAIN_EXCLUDE_ROOT + DISABLE_MD2_MD4
            // No cache-only, ignore-offline, test-root or revocation bypass.

            IntPtr pathMemory = IntPtr.Zero;
            IntPtr fileMemory = IntPtr.Zero;
            bool referenced = false;
            try {
                stream.SafeFileHandle.DangerousAddRef(ref referenced);
                stream.Position = 0;
                pathMemory = Marshal.StringToCoTaskMemUni(path);

                var file = new TrustFile();
                file.Size = (uint)Marshal.SizeOf(typeof(TrustFile));
                file.Path = pathMemory;
                file.File = stream.SafeFileHandle.DangerousGetHandle();
                fileMemory = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(TrustFile)));
                Marshal.StructureToPtr(file, fileMemory, false);
                data.File = fileMemory;

                evidence.AuthenticodeStatus = WinVerifyTrust(new IntPtr(-1), ref action, ref data);
                if (evidence.AuthenticodeStatus != 0) { return evidence; }

                IntPtr provider = WTHelperProvDataFromStateData(data.State);
                if (provider == IntPtr.Zero) { return evidence; }

                IntPtr signerPointer = WTHelperGetProvSignerFromChain(provider, 0, false, 0);
                if (signerPointer == IntPtr.Zero) { return evidence; }

                var signer = (ProviderSigner)Marshal.PtrToStructure(signerPointer, typeof(ProviderSigner));
                if (signer.Error != 0 || signer.CertificateCount == 0 || signer.Chain == IntPtr.Zero) { return evidence; }

                // Policy 7 checks Microsoft's ROOT PUBLIC KEY, not a display
                // name. It supplements full Authenticode, never replaces it.
                // https://learn.microsoft.com/windows/win32/api/wincrypt/nf-wincrypt-certverifycertificatechainpolicy
                // 0x40000 excludes flight roots; 0x20000 selects application roots.
                // Never enable the test-root flag (0x10000).
                evidence.MicrosoftRootStatus = CheckMicrosoftRoot(signer.Chain, 0x40000);
                if (evidence.MicrosoftRootStatus != 0) {
                    evidence.MicrosoftRootStatus = CheckMicrosoftRoot(signer.Chain, 0x60000);
                }

                IntPtr certificatePointer = WTHelperGetProvCertFromChain(signerPointer, 0);
                if (certificatePointer == IntPtr.Zero) { return evidence; }

                var certificate = (ProviderCertificate)Marshal.PtrToStructure(certificatePointer, typeof(ProviderCertificate));
                if (certificate.Certificate == IntPtr.Zero) { return evidence; }

                const uint CERT_NAME_ATTR_TYPE = 3;
                IntPtr organizationOid = Marshal.StringToHGlobalAnsi("2.5.4.10"); // szOID_ORGANIZATION_NAME
                try {
                    // Official API: type 3 returns the attribute selected by
                    // pvTypePara's OID. OID 2.5.4.10 selects O, NOT common name.
                    // https://learn.microsoft.com/windows/win32/api/wincrypt/nf-wincrypt-certgetnamestringw
                    var organization = new StringBuilder(256);
                    uint length = CertGetNameStringW(certificate.Certificate, CERT_NAME_ATTR_TYPE,
                        0, organizationOid, organization, 256);
                    if (length > 1 && length <= 256) { evidence.SignerOrganization = organization.ToString(); }
                }
                finally { Marshal.FreeHGlobal(organizationOid); }

                return evidence;
            }
            finally {
                if (data.State != IntPtr.Zero) {
                    data.StateAction = 2; // WTD_STATEACTION_CLOSE, including failure.
                    WinVerifyTrust(new IntPtr(-1), ref action, ref data);
                }

                if (fileMemory != IntPtr.Zero) { Marshal.FreeHGlobal(fileMemory); }
                if (pathMemory != IntPtr.Zero) { Marshal.FreeCoTaskMem(pathMemory); }
                if (referenced) { stream.SafeFileHandle.DangerousRelease(); }
            }
        }

        static byte[] ReadAt(Stream stream, long offset, int count) {
            if (offset < 0 || count < 0 || offset > stream.Length - count) {
                throw new InvalidDataException("PE range is outside the locked file.");
            }

            var bytes = new byte[count];
            stream.Position = offset;
            int done = 0;
            while (done < count) {
                int read = stream.Read(bytes, done, count - done);
                if (read == 0) { throw new EndOfStreamException("Truncated locked PE file."); }
                done += read;
            }

            return bytes;
        }

        static ushort U16(byte[] data, int offset) {
            if (offset < 0 || offset > data.Length - 2) { throw new InvalidDataException("Truncated PE word."); }
            return BitConverter.ToUInt16(data, offset);
        }

        static uint U32(byte[] data, int offset) {
            if (offset < 0 || offset > data.Length - 4) { throw new InvalidDataException("Truncated PE dword."); }
            return BitConverter.ToUInt32(data, offset);
        }

        static long MapRva(uint rva, uint size, byte[] sections, long fileLength) {
            long found = -1;
            for (int offset = 0; offset < sections.Length; offset += 40) {
                uint start = U32(sections, offset + 12);
                uint rawSize = U32(sections, offset + 16);
                uint rawOffset = U32(sections, offset + 20);
                long relative = (long)rva - start;
                if (relative < 0 || relative + size > rawSize) { continue; }

                long candidate = rawOffset + relative;
                if (candidate < 0 || candidate + size > fileLength || found >= 0) {
                    throw new InvalidDataException("Ambiguous or invalid PE section mapping.");
                }

                found = candidate;
            }

            if (found < 0) { throw new InvalidDataException("PE resource RVA has no bounded section."); }
            return found;
        }

        static List<uint[]> ResourceEntries(byte[] resource, uint directory) {
            if (directory > Int32.MaxValue) { throw new InvalidDataException("Invalid PE resource directory."); }

            int offset = (int)directory;
            int count = U16(resource, offset + 12) + U16(resource, offset + 14);
            if (count < 1 || count > 256 || offset > resource.Length - 16 - count * 8) {
                throw new InvalidDataException("Unbounded PE resource directory.");
            }

            var entries = new List<uint[]>();
            for (int index = 0; index < count; index++) {
                int entry = offset + 16 + index * 8;
                entries.Add(new uint[] { U32(resource, entry), U32(resource, entry + 4) });
            }

            return entries;
        }

        static uint RequireResourceDirectory(byte[] resource, uint directory, uint id) {
            uint found = UInt32.MaxValue;
            foreach (uint[] entry in ResourceEntries(resource, directory)) {
                if (entry[0] != id) { continue; }
                if (found != UInt32.MaxValue || (entry[1] & 0x80000000) == 0) {
                    throw new InvalidDataException("Ambiguous PE version-resource directory.");
                }

                found = entry[1] & 0x7fffffff;
            }

            if (found == UInt32.MaxValue) { throw new InvalidDataException("PE version resource is missing."); }
            return found;
        }

        sealed class VersionNode {
            public int End;
            public string Key;
            public int Value;
            public int ValueBytes;
            public int Children;
        }

        static int Align4(int offset) { return checked((offset + 3) & ~3); }

        static VersionNode ReadVersionNode(byte[] bytes, int offset, int limit) {
            int length = U16(bytes, offset);
            int valueLength = U16(bytes, offset + 2);
            int type = U16(bytes, offset + 4);
            if (length < 8 || offset > limit - length || type > 1) {
                throw new InvalidDataException("Malformed bounded PE version block.");
            }

            int end = offset + length;
            int keyStart = offset + 6;
            int cursor = keyStart;
            while (cursor <= end - 2 && U16(bytes, cursor) != 0) { cursor += 2; }
            if (cursor > end - 2) { throw new InvalidDataException("Unterminated PE version key."); }

            int value = Align4(cursor + 2);
            int valueBytes = checked(valueLength * (type == 1 ? 2 : 1));
            if (value > end || valueBytes > end - value) { throw new InvalidDataException("Invalid PE version value size."); }

            return new VersionNode {
                End = end, Key = Encoding.Unicode.GetString(bytes, keyStart, cursor - keyStart),
                Value = value, ValueBytes = valueBytes, Children = Math.Min(end, Align4(value + valueBytes))
            };
        }

        static List<VersionNode> VersionChildren(byte[] bytes, VersionNode parent) {
            var children = new List<VersionNode>();
            int cursor = parent.Children;
            while (cursor <= parent.End - 8) {
                if (children.Count >= 256) { throw new InvalidDataException("Too many PE version children."); }

                VersionNode child = ReadVersionNode(bytes, cursor, parent.End);
                children.Add(child);
                cursor = Align4(child.End);
            }

            return children;
        }

        static void MergeIdentity(Dictionary<string, string> values, string key, string value) {
            string previous;
            if (values.TryGetValue(key, out previous) && !String.Equals(previous, value, StringComparison.Ordinal)) {
                throw new InvalidDataException("Conflicting multilingual PE product identity.");
            }

            values[key] = value;
        }

        public static WinGetMetadata ReadMetadata(Stream stream) {
            // Parse bounded bytes from the held stream. FileVersionInfo and
            // GetFileVersionInfo are PATH APIs and would reopen a different file.
            byte[] dos = ReadAt(stream, 0, 64);
            if (U16(dos, 0) != 0x5a4d) { throw new InvalidDataException("Candidate is not a PE image (aliases are not executable probes)."); }

            long peOffset = U32(dos, 60);
            byte[] header = ReadAt(stream, peOffset, 24);
            if (U32(header, 0) != 0x00004550) { throw new InvalidDataException("Invalid PE signature."); }

            ushort machine = U16(header, 4);
            string architecture;
            switch (machine) {
                case 0x8664: architecture = "x64"; break;
                case 0xaa64: architecture = "arm64"; break;
                case 0x014c: architecture = "x86"; break;
                default: throw new InvalidDataException("Unsupported WinGet PE architecture.");
            }

            int sectionCount = U16(header, 6);
            int optionalSize = U16(header, 20);
            ushort characteristics = U16(header, 22);
            if (sectionCount < 1 || sectionCount > 96 || optionalSize < 136 || optionalSize > 4096 ||
                (characteristics & 2) == 0 || (characteristics & 0x2000) != 0) {
                throw new InvalidDataException("Candidate is not a bounded executable PE application.");
            }

            byte[] optional = ReadAt(stream, peOffset + 24, optionalSize);
            bool pe32 = U16(optional, 0) == 0x10b;
            bool pe64 = U16(optional, 0) == 0x20b;
            if ((!pe32 && !pe64) || (machine == 0x014c) != pe32 || U16(optional, 68) != 3) {
                throw new InvalidDataException("WinGet must be a matching console PE image.");
            }

            int dataDirectory = pe32 ? 96 : 112;
            if (U32(optional, dataDirectory - 4) < 3) { throw new InvalidDataException("PE resource directory is missing."); }

            uint resourceRva = U32(optional, dataDirectory + 16);
            uint resourceSize = U32(optional, dataDirectory + 20);
            if (resourceRva == 0 || resourceSize < 16 || resourceSize > 16777216) {
                throw new InvalidDataException("Invalid bounded PE resource size.");
            }

            byte[] sections = ReadAt(stream, peOffset + 24 + optionalSize, sectionCount * 40);
            byte[] resource = ReadAt(stream, MapRva(resourceRva, resourceSize, sections, stream.Length), (int)resourceSize);
            uint typeDirectory = RequireResourceDirectory(resource, 0, 16); // RT_VERSION
            uint languagesDirectory = RequireResourceDirectory(resource, typeDirectory, 1); // VS_VERSION_INFO
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            Version fileVersion = null;

            foreach (uint[] language in ResourceEntries(resource, languagesDirectory)) {
                if ((language[1] & 0x80000000) != 0 || language[1] > Int32.MaxValue) {
                    throw new InvalidDataException("Invalid PE version language entry.");
                }

                int entry = (int)language[1];
                uint versionRva = U32(resource, entry);
                uint versionSize = U32(resource, entry + 4);
                if (versionSize < 52 || versionSize > 1048576) { throw new InvalidDataException("Invalid PE version-resource size."); }

                byte[] bytes = ReadAt(stream, MapRva(versionRva, versionSize, sections, stream.Length), (int)versionSize);
                VersionNode root = ReadVersionNode(bytes, 0, bytes.Length);
                if (root.Key != "VS_VERSION_INFO" || root.ValueBytes != 52 ||
                    U32(bytes, root.Value) != 0xfeef04bd || U32(bytes, root.Value + 36) != 1) {
                    throw new InvalidDataException("Invalid application VS_FIXEDFILEINFO.");
                }

                uint ms = U32(bytes, root.Value + 8);
                uint ls = U32(bytes, root.Value + 12);
                var currentVersion = new Version((int)(ms >> 16), (int)(ms & 65535), (int)(ls >> 16), (int)(ls & 65535));
                if (fileVersion != null && !fileVersion.Equals(currentVersion)) { throw new InvalidDataException("Conflicting PE file versions."); }
                fileVersion = currentVersion;

                foreach (VersionNode child in VersionChildren(bytes, root)) {
                    if (child.Key != "StringFileInfo") { continue; }

                    foreach (VersionNode table in VersionChildren(bytes, child)) {
                        var tableValues = new Dictionary<string, string>(StringComparer.Ordinal);
                        foreach (VersionNode text in VersionChildren(bytes, table)) {
                            if (text.Key != "OriginalFilename" && text.Key != "InternalName" && text.Key != "ProductName") { continue; }
                            if (tableValues.ContainsKey(text.Key) || text.ValueBytes < 2 || U16(bytes, text.Value + text.ValueBytes - 2) != 0) {
                                throw new InvalidDataException("Ambiguous or unterminated PE product string.");
                            }

                            string value = Encoding.Unicode.GetString(bytes, text.Value, text.ValueBytes - 2);
                            if (value.IndexOf('\0') >= 0) { throw new InvalidDataException("Embedded NUL in PE product identity."); }
                            tableValues.Add(text.Key, value);
                        }

                        foreach (string key in new string[] { "OriginalFilename", "InternalName", "ProductName" }) {
                            if (!tableValues.ContainsKey(key)) { throw new InvalidDataException("Missing PE product identity field."); }
                            MergeIdentity(values, key, tableValues[key]);
                        }
                    }
                }
            }

            if (fileVersion == null || values.Count != 3) { throw new InvalidDataException("PE product identity is missing."); }

            return new WinGetMetadata {
                Architecture = architecture, Version = fileVersion, OriginalFilename = values["OriginalFilename"],
                InternalName = values["InternalName"], ProductName = values["ProductName"]
            };
        }
    }
}
'@
}

function Get-WinGetSignatureEvidence {
    param([Parameter(Mandatory)][IO.FileStream]$Stream, [Parameter(Mandatory)][string]$Path)

    Initialize-WinGetTrustNativeApi
    [Softwarekatalog.WinGetTrustNative]::VerifySignature($Stream, $Path)
}

function Get-WinGetPublisherId {
    param([Parameter(Mandatory)][string]$Publisher)

    # AppX publisher ID: first 64 SHA256 bits of the exact UTF-16LE publisher,
    # encoded as 13 Crockford base32 characters (last bit padded with zero).
    # Derive identity instead of accepting a publisher's displayed common name.
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::Unicode.GetBytes($Publisher)) }
    finally { $sha.Dispose() }

    $alphabet = '0123456789abcdefghjkmnpqrstvwxyz'
    $result = New-Object Text.StringBuilder
    for ($start = 0; $start -lt 65; $start += 5) {
        $value = 0
        for ($bit = $start; $bit -lt ($start + 5); $bit++) {
            $value = $value -shl 1
            if ($bit -lt 64) { $value = $value -bor (($hash[[int][Math]::Floor($bit / 8)] -shr (7 - ($bit % 8))) -band 1) }
        }
        [void]$result.Append($alphabet[$value])
    }

    $result.ToString()
}

function Get-WinGetPackageIdentity {
    param([Parameter(Mandatory)][string]$Path, $Package)

    $directory = [IO.Path]::GetDirectoryName($Path)
    $expectedFamily = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
    $packageDirectory = [IO.Path]::GetFileName($directory) -like 'Microsoft.DesktopAppInstaller_*'
    if ($null -ne $Package) {
        if ($Package.Name -cne 'Microsoft.DesktopAppInstaller' -or $Package.PackageFamilyName -cne $expectedFamily) {
            throw 'WinGet AppX metadata has the wrong package family.'
        }

        $location = [IO.Path]::GetFullPath([string]$Package.InstallLocation).TrimEnd([char[]]'\/')
        if (-not [string]::Equals($directory, $location, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'WinGet candidate does not belong to the supplied AppX installation.'
        }
    }

    Assert-TrustedFileSystemPath -Path $directory -Directory
    $manifestPath = Join-Path $directory 'AppxManifest.xml'
    # Probe only through the no-follow trusted reader. Get-Item/Test-Path can
    # follow an existing malicious manifest reparse point before its validation.
    try { $manifestStream = Open-TrustedFileRead -Path $manifestPath }
    catch {
        $errorCause = $_.Exception
        while ($null -ne $errorCause.InnerException) { $errorCause = $errorCause.InnerException }
        $missing = $errorCause -is [IO.FileNotFoundException] -or
            ($errorCause -is [ComponentModel.Win32Exception] -and $errorCause.NativeErrorCode -eq 2)
        if (-not $missing) { throw }

        if ($null -ne $Package -or $packageDirectory) { throw 'WinGet package manifest is missing.' }
        return $null
    }

    try {
        if ($manifestStream.Length -gt 1048576) { throw 'WinGet package manifest exceeds the bounded size.' }

        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $settings.MaxCharactersInDocument = 1048576
        $reader = [Xml.XmlReader]::Create($manifestStream, $settings)
        try {
            $document = New-Object Xml.XmlDocument
            $document.XmlResolver = $null
            $document.Load($reader)
        }
        finally { $reader.Dispose() }
    }
    finally { $manifestStream.Dispose() }

    if ($document.DocumentElement.NamespaceURI -notin @(
        'http://schemas.microsoft.com/appx/manifest/foundation/windows10',
        'http://schemas.microsoft.com/appx/2010/manifest'
    )) { throw 'WinGet manifest has an unsupported package schema.' }

    $identities = $document.SelectNodes("/*[local-name()='Package']/*[local-name()='Identity' and namespace-uri()=namespace-uri(..)]")
    if ($identities.Count -ne 1) { throw 'WinGet package must contain exactly one manifest identity.' }

    $identity = $identities[0]
    $family = $identity.GetAttribute('Name') + '_' + (Get-WinGetPublisherId -Publisher $identity.GetAttribute('Publisher'))
    if ($family -cne $expectedFamily) { throw 'WinGet manifest has the wrong package family or publisher identity.' }

    $architecture = $identity.GetAttribute('ProcessorArchitecture').ToLowerInvariant()
    if (-not $architecture) { $architecture = 'neutral' }
    if ($architecture -notin @('arm64','x64','x86','neutral')) { throw 'Unsupported WinGet package architecture.' }

    $versionText = $identity.GetAttribute('Version')
    if ($versionText -cnotmatch '^[0-9]+(?:\.[0-9]+){3}$') { throw 'Invalid four-part WinGet package version.' }

    $version = [version]$versionText
    if (@($version.Major,$version.Minor,$version.Build,$version.Revision | Where-Object { $_ -gt 65535 }).Count) {
        throw 'WinGet package version component exceeds AppX limits.'
    }
    if ($null -ne $Package) {
        if ([string]$Package.Publisher -cne $identity.GetAttribute('Publisher') -or [version]$Package.Version -ne $version -or
            ([string]$Package.Architecture).ToLowerInvariant() -cne $architecture) {
            throw 'WinGet AppX metadata disagrees with its protected manifest.'
        }
    }

    [pscustomobject]@{ PackageFamilyName = $family; Architecture = $architecture; Version = $version }
}

function Assert-WinGetProductIdentity {
    param([Parameter(Mandatory)]$Metadata)

    $upstreamCli = $Metadata.InternalName -ceq 'winget.exe' -and $Metadata.ProductName -ceq 'WinGet CLI'
    $appInstallerCli = $Metadata.InternalName -ceq 'AppInstallerCLI' -and
        $Metadata.ProductName -ceq 'Microsoft Desktop App Installer'
    if ($Metadata.OriginalFilename -ceq 'winget.exe' -and ($upstreamCli -or $appInstallerCli)) { return }

    # These bytes have not passed Authenticode yet. Bound each diagnostic field
    # BEFORE escaping, and make it printable ASCII to prevent control/bidi/log
    # injection or an unbounded exception from attacker-controlled resources.
    $fields = foreach ($name in @('OriginalFilename','InternalName','ProductName')) {
        $value = [string]$Metadata.$name
        $truncated = $value.Length -gt 128
        if ($truncated) { $value = $value.Substring(0, 128) }

        $escaped = foreach ($character in $value.ToCharArray()) {
            $code = [int]$character
            if ($code -lt 32 -or $code -gt 126 -or $code -eq 39 -or $code -eq 92) {
                '\u{0:x4}' -f $code
            }
            else { [string]$character }
        }

        $display = -join $escaped
        if ($truncated) { $display += '...' }

        "$name='$display'"
    }

    throw ('File is not the actual WinGet CLI product. Observed PE identity: ' + ($fields -join ', '))
}

function Open-TrustedWinGetCandidate {
    param([Parameter(Mandatory)][string]$Path, $Package)

    if (-not [IO.Path]::IsPathRooted($Path) -or [IO.Path]::GetFileName($Path) -ine 'winget.exe') {
        throw 'WinGet requires an absolute winget.exe file path, never a command alias.'
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-TrustedFileSystemPath -Path $fullPath
    $stream = Open-TrustedFileRead -Path $fullPath
    $leased = $false
    try {
        if (-not $stream.CanRead -or $stream.CanWrite -or -not $stream.CanSeek) { throw 'WinGet requires a protected read-only seekable handle.' }

        Initialize-WinGetTrustNativeApi
        $metadata = [Softwarekatalog.WinGetTrustNative]::ReadMetadata($stream)
        Assert-WinGetProductIdentity -Metadata $metadata

        $signature = Get-WinGetSignatureEvidence -Stream $stream -Path $fullPath
        if ($signature.AuthenticodeStatus -ne 0 -or $signature.MicrosoftRootStatus -ne 0 -or
            $signature.SignerOrganization -cne 'Microsoft Corporation') {
            throw 'WinGet requires valid Microsoft-production Authenticode and an authenticated Microsoft publisher.'
        }

        $identity = Get-WinGetPackageIdentity -Path $fullPath -Package $Package
        $family = $null
        if ($null -ne $identity) {
            if ($identity.Architecture -ne 'neutral' -and $identity.Architecture -cne $metadata.Architecture) {
                throw 'WinGet PE architecture disagrees with its protected package identity.'
            }

            $family = $identity.PackageFamilyName
        }

        $lease = New-Object Softwarekatalog.WinGetCandidateLease($fullPath, $metadata, $family, $stream)
        $leased = $true
        return $lease
    }
    finally { if (-not $leased) { $stream.Dispose() } }
}

function Assert-TrustedWinGetCandidate {
    param([Parameter(Mandatory)][string]$Path, $Package)

    $lease = Open-TrustedWinGetCandidate -Path $Path -Package $Package
    try {
        [pscustomobject]@{ Path = $lease.Path; Architecture = $lease.Architecture
            Version = $lease.Version; PackageFamilyName = $lease.PackageFamilyName }
    }
    finally { $lease.Dispose() }
}

function Select-TrustedWinGetCandidate {
    param([object[]]$Candidates, [Parameter(Mandatory)][ValidateSet('arm64','x64','x86')][string]$NativeArchitecture)

    $preference = @(switch ($NativeArchitecture) {
        arm64 { @('arm64','x64','x86') }
        x64 { @('x64','x86') }
        x86 { @('x86') }
    })

    # Preserve all metadata claims for duplicate paths. A negative AppX identity
    # must not be laundered into a metadata-free PATH/portable fallback.
    $groups = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) { continue }

        $path = if ($candidate -is [string]) { $candidate } else { [string]$candidate.Path }
        if (-not [IO.Path]::IsPathRooted($path)) { continue }

        try { $canonical = [IO.Path]::GetFullPath($path) }
        catch { Write-Verbose "Rejected invalid WinGet path: $($_.Exception.Message)"; continue }

        if (-not $groups.ContainsKey($canonical)) { $groups.Add($canonical, (New-Object 'Collections.Generic.List[object]')) }
        $package = $null
        if ($candidate -is [Collections.IDictionary]) {
            if ($candidate.Contains('Package')) { $package = $candidate['Package'] }
        }
        elseif ($candidate -isnot [string] -and $candidate.PSObject.Properties['Package']) { $package = $candidate.Package }

        if ($null -ne $package) { $groups[$canonical].Add($package) }
    }

    $leases = New-Object 'Collections.Generic.List[object]'
    $selected = $null
    try {
        foreach ($path in $groups.Keys) {
            $lease = $null
            try {
                $packages = @($groups[$path].ToArray())
                if ($packages.Count -eq 0) { $packages = @($null) }
                foreach ($package in $packages) {
                    $verified = Open-TrustedWinGetCandidate -Path $path -Package $package
                    if ($null -eq $lease) { $lease = $verified }
                    else { $verified.Dispose() }
                }

                $rank = [array]::IndexOf($preference, $lease.Architecture)
                if ($rank -lt 0) { $lease.Dispose(); continue }

                $leases.Add([pscustomobject]@{ Lease = $lease; Rank = $rank; Version = $lease.Version; Path = $path })
            }
            catch {
                if ($null -ne $lease) { $lease.Dispose() }
                Write-Verbose "Rejected unauthenticated WinGet candidate '$path': $($_.Exception.Message)"
            }
        }

        $best = $leases | Sort-Object Rank, @{ Expression = { $_.Version }; Descending = $true }, Path | Select-Object -First 1
        if ($null -ne $best) { $selected = $best.Lease }
        return $selected
    }
    finally {
        foreach ($entry in $leases) {
            if (-not [object]::ReferenceEquals($entry.Lease, $selected)) { $entry.Lease.Dispose() }
        }
    }
}
