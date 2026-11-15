# Read-only native SYSTEM verification. Never register, install or execute any
# downloaded candidate. The caller supplies an existing protected scratch root.
# Example: powershell.exe -File Test-WinGetTrustNative.ps1 -Root C:\ProtectedCI
#          -SourceRoot C:\ProtectedSource -NativeArchitecture arm64
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [string]$SourceRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [ValidateSet('x64','arm64')][string]$NativeArchitecture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NativeTrust($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-NativeDownloadUri([Uri]$Uri) {
    $allowedHosts = @('api.github.com','github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')
    if ($Uri.Scheme -cne 'https' -or $Uri.Port -ne 443 -or $Uri.UserInfo -or $Uri.Host -notin $allowedHosts) {
        throw 'WinGet test download escaped its HTTPS Microsoft GitHub release hosts.'
    }
}

function Save-NativeTrustDownload {
    param([Uri]$Uri, [string]$Destination, [long]$MaximumBytes, [int]$TimeoutSeconds = 300)

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object Net.Http.HttpClient($handler)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('softwarekatalog-native-winget-trust-test')
    $cancellation = New-Object Threading.CancellationTokenSource([int]($TimeoutSeconds * 1000))
    try {
        for ($redirect = 0; $redirect -le 5; $redirect++) {
            Assert-NativeDownloadUri $Uri
            $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token).GetAwaiter().GetResult()
            try {
                if ([int]$response.StatusCode -in @(301,302,303,307,308)) {
                    if ($null -eq $response.Headers.Location) { throw 'Download redirect has no location.' }

                    $Uri = New-Object Uri($Uri, $response.Headers.Location)
                    continue
                }

                $null = $response.EnsureSuccessStatusCode()
                $declaredLength = $response.Content.Headers.ContentLength
                if ($null -ne $declaredLength -and ($declaredLength -lt 1 -or $declaredLength -gt $MaximumBytes)) {
                    throw 'Native WinGet download exceeds its bounded size.'
                }

                $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                try {
                    $outputStream = New-Object IO.FileStream($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try {
                        $buffer = New-Object byte[] 65536
                        [long]$written = 0
                        while ($true) {
                            $read = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $cancellation.Token)
                            # Also cancel the wait: .NET Framework response streams
                            # need not interrupt an already pending ReadAsync.
                            $read.Wait($cancellation.Token)
                            $count = $read.GetAwaiter().GetResult()
                            if ($count -eq 0) { break }

                            $written += $count
                            if ($written -gt $MaximumBytes) { throw 'Native WinGet download exceeded its bounded size while streaming.' }

                            $outputStream.Write($buffer, 0, $count)
                        }
                        if ($written -eq 0 -or ($null -ne $declaredLength -and $written -ne $declaredLength)) {
                            throw 'Native WinGet download was empty or truncated.'
                        }
                    }
                    finally { $outputStream.Dispose() }
                }
                finally { $inputStream.Dispose() }

                return
            }
            finally { $response.Dispose() }
        }
        throw 'Native WinGet download exceeded the redirect limit.'
    }
    finally { $cancellation.Dispose(); $client.Dispose() }
}

function Get-NativeTrustZipEntry {
    param([IO.Compression.ZipArchive]$Archive, [string]$Name, [long]$MaximumBytes)

    $entries = @($Archive.Entries | Where-Object { $_.FullName -ceq $Name })
    if ($entries.Count -ne 1 -or $entries[0].Length -lt 1 -or $entries[0].Length -gt $MaximumBytes) {
        throw "Archive must contain exactly one bounded '$Name' entry."
    }

    return $entries[0]
}

function Expand-NativeTrustZipEntry {
    param([IO.Compression.ZipArchiveEntry]$Entry, [string]$Destination, [long]$MaximumBytes)

    if ($Entry.Length -gt $MaximumBytes) { throw 'Native archive entry exceeds its bounded size.' }

    $inputStream = $Entry.Open()
    try {
        $outputStream = New-Object IO.FileStream($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $buffer = New-Object byte[] 65536
            [long]$written = 0
            while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $written += $count
                if ($written -gt $MaximumBytes) { throw 'Expanded archive entry exceeded its bounded size.' }

                $outputStream.Write($buffer, 0, $count)
            }
            if ($written -ne $Entry.Length) { throw 'Expanded native archive entry was truncated.' }
        }
        finally { $outputStream.Dispose() }
    }
    finally { $inputStream.Dispose() }
}

function Read-NativeTrustXml([IO.Stream]$Stream) {
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 1048576
    $reader = [Xml.XmlReader]::Create($Stream, $settings)
    try {
        $document = New-Object Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
        return ,$document
    }
    finally { $reader.Dispose() }
}

function Assert-NativeTrustRejection {
    param([scriptblock]$Body, [string]$Name, [string]$MessagePattern = '.')

    try { $lease = & $Body }
    catch {
        if ($_.Exception.Message -notmatch $MessagePattern) { throw }

        Write-Output "PASS WinGetNative rejects $Name"
        return
    }

    if ($null -ne $lease -and $lease -is [IDisposable]) { $lease.Dispose() }
    throw "Native WinGet trust incorrectly accepted $Name."
}

function Assert-NativeTrustSharingFailure([scriptblock]$Body, [string]$Name) {
    try { & $Body }
    catch {
        $cause = $_.Exception
        while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
        if ($cause -isnot [IO.IOException] -or ($cause.HResult -band 0xffff) -ne 32) { throw }

        Write-Output "PASS WinGetNative held handle blocks $Name with ERROR_SHARING_VIOLATION"
        return
    }
    throw "Held WinGet lease did not block $Name."
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Native WinGet trust test requires Windows.' }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try { Assert-NativeTrust ($identity.User.Value -ceq 'S-1-5-18') 'Native WinGet trust test must run as SYSTEM.' }
finally { $identity.Dispose() }

Assert-NativeTrust ([Environment]::Is64BitProcess) 'Native WinGet test requires 64-bit PowerShell.'
if (-not ('Softwarekatalog.WinGetNativeTestSystem' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Softwarekatalog {
    public static class WinGetNativeTestSystem {
        [DllImport("kernel32.dll")] static extern void GetNativeSystemInfo(IntPtr information);

        public static string GetArchitecture() {
            IntPtr information = Marshal.AllocHGlobal(64);
            try {
                GetNativeSystemInfo(information);
                ushort architecture = (ushort)Marshal.ReadInt16(information);
                if (architecture == 9) return "x64";
                if (architecture == 12) return "arm64";

                throw new InvalidOperationException("Native test supports only x64 and ARM64 Windows.");
            }
            finally { Marshal.FreeHGlobal(information); }
        }
    }
}
'@
}

$actualArchitecture = [Softwarekatalog.WinGetNativeTestSystem]::GetArchitecture()
if ($NativeArchitecture -and $NativeArchitecture -cne $actualArchitecture) { throw 'Requested native architecture disagrees with Windows.' }

$NativeArchitecture = $actualArchitecture
. (Join-Path $SourceRoot 'modules/FileSystem.Security.ps1')
. (Join-Path $SourceRoot 'modules/WinGet.Trust.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
Assert-TrustedFileSystemPath -Path $Root -Directory

$workRoot = Join-Path $Root ('WinGetNative-' + [Guid]::NewGuid().ToString('N'))
New-TrustedDirectory -Path $workRoot
$junction = $null
$lease = $null
$originalProtocols = [Net.ServicePointManager]::SecurityProtocol
try {
    [Net.ServicePointManager]::SecurityProtocol = $originalProtocols -bor [Net.SecurityProtocolType]::Tls12
    $releasePath = Join-Path $workRoot 'release.json'
    Save-NativeTrustDownload -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Destination $releasePath -MaximumBytes 2097152 -TimeoutSeconds 60
    $release = [IO.File]::ReadAllText($releasePath) | ConvertFrom-Json
    Assert-NativeTrust (-not $release.draft -and -not $release.prerelease) 'Official latest release is not a stable public release.'

    $assetName = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    $assets = @($release.assets | Where-Object { $_.name -ceq $assetName })
    Assert-NativeTrust ($assets.Count -eq 1) 'Official release does not expose exactly one expected App Installer bundle.'
    Assert-NativeTrust ($assets[0].size -ge 1 -and $assets[0].size -le 536870912) 'Official bundle size exceeds the 512 MiB test bound.'

    $assetUri = [Uri]$assets[0].browser_download_url
    Assert-NativeDownloadUri $assetUri
    Assert-NativeTrust ($assetUri.Host -ceq 'github.com' -and $assetUri.AbsolutePath -cmatch '^/microsoft/winget-cli/releases/download/[^/]+/Microsoft\.DesktopAppInstaller_8wekyb3d8bbwe\.msixbundle$') 'Asset is not the official Microsoft release download.'
    $bundlePath = Join-Path $workRoot $assetName
    Save-NativeTrustDownload -Uri $assetUri -Destination $bundlePath -MaximumBytes 536870912
    Assert-NativeTrust (([IO.FileInfo]$bundlePath).Length -eq $assets[0].size) 'Downloaded bundle length disagrees with release metadata.'

    $packagePath = Join-Path $workRoot 'NativePackage.msix'
    $bundle = [IO.Compression.ZipFile]::OpenRead($bundlePath)
    try {
        $manifestEntry = Get-NativeTrustZipEntry $bundle 'AppxMetadata/AppxBundleManifest.xml' 1048576
        $manifestStream = $manifestEntry.Open()
        try { $bundleManifest = Read-NativeTrustXml $manifestStream }
        finally { $manifestStream.Dispose() }

        $packages = @($bundleManifest.SelectNodes("/*[local-name()='Bundle']/*[local-name()='Packages']/*[local-name()='Package']") | Where-Object {
            $_.GetAttribute('Type') -ceq 'application' -and $_.GetAttribute('Architecture') -ceq $NativeArchitecture
        })
        Assert-NativeTrust ($packages.Count -eq 1) 'Bundle does not contain exactly one native application package.'
        $packageName = $packages[0].GetAttribute('FileName')
        Assert-NativeTrust ($packageName -and $packageName -ceq [IO.Path]::GetFileName($packageName) -and $packageName -notmatch '[:\\/]') 'Bundle package entry is not a simple archive member.'
        $packageEntry = Get-NativeTrustZipEntry $bundle $packageName 536870912
        Expand-NativeTrustZipEntry $packageEntry $packagePath 536870912
    }
    finally { $bundle.Dispose() }

    $nativeRoot = Join-Path $workRoot 'OriginalNativePackage'
    New-TrustedDirectory -Path $nativeRoot
    $wingetPath = Join-Path $nativeRoot 'winget.exe'
    $manifestPath = Join-Path $nativeRoot 'AppxManifest.xml'
    $packageArchive = [IO.Compression.ZipFile]::OpenRead($packagePath)
    try {
        # Only fixed, exact members are extracted; no bulk extraction or zip-slip.
        Expand-NativeTrustZipEntry (Get-NativeTrustZipEntry $packageArchive 'winget.exe' 134217728) $wingetPath 134217728
        Expand-NativeTrustZipEntry (Get-NativeTrustZipEntry $packageArchive 'AppxManifest.xml' 1048576) $manifestPath 1048576
    }
    finally { $packageArchive.Dispose() }

    $manifestStream = Open-TrustedFileRead $manifestPath
    try { $manifest = Read-NativeTrustXml $manifestStream }
    finally { $manifestStream.Dispose() }
    $packageIdentities = $manifest.SelectNodes("/*[local-name()='Package']/*[local-name()='Identity']")
    Assert-NativeTrust ($packageIdentities.Count -eq 1) 'Original Microsoft package manifest identity is ambiguous.'
    $packageIdentity = $packageIdentities[0]
    $package = [pscustomobject]@{
        Name = $packageIdentity.GetAttribute('Name')
        PackageFamilyName = $packageIdentity.GetAttribute('Name') + '_' + (Get-WinGetPublisherId $packageIdentity.GetAttribute('Publisher'))
        InstallLocation = $nativeRoot
        Publisher = $packageIdentity.GetAttribute('Publisher')
        Version = [version]$packageIdentity.GetAttribute('Version')
        Architecture = $packageIdentity.GetAttribute('ProcessorArchitecture')
    }
    Assert-NativeTrust ($package.PackageFamilyName -ceq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe') 'Downloaded manifest is not the genuine Desktop App Installer family.'

    $lease = Open-TrustedWinGetCandidate -Path $wingetPath -Package $package
    Assert-NativeTrust ($lease.Architecture -ceq $NativeArchitecture -and $lease.Stream.CanRead -and -not $lease.Stream.CanWrite) 'Genuine native WinGet lost its authenticated architecture or held read-only handle.'
    Write-Output "PASS WinGetNative genuine Microsoft release $($release.tag_name) $NativeArchitecture $($lease.Version) passes real filesystem, WinVerifyTrust, Microsoft policy and PE identity"

    Assert-NativeTrustSharingFailure {
        $writer = [IO.File]::Open($wingetPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $writer.Dispose()
    } 'concurrent write access'
    Assert-NativeTrustSharingFailure { [IO.File]::Delete($wingetPath) } 'deletion'
    Assert-NativeTrustSharingFailure { [IO.File]::Move($wingetPath, (Join-Path $nativeRoot 'moved.exe')) } 'rename/replacement'
    $lease.Dispose()
    $lease = $null

    $writer = [IO.File]::Open($wingetPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $writer.Dispose()
    Write-Output 'PASS WinGetNative disposing the lease releases write exclusion without changing executable bytes'

    $wrongPackage = $package | Select-Object *
    $wrongPackage.PackageFamilyName = 'Microsoft.DesktopAppInstaller_wrongpublisher'
    Assert-NativeTrustRejection { Open-TrustedWinGetCandidate $wingetPath -Package $wrongPackage } 'wrong AppX family' 'wrong package family'

    $otherRoot = Join-Path $workRoot 'OtherMicrosoftProduct'
    New-TrustedDirectory -Path $otherRoot
    $otherMicrosoft = Join-Path $env:SystemRoot 'System32\cmd.exe'
    Assert-TrustedFileSystemPath -Path $otherMicrosoft
    $otherSignature = Get-AuthenticodeSignature -LiteralPath $otherMicrosoft
    Assert-NativeTrust ($otherSignature.Status -eq 'Valid' -and $otherSignature.SignerCertificate.Subject -match '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') 'OS cmd.exe negative fixture is not genuinely Microsoft-signed.'
    $renamedMicrosoft = Join-Path $otherRoot 'winget.exe'
    [IO.File]::Copy($otherMicrosoft, $renamedMicrosoft)
    Assert-NativeTrustRejection { Open-TrustedWinGetCandidate $renamedMicrosoft } 'renamed genuine Microsoft cmd.exe' 'not the actual WinGet CLI product'

    $weakRoot = Join-Path $workRoot 'WeakBoundary'
    New-TrustedDirectory -Path $weakRoot
    [IO.File]::Copy($wingetPath, (Join-Path $weakRoot 'winget.exe'))
    [IO.File]::Copy($manifestPath, (Join-Path $weakRoot 'AppxManifest.xml'))
    $weakAcl = Get-Acl -LiteralPath $weakRoot
    $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $weakRule = New-Object Security.AccessControl.FileSystemAccessRule($users, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $weakAcl.AddAccessRule($weakRule)
    Set-Acl -LiteralPath $weakRoot -AclObject $weakAcl
    $weakPath = Join-Path $weakRoot 'winget.exe'
    Assert-NativeTrustRejection { Open-TrustedWinGetCandidate $weakPath } 'genuine executable behind a user-writable directory'

    $junction = Join-Path $workRoot 'ReparseBoundary'
    New-Item -ItemType Junction -Path $junction -Target $nativeRoot | Out-Null
    $reparsePath = Join-Path $junction 'winget.exe'
    Assert-NativeTrustRejection { Open-TrustedWinGetCandidate $reparsePath } 'reparse directory leading to a genuine executable'

    $lease = Select-TrustedWinGetCandidate -Candidates @($weakPath,$renamedMicrosoft,$reparsePath,@{ Path=$wingetPath; Package=$package }) -NativeArchitecture $NativeArchitecture
    Assert-NativeTrust ($null -ne $lease -and $lease.Path -eq $wingetPath -and $lease.Stream.CanRead) 'Native ranking did not select and hold the only authenticated executable.'
    Write-Output 'PASS WinGetNative selection authenticates all candidates before ranking and returns the genuine held lease'
    $lease.Dispose()
    $lease = $null

    Write-Output 'Native WinGet provenance checks passed without registering, installing or executing a downloaded candidate.'
}
finally {
    if ($null -ne $lease) { $lease.Dispose() }

    [Net.ServicePointManager]::SecurityProtocol = $originalProtocols
    if ($null -ne $junction -and [IO.Directory]::Exists($junction)) {
        # Remove the junction itself first, never recurse through its target.
        [IO.Directory]::Delete($junction, $false)
    }
    # CLR recursive deletion removes reparse points rather than traversing them;
    # avoid Windows PowerShell 5's provider-dependent recursive Remove-Item.
    [IO.Directory]::Delete($workRoot, $true)
}
