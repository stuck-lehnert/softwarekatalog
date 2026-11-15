# Portable contract tests. ONLY filesystem trust and Windows signature APIs are
# doubled. Production PE parsing, package identity, selection and lease cleanup
# run unchanged against harmless synthetic PE DATA; no candidate is executed.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules/WinGet.Trust.ps1')
Initialize-WinGetTrustNativeApi

$script:root = Join-Path ([IO.Path]::GetTempPath()) ('winget-trust-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:root | Out-Null
$script:opened = New-Object 'Collections.Generic.List[IO.FileStream]'
$script:signatureCalls = New-Object 'Collections.Generic.List[string]'
$script:unsafePaths = @{}
$script:signatures = @{}
$script:passed = 0
$script:failures = New-Object 'Collections.Generic.List[string]'
$script:publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'

function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    try { & $Body | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected exception matching '$Pattern'."
}
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Output "PASS $Name" }
    catch { $script:failures.Add("${Name}: $_`n$($_.ScriptStackTrace)"); Write-Output "FAIL ${Name}: $_" }
}

function Assert-TrustedFileSystemPath {
    param([string]$Path, [switch]$Directory)
    if ($script:unsafePaths.ContainsKey($Path)) { throw 'Untrusted owner/DACL/reparse filesystem boundary.' }
}
function Open-TrustedFileRead {
    param([string]$Path)
    Assert-TrustedFileSystemPath -Path $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $script:opened.Add($stream)
    return $stream
}
function Get-WinGetSignatureEvidence {
    param([IO.FileStream]$Stream, [string]$Path)
    Assert ($Stream.CanRead -and -not $Stream.CanWrite -and -not $Stream.SafeFileHandle.IsClosed) 'Signature boundary received a closed/writable/different-kind handle.'
    $script:signatureCalls.Add($Path)
    if ($script:signatures.ContainsKey($Path)) { return $script:signatures[$Path] }
    [pscustomobject]@{ AuthenticodeStatus = 0; MicrosoftRootStatus = 0; SignerOrganization = 'Microsoft Corporation' }
}

function Set-Word([byte[]]$Bytes, [int]$Offset, [uint16]$Value) { [BitConverter]::GetBytes($Value).CopyTo($Bytes, $Offset) }
function Set-Dword([byte[]]$Bytes, [int]$Offset, [uint32]$Value) { [BitConverter]::GetBytes($Value).CopyTo($Bytes, $Offset) }
function New-VersionNode {
    param([string]$Key, [byte[]]$Value = @(), [uint16]$Type = 0, [byte[][]]$Children = @())

    $memory = New-Object IO.MemoryStream
    $writer = New-Object IO.BinaryWriter($memory)
    try {
        $writer.Write([uint16]0)
        $valueLength = if ($Type -eq 1) { $Value.Length / 2 } else { $Value.Length }
        $writer.Write([uint16]$valueLength)
        $writer.Write($Type)
        $writer.Write([Text.Encoding]::Unicode.GetBytes($Key + [char]0))
        while (($memory.Position % 4) -ne 0) { $writer.Write([byte]0) }
        $writer.Write($Value)
        foreach ($child in $Children) {
            while (($memory.Position % 4) -ne 0) { $writer.Write([byte]0) }
            $writer.Write($child)
        }

        $bytes = $memory.ToArray()
        Set-Word $bytes 0 ([uint16]$bytes.Length)
        return ,$bytes
    }
    finally { $writer.Dispose(); $memory.Dispose() }
}

function New-TestCandidate {
    param([string]$Name, [ValidateSet('x64','arm64','x86')][string]$Architecture = 'x64',
        [version]$Version = '1.12.300.0', [string]$OriginalFilename = 'winget.exe',
        [string]$InternalName = 'winget.exe', [string]$ProductName = 'WinGet CLI')

    $strings = New-Object 'Collections.Generic.List[byte[]]'
    foreach ($entry in @(@('OriginalFilename',$OriginalFilename), @('InternalName',$InternalName), @('ProductName',$ProductName))) {
        $strings.Add((New-VersionNode -Key $entry[0] -Type 1 -Value ([Text.Encoding]::Unicode.GetBytes($entry[1] + [char]0))))
    }
    $table = New-VersionNode -Key '040904B0' -Type 1 -Children $strings.ToArray()
    $stringInfo = New-VersionNode -Key StringFileInfo -Type 1 -Children (,$table)
    $fixed = New-Object byte[] 52
    Set-Dword $fixed 0 4277077181 # VS_FFI_SIGNATURE = 0xFEEF04BD
    Set-Dword $fixed 4 65536
    Set-Dword $fixed 8 ([uint32]($Version.Major * 65536L + $Version.Minor))
    Set-Dword $fixed 12 ([uint32]($Version.Build * 65536L + $Version.Revision))
    Set-Dword $fixed 36 1 # VFT_APP
    $versionNode = New-VersionNode -Key VS_VERSION_INFO -Value $fixed -Children (,$stringInfo)

    # Minimal PE header and .rsrc section, not executable program code. Resource
    # RVAs map to actual bytes so the production parser is not replaced.
    $bytes = New-Object byte[] 8192
    Set-Word $bytes 0 0x5a4d
    Set-Dword $bytes 60 128
    Set-Dword $bytes 128 0x00004550
    $machine = switch ($Architecture) { x64 { 0x8664 } arm64 { 0xaa64 } x86 { 0x014c } }
    Set-Word $bytes 132 $machine
    Set-Word $bytes 134 1
    $optionalSize = if ($Architecture -eq 'x86') { 224 } else { 240 }
    Set-Word $bytes 148 $optionalSize
    Set-Word $bytes 150 2
    $optional = 152
    $magic = if ($Architecture -eq 'x86') { 0x10b } else { 0x20b }
    Set-Word $bytes $optional $magic
    Set-Word $bytes ($optional + 68) 3
    $directories = if ($Architecture -eq 'x86') { 96 } else { 112 }
    Set-Dword $bytes ($optional + $directories - 4) 16
    Set-Dword $bytes ($optional + $directories + 16) 4096
    Set-Dword $bytes ($optional + $directories + 20) 4096

    $section = $optional + $optionalSize
    Set-Dword $bytes ($section + 8) 4096
    Set-Dword $bytes ($section + 12) 4096
    Set-Dword $bytes ($section + 16) 4096
    Set-Dword $bytes ($section + 20) 512
    $resource = 512
    Set-Word $bytes ($resource + 14) 1
    Set-Dword $bytes ($resource + 16) 16
    Set-Dword $bytes ($resource + 20) 2147483672 # directory flag | 24
    Set-Word $bytes ($resource + 38) 1
    Set-Dword $bytes ($resource + 40) 1
    Set-Dword $bytes ($resource + 44) 2147483696 # directory flag | 48
    Set-Word $bytes ($resource + 62) 1
    Set-Dword $bytes ($resource + 64) 1033
    Set-Dword $bytes ($resource + 68) 72
    Set-Dword $bytes ($resource + 72) 4192 # resource RVA + 96
    Set-Dword $bytes ($resource + 76) $versionNode.Length
    $versionNode.CopyTo($bytes, $resource + 96)

    $directory = Join-Path $script:root $Name
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $path = Join-Path $directory 'winget.exe'
    [IO.File]::WriteAllBytes($path, $bytes)
    return $path
}

function New-TestPackage {
    param([string]$Path, [string]$Architecture = 'x64', [string]$Name = 'Microsoft.DesktopAppInstaller',
        [string]$Publisher = $script:publisher, [string]$Family = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe')

    $directory = Split-Path $Path -Parent
    $escaped = [Security.SecurityElement]::Escape($Publisher)
    $manifest = '<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="{0}" Publisher="{1}" Version="1.27.300.0" ProcessorArchitecture="{2}" /></Package>' -f $Name,$escaped,$Architecture
    [IO.File]::WriteAllText((Join-Path $directory 'AppxManifest.xml'), $manifest)

    [pscustomobject]@{ Name = $Name; PackageFamilyName = $Family; InstallLocation = $directory
        Publisher = $Publisher; Version = [version]'1.27.300.0'; Architecture = $Architecture }
}

try {
    Case 'Native verification structures preserve Windows pointer alignment and signer-chain offsets' {
        foreach ($layout in @(
            @('TrustFile',32,16), @('TrustData',88,52), @('ProviderSigner',64,44),
            @('ProviderCertificate',16,8), @('ChainPolicyParameters',16,12), @('ChainPolicyStatus',24,20)
        )) {
            $type = [Softwarekatalog.WinGetTrustNative].GetNestedType($layout[0], [Reflection.BindingFlags]::NonPublic)
            $instance = [Activator]::CreateInstance($type)
            $expected = if ([IntPtr]::Size -eq 8) { $layout[1] } else { $layout[2] }
            Assert ([Runtime.InteropServices.Marshal]::SizeOf($instance) -eq $expected) "Incorrect $($layout[0]) native structure size."
        }

        $signer = [Softwarekatalog.WinGetTrustNative].GetNestedType('ProviderSigner', [Reflection.BindingFlags]::NonPublic)
        $expectedOffset = if ([IntPtr]::Size -eq 8) { 56 } else { 40 }
        Assert ([Runtime.InteropServices.Marshal]::OffsetOf($signer, 'Chain').ToInt32() -eq $expectedOffset) 'Actual provider signer chain pointer is misaligned.'
    }
    Case 'Microsoft AppX publisher identity is derived, not accepted by CN spelling' {
        Assert ((Get-WinGetPublisherId $script:publisher) -ceq '8wekyb3d8bbwe') 'Known Microsoft AppX publisher-ID vector failed.'
        Assert ((Get-WinGetPublisherId 'CN=Microsoft Corporation, O=Other Company') -cne '8wekyb3d8bbwe') 'Spoofed publisher display name matched Microsoft family.'
    }
    foreach ($architecture in @('x64','arm64','x86')) {
        Case "Actual bounded PE metadata reader decodes $architecture and signed file version" {
            $path = New-TestCandidate -Name "portable-$architecture" -Architecture $architecture
            $record = Assert-TrustedWinGetCandidate $path
            Assert ($record.Architecture -eq $architecture -and $record.Version -eq [version]'1.12.300.0') 'Metadata did not come from the actual PE bytes.'
            Assert (-not $record.PackageFamilyName) 'Portable candidate invented package membership.'
        }
    }
    Case 'Lease keeps the actual read handle alive until caller disposal' {
        $path = New-TestCandidate -Name lease
        $lease = Open-TrustedWinGetCandidate $path
        try {
            Assert ($lease.Stream.CanRead -and -not $lease.Stream.CanWrite) 'Returned lease lost its protected read handle.'
            Assert ([object]::ReferenceEquals($lease.Stream, $script:opened[$script:opened.Count - 1])) 'Lease replaced the verified file handle.'
            if ($env:OS -eq 'Windows_NT') {
                Assert-Throws { [IO.File]::Open($path, 'Open', 'Write', 'ReadWrite').Dispose() } 'used by another process|being used|sharing'
                Write-Output 'Windows read lease also rejects a concurrent write open'
            }
        }
        finally { $lease.Dispose() }
        Assert ($null -eq $lease.Stream) 'Lease was not disposed.'
    }
    Case 'Unsafe path is rejected before opening or inspecting candidate bytes' {
        $path = New-TestCandidate -Name unsafe
        $script:unsafePaths[$path] = $true
        $before = $script:opened.Count
        Assert-Throws { Assert-TrustedWinGetCandidate $path } 'Untrusted owner/DACL/reparse'
        Assert ($script:opened.Count -eq $before) 'Untrusted candidate was opened before path trust.'
    }
    Case 'AppExecLink-like data is rejected without starting it or querying its version' {
        $path = New-TestCandidate -Name alias
        [IO.File]::WriteAllBytes($path, (New-Object byte[] 64))
        $before = $script:signatureCalls.Count
        Assert-Throws { Assert-TrustedWinGetCandidate $path } 'not a PE image'
        Assert ($script:signatureCalls.Count -eq $before) 'Non-PE alias reached signature/version probing.'
    }
    Case 'Renamed genuine Microsoft cmd.exe is not WinGet provenance' {
        $path = New-TestCandidate -Name renamed-cmd -OriginalFilename cmd.exe -InternalName cmd -ProductName 'Microsoft Windows Operating System'
        Assert-Throws { Assert-TrustedWinGetCandidate $path } 'not the actual WinGet CLI product'
    }
    Case 'Original filename alone does not authorize a different Microsoft product' {
        $path = New-TestCandidate -Name wrong-product -ProductName 'Other Microsoft Product'
        Assert-Throws { Assert-TrustedWinGetCandidate $path } 'not the actual WinGet CLI product'
    }
    foreach ($failure in @(
        @{ Name = 'invalid signature'; Auth = -1; Root = 0; Organization = 'Microsoft Corporation' },
        @{ Name = 'foreign root with Microsoft display name'; Auth = 0; Root = 1; Organization = 'Microsoft Corporation' },
        @{ Name = 'foreign signer under an otherwise accepted root'; Auth = 0; Root = 0; Organization = 'Other Company' },
        @{ Name = 'offline revocation validation'; Auth = -2146885613; Root = 0; Organization = 'Microsoft Corporation' }
    )) {
        Case "Reject $($failure.Name) without a validation bypass" {
            $path = New-TestCandidate -Name ('signature-' + $script:passed)
            $script:signatures[$path] = [pscustomobject]@{ AuthenticodeStatus = $failure.Auth; MicrosoftRootStatus = $failure.Root; SignerOrganization = $failure.Organization }
            Assert-Throws { Assert-TrustedWinGetCandidate $path } 'valid Microsoft-production Authenticode'
        }
    }
    Case 'Valid exact AppX family and protected manifest retain individual PE version' {
        $path = New-TestCandidate -Name packaged
        $package = New-TestPackage $path
        $record = Assert-TrustedWinGetCandidate $path -Package $package
        Assert ($record.PackageFamilyName -ceq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe') 'Exact package family was not retained.'
        Assert ($record.Version -eq [version]'1.12.300.0') 'Package/directory version replaced the signed PE version.'
    }
    Case 'Wrong registered AppX package family is rejected' {
        $path = New-TestCandidate -Name wrong-family
        $package = New-TestPackage $path -Family Microsoft.OtherInstaller_8wekyb3d8bbwe
        Assert-Throws { Assert-TrustedWinGetCandidate $path -Package $package } 'wrong package family'
    }
    Case 'Package installation prefix cannot substitute for actual directory membership' {
        $path = New-TestCandidate -Name wrong-location
        $package = New-TestPackage $path
        $package.InstallLocation += '-other'
        Assert-Throws { Assert-TrustedWinGetCandidate $path -Package $package } 'does not belong'
    }
    Case 'Forged Microsoft manifest display name fails derived publisher-family identity' {
        $path = New-TestCandidate -Name forged-publisher
        $package = New-TestPackage $path -Publisher 'CN=Microsoft Corporation, O=Other Company'
        Assert-Throws { Assert-TrustedWinGetCandidate $path -Package $package } 'wrong package family or publisher'
    }
    Case 'Present bad manifest is not ignored for a portable fallback' {
        $path = New-TestCandidate -Name bad-manifest
        $null = New-TestPackage $path -Name Other.Package
        Assert-Throws { Assert-TrustedWinGetCandidate $path } 'wrong package family or publisher'
    }
    Case 'Missing manifest cannot downgrade a WindowsApps-shaped package to portable' {
        $path = New-TestCandidate -Name Microsoft.DesktopAppInstaller_9999.0.0.0_x64__8wekyb3d8bbwe
        Assert-Throws { Assert-TrustedWinGetCandidate $path } 'manifest is missing'
    }
    Case 'Untrusted manifest path fails closed despite valid executable evidence' {
        $path = New-TestCandidate -Name unsafe-manifest
        $package = New-TestPackage $path
        $script:unsafePaths[(Join-Path (Split-Path $path -Parent) AppxManifest.xml)] = $true
        Assert-Throws { Assert-TrustedWinGetCandidate $path -Package $package } 'Untrusted owner/DACL/reparse'
    }
    Case 'Package manifest architecture must agree with actual PE machine type' {
        $path = New-TestCandidate -Name wrong-package-arch -Architecture x64
        $package = New-TestPackage $path -Architecture arm64
        Assert-Throws { Assert-TrustedWinGetCandidate $path -Package $package } 'PE architecture disagrees'
    }
    Case 'Registered package metadata cannot contradict protected manifest version' {
        $path = New-TestCandidate -Name wrong-package-version
        $package = New-TestPackage $path
        $package.Version = [version]'9999.0.0.0'
        Assert-Throws { Assert-TrustedWinGetCandidate $path -Package $package } 'metadata disagrees'
    }
    Case 'Valid protected manifest is enforced even without AppX registration metadata' {
        $path = New-TestCandidate -Name manifest-only
        $null = New-TestPackage $path
        $record = Assert-TrustedWinGetCandidate $path
        Assert ($record.PackageFamilyName -ceq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe') 'Manifest identity was silently treated as portable.'
    }
    Case 'Supplied package metadata cannot fall back when its manifest is absent' {
        $path = New-TestCandidate -Name missing-metadata-manifest
        $package = New-TestPackage $path
        Remove-Item -LiteralPath (Join-Path (Split-Path $path -Parent) AppxManifest.xml)
        Assert-Throws { Assert-TrustedWinGetCandidate $path -Package $package } 'manifest is missing'
    }
    Case 'Foreign XML namespace cannot impersonate the AppX identity schema' {
        $path = New-TestCandidate -Name foreign-schema
        $null = New-TestPackage $path
        $manifest = Join-Path (Split-Path $path -Parent) AppxManifest.xml
        $text = [IO.File]::ReadAllText($manifest).Replace('http://schemas.microsoft.com/appx/manifest/foundation/windows10','https://example.invalid/not-appx')
        [IO.File]::WriteAllText($manifest, $text)
        Assert-Throws { Assert-TrustedWinGetCandidate $path } 'unsupported package schema'
    }
    foreach ($invalidVersion in @('1.27','1.27.300.65536')) {
        Case "Manifest package version $invalidVersion must obey the actual AppX four-part format" {
            $path = New-TestCandidate -Name "invalid-version-$invalidVersion"
            $null = New-TestPackage $path
            $manifest = Join-Path (Split-Path $path -Parent) AppxManifest.xml
            $text = [IO.File]::ReadAllText($manifest).Replace('1.27.300.0', $invalidVersion)
            [IO.File]::WriteAllText($manifest, $text)
            Assert-Throws { Assert-TrustedWinGetCandidate $path } 'four-part|exceeds AppX limits'
        }
    }
    Case 'Foreign identity element cannot hide inside an otherwise valid AppX namespace' {
        $path = New-TestCandidate -Name foreign-identity-schema
        $null = New-TestPackage $path
        $manifest = Join-Path (Split-Path $path -Parent) AppxManifest.xml
        $text = [IO.File]::ReadAllText($manifest).Replace('<Identity ', '<Identity xmlns="https://example.invalid/not-appx" ')
        [IO.File]::WriteAllText($manifest, $text)
        Assert-Throws { Assert-TrustedWinGetCandidate $path } 'exactly one manifest identity'
    }
    Case 'Manifest DTD and external entities are prohibited, not fetched' {
        $path = New-TestCandidate -Name manifest-dtd
        [IO.File]::WriteAllText((Join-Path (Split-Path $path -Parent) AppxManifest.xml), '<!DOCTYPE Package [<!ENTITY bad SYSTEM "https://example.invalid/never">]><Package>&bad;</Package>')
        Assert-Throws { Assert-TrustedWinGetCandidate $path } 'DTD|prohibit|security reasons'
    }
    Case 'Native ARM64 outranks newer authenticated x64; forged higher version is discarded first' {
        $arm = New-TestCandidate -Name rank-arm -Architecture arm64 -Version 1.0.0.0
        $x64 = New-TestCandidate -Name rank-x64 -Version 9.0.0.0
        $bad = New-TestCandidate -Name rank-untrusted-arm -Architecture arm64 -Version 99.0.0.0
        $script:signatures[$bad] = [pscustomobject]@{ AuthenticodeStatus = -1; MicrosoftRootStatus = 0; SignerOrganization = 'Microsoft Corporation' }
        $lease = Select-TrustedWinGetCandidate @($bad,$x64,$arm) -NativeArchitecture arm64
        try { Assert ($null -ne $lease -and $lease.Path -eq $arm -and $lease.Stream.CanRead) 'Architecture/version ranking trusted an unauthenticated candidate.' }
        finally { if ($null -ne $lease) { $lease.Dispose() } }
    }
    Case 'Native x64 chooses newest authenticated x64 and cannot choose ARM64' {
        $arm = New-TestCandidate -Name rank-x64-host-arm -Architecture arm64 -Version 99.0.0.0
        $older = New-TestCandidate -Name rank-x64-old -Version 1.0.0.0
        $newer = New-TestCandidate -Name rank-x64-new -Version 2.0.0.0
        $lease = Select-TrustedWinGetCandidate @($arm,$older,$newer) -NativeArchitecture x64
        try { Assert ($null -ne $lease -and $lease.Path -eq $newer) 'Native x64 ranking used names or the wrong architecture.' }
        finally { if ($null -ne $lease) { $lease.Dispose() } }
    }
    Case 'Single-choice native x86 ranking stays an array and excludes x64/ARM64' {
        $x86 = New-TestCandidate -Name rank-x86-native -Architecture x86
        $x64 = New-TestCandidate -Name rank-x86-other -Architecture x64 -Version 99.0.0.0
        $lease = Select-TrustedWinGetCandidate @($x64,$x86) -NativeArchitecture x86
        try { Assert ($null -ne $lease -and $lease.Path -eq $x86) 'Native x86 selection was malformed or selected x64.' }
        finally { if ($null -ne $lease) { $lease.Dispose() } }
    }
    Case 'Duplicate bare PATH candidate cannot launder negative AppX metadata' {
        $path = New-TestCandidate -Name duplicate-negative
        $package = New-TestPackage $path -Family Wrong.Package_otherpublisher
        $lease = Select-TrustedWinGetCandidate @($path,@{ Path = $path; Package = $package }) -NativeArchitecture x64
        try { Assert ($null -eq $lease) 'Bare PATH fallback bypassed negative same-file AppX metadata.' }
        finally { if ($null -ne $lease) { $lease.Dispose() } }
    }
    Case 'Later negative metadata also closes an earlier authenticated duplicate lease' {
        $path = New-TestCandidate -Name duplicate-mixed
        $valid = New-TestPackage $path
        $invalid = $valid | Select-Object *
        $invalid.PackageFamilyName = 'Wrong.Package_otherpublisher'
        $lease = Select-TrustedWinGetCandidate @(@{ Path=$path; Package=$valid }, $path, @{ Path=$path; Package=$invalid }) -NativeArchitecture x64
        try { Assert ($null -eq $lease) 'A prior positive duplicate bypassed later negative metadata.' }
        finally { if ($null -ne $lease) { $lease.Dispose() } }
    }
    Case 'All rejected or absent candidates yield no executable path' {
        $path = New-TestCandidate -Name all-rejected
        $script:unsafePaths[$path] = $true
        Assert ($null -eq (Select-TrustedWinGetCandidate @($path) -NativeArchitecture x64)) 'Rejected path was returned.'
        Assert ($null -eq (Select-TrustedWinGetCandidate @() -NativeArchitecture arm64)) 'Absent candidates produced a path.'
    }
    Case 'Positive authentication is not cached after a snapshot closes its lease' {
        $path = New-TestCandidate -Name no-cache
        $null = Assert-TrustedWinGetCandidate $path
        $script:signatures[$path] = [pscustomobject]@{ AuthenticodeStatus = -1; MicrosoftRootStatus = 0; SignerOrganization = 'Microsoft Corporation' }
        Assert-Throws { Assert-TrustedWinGetCandidate $path } 'valid Microsoft-production Authenticode'
    }
    foreach ($malformation in @('header-range','resource-range','language-cycle','unknown-machine','dll')) {
        Case "Bounded real PE parser rejects $malformation" {
            $path = New-TestCandidate -Name "malformed-$malformation"
            $bytes = [IO.File]::ReadAllBytes($path)
            switch ($malformation) {
                header-range { Set-Dword $bytes 60 ([uint32]::MaxValue) }
                resource-range { Set-Dword $bytes (152 + 112 + 20) ([uint32]::MaxValue) }
                language-cycle { Set-Dword $bytes (512 + 68) 2147483648 }
                unknown-machine { Set-Word $bytes 132 0x01c4 }
                dll { Set-Word $bytes 150 0x2002 }
            }
            [IO.File]::WriteAllBytes($path, $bytes)
            Assert-Throws { Assert-TrustedWinGetCandidate $path } 'PE|architecture|version language'
        }
    }
    Case 'All rejected, snapshot and unselected candidate/manifest handles are closed' {
        Assert (@($script:opened | Where-Object { $_.CanRead }).Count -eq 0) 'A rejected/unselected candidate leaked a read lease.'
    }
}
finally {
    foreach ($stream in $script:opened) { $stream.Dispose() }
    Remove-Item -LiteralPath $script:root -Recurse -Force
}

if ($script:failures.Count) { throw ($script:failures -join "`n`n") }
Write-Output "$script:passed WinGet trust contract checks passed; native cryptographic APIs require Windows CI."
