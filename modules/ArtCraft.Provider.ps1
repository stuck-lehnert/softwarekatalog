# Privileged, fixed-family MSI provider. Mutating entry points require the caller's
# global installer lock. Dot-sourcing this file does not touch disk or the network.
function Get-ArtCraftDefinition {
    param([Parameter(Mandatory)][string]$PackageId)
    $found = @(Get-ArtCraftDefinitions | Where-Object { $_.PackageId -ieq $PackageId })
    if ($found.Count -ne 1) { throw "Unknown ArtCraft package identity: $PackageId" }
    $found[0]
}

function Assert-ArtCraftSystem {
    if (-not (Test-RunningAsLocalSystem)) { throw 'ArtCraft mutation requires LocalSystem and the caller-held installer lock.' }
}

function Get-ArtCraftRoot {
    if (-not $BaseDir) { throw 'Missing protected service BaseDir.' }
    Join-Path $BaseDir 'ArtCraft'
}

function Assert-ArtCraftNoReparsePoint {
    param([Parameter(Mandatory)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point not allowed in ArtCraft protected path: $current"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }; $current = $parent
    }
}

function Initialize-ArtCraftStorage {
    Assert-ArtCraftSystem
    $root = Get-ArtCraftRoot
    foreach ($path in @($root, (Join-Path $root 'Cache'), (Join-Path $root 'Logs'))) {
        Assert-ArtCraftNoReparsePoint $path
        Ensure-Directory $path
        Set-DirectoryAcl -Path $path -UsersCanModify $false
    }
}

function Test-ArtCraftGuid {
    param([string]$Value)
    $Value -cmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$'
}

function ConvertTo-ArtCraftVersion {
    param([Parameter(Mandatory)][string]$Text)
    if ($Text -cnotmatch '^(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})$') { throw 'Invalid stable ArtCraft version.' }
    $v = [version]$Text
    if ($v.Major -gt 255 -or $v.Minor -gt 255 -or $v.Build -gt 65535) { throw 'Version exceeds MSI limits.' }
    $v
}

function Assert-ArtCraftTarget {
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)]$Target)
    [void](ConvertTo-ArtCraftVersion ([string]$Target.Version))
    if ($Target.Tag -cne ('v' + $Target.Version) -or $Target.Architecture -cnotin @('x64','arm64') -or
        $Target.AssetName -cne ("{0}-{1}-windows-{2}.msi" -f $Definition.Alias,$Target.Version,$Target.Architecture) -or
        $Target.Sha256 -cnotmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid frozen release target.' }
    if ($Target.ProductCode -and -not (Test-ArtCraftGuid $Target.ProductCode)) { throw 'Invalid frozen MSI product identity.' }
}

function Read-ArtCraftState {
    $path = Join-Path (Get-ArtCraftRoot) 'State.json'
    Assert-ArtCraftNoReparsePoint $path
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ SchemaVersion = 1; Records = @() } }
    if ((Get-Item -LiteralPath $path).Length -gt 1048576) { throw 'ArtCraft state exceeds its size limit.' }
    $raw = [IO.File]::ReadAllText($path)
    if (-not $raw.TrimStart().StartsWith('{')) { throw 'ArtCraft state must be an object.' }
    $state = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    if ($state -isnot [pscustomobject] -or $state.SchemaVersion -is [bool] -or $state.SchemaVersion -is [string] -or $state.SchemaVersion -ne 1 -or $null -eq $state.Records -or
        $state.Records -isnot [array] -or $state.Records.Count -gt 14) { throw 'Invalid ArtCraft state schema; refusing to reset ownership.' }
    $seen = @{}
    foreach ($r in $state.Records) {
        $d = Get-ArtCraftDefinition ([string]$r.PackageId)
        if ($seen.ContainsKey($r.PackageId) -or $r.PackageId -cne $d.PackageId -or $r.Alias -cne $d.Alias -or
            $r.Stage -cnotin @('Owned','Prepared','Removing','Installing','Uninstalling') -or
            $r.RebootRequired -isnot [bool] -or $r.Sources -isnot [array]) { throw 'Invalid or duplicate ArtCraft ownership record.' }
        $seen[$r.PackageId] = $true
        if (-not $r.PSObject.Properties['MetadataStale']) { $r | Add-Member NoteProperty MetadataStale $false }
        if ($r.MetadataStale -isnot [bool]) { throw 'Invalid ArtCraft metadata freshness flag.' }
        if ($r.Target) { Assert-ArtCraftTarget $d $r.Target }
        if ($r.Stage -in @('Prepared','Removing','Installing') -and -not $r.Target) { throw 'Recovery intent has no frozen target.' }
        foreach ($source in @($r.Sources)) {
            if (-not (Test-ArtCraftGuid $source.ProductCode) -or $source.Scope -cnotin @('machine','user')) { throw 'Invalid ArtCraft source registration.' }
        }
    }
    $state
}

function Write-ArtCraftState {
    param([Parameter(Mandatory)]$State)
    Assert-ArtCraftSystem
    $path = Join-Path (Get-ArtCraftRoot) 'State.json'
    Assert-ArtCraftNoReparsePoint $path
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($State | ConvertTo-Json -Depth 16))
        $file = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $file.Write($bytes,0,$bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary,$path) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Get-ArtCraftOwnership { (Read-ArtCraftState).Records }

function Test-ArtCraftManagedPackage {
    param([Parameter(Mandatory)][string]$PackageId)
    if (@(Get-ArtCraftDefinitions | Where-Object { $_.PackageId -ieq $PackageId }).Count -ne 1) { return $false }
    if (Test-ArtCraftEnabled) { return $true }
    # A corrupt ownership journal must never route a potentially adopted package
    # back to WinGet. The caller must surface the state error, not bypass it.
    @(Get-ArtCraftOwnership | Where-Object { $_.PackageId -ieq $PackageId }).Count -gt 0
}

function Initialize-ArtCraftNativeMsi {
    if ('Softwarekatalog.ArtCraftMsi' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace Softwarekatalog {
 public static class ArtCraftMsi {
  [DllImport("msi.dll", CharSet=CharSet.Unicode)] static extern uint MsiGetProductInfoEx(string p,string sid,uint c,string n,StringBuilder b,ref uint l);
  [DllImport("msi.dll", CharSet=CharSet.Unicode)] public static extern uint MsiEnumRelatedProducts(string u,uint r,uint i,StringBuilder p);
  [DllImport("msi.dll", CharSet=CharSet.Unicode)] static extern uint MsiOpenDatabase(string p,IntPtr mode,out uint db);
  [DllImport("msi.dll", CharSet=CharSet.Unicode)] static extern uint MsiDatabaseOpenView(uint db,string sql,out uint view);
  [DllImport("msi.dll")] static extern uint MsiViewExecute(uint view,uint record);
  [DllImport("msi.dll")] static extern uint MsiViewFetch(uint view,out uint record);
  [DllImport("msi.dll", CharSet=CharSet.Unicode)] static extern uint MsiRecordGetString(uint record,uint field,StringBuilder value,ref uint length);
  [DllImport("msi.dll", CharSet=CharSet.Unicode)] static extern uint MsiGetSummaryInformation(uint db,string path,uint updates,out uint summary);
  [DllImport("msi.dll", CharSet=CharSet.Unicode)] static extern uint MsiSummaryInfoGetProperty(uint summary,uint property,out uint type,out int integer,out long time,StringBuilder value,ref uint length);
  [DllImport("msi.dll")] static extern uint MsiCloseHandle(uint h);
  public static string LocalPackage(string product,uint context) {
   var b=new StringBuilder(32768); uint n=32768;
   // null SID MUST remain a native null pointer, not PowerShell String.Empty.
   uint rc=MsiGetProductInfoEx(product,null,context,"LocalPackage",b,ref n);
   return rc==0 ? b.ToString() : null;
  }
  public static string Property(string path,string name) {
   uint db=0,view=0,record=0;
   try {
    if(MsiOpenDatabase(path,IntPtr.Zero,out db)!=0) throw new Exception("Cannot open MSI read-only.");
    if(MsiDatabaseOpenView(db,"SELECT `Value` FROM `Property` WHERE `Property` = '"+name+"'",out view)!=0 || MsiViewExecute(view,0)!=0) throw new Exception("Cannot query MSI property.");
    uint rc=MsiViewFetch(view,out record); if(rc==259) return "";
    if(rc!=0) throw new Exception("Cannot fetch MSI property.");
    var b=new StringBuilder(32768); uint n=32768;
    if(MsiRecordGetString(record,1,b,ref n)!=0) throw new Exception("Cannot read MSI property.");
    return b.ToString();
   } finally { if(record!=0)MsiCloseHandle(record); if(view!=0)MsiCloseHandle(view); if(db!=0)MsiCloseHandle(db); }
  }
  public static string Template(string path) {
   uint h=0;
   try {
    if(MsiGetSummaryInformation(0,path,0,out h)!=0) throw new Exception("Cannot open MSI SummaryInformation.");
    uint type,n=32768; int integer; long time; var b=new StringBuilder(32768);
    if(MsiSummaryInfoGetProperty(h,7,out type,out integer,out time,b,ref n)!=0 || type!=30) throw new Exception("Invalid MSI template.");
    return b.ToString();
   } finally { if(h!=0)MsiCloseHandle(h); }
  }
 }
}
'@
}

function Get-ArtCraftMsiMetadata {
    param([Parameter(Mandatory)][string]$Path)
    Initialize-ArtCraftNativeMsi
    $template = [Softwarekatalog.ArtCraftMsi]::Template($Path).Split(';')[0]
    $architecture = switch -CaseSensitive ($template) { 'x64' { 'x64' }; 'Arm64' { 'arm64' }; default { 'unsupported' } }
    [pscustomobject]@{
        ProductCode = [Softwarekatalog.ArtCraftMsi]::Property($Path,'ProductCode')
        UpgradeCode = [Softwarekatalog.ArtCraftMsi]::Property($Path,'UpgradeCode')
        Version = [Softwarekatalog.ArtCraftMsi]::Property($Path,'ProductVersion')
        Architecture = $architecture
    }
}

function Get-ArtCraftRelatedProducts {
    param([Parameter(Mandatory)]$Definition)
    Initialize-ArtCraftNativeMsi
    for ($index = 0; $index -lt 128; $index++) {
        $buffer = New-Object Text.StringBuilder 39
        $code = [Softwarekatalog.ArtCraftMsi]::MsiEnumRelatedProducts($Definition.UpgradeCode,0,$index,$buffer)
        if ($code -eq 259) { return }
        if ($code -ne 0) { throw "MSI family enumeration failed: $code" }
        $buffer.ToString()
    }
    throw 'MSI family registration count exceeds limit.'
}

function Get-ArtCraftRegistrationMetadata {
    param([Parameter(Mandatory)]$Registration)
    Initialize-ArtCraftNativeMsi
    $contexts = if ($Registration.Scope -eq 'machine') { @(4) } else { @(2,1) }
    foreach ($context in $contexts) {
        $path = [Softwarekatalog.ArtCraftMsi]::LocalPackage($Registration.ProductCode,$context)
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return Get-ArtCraftMsiMetadata $path }
    }
    throw 'Registered MSI has no readable cached metadata in its scope.'
}

function Test-ArtCraftMachinePath {
    param([string]$Path)
    if (-not $Path -or $Path -match '["\r\n]' -or -not [IO.Path]::IsPathRooted($Path)) { return $false }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    foreach ($root in @($env:ProgramW6432,$env:ProgramFiles,${env:ProgramFiles(x86)}) | Select-Object -Unique) {
        if ($root -and $full.StartsWith(([IO.Path]::GetFullPath($root).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)) {
            Assert-ArtCraftNoReparsePoint $Path
            return $true
        }
    }
    $false
}

function Get-ArtCraftInventory {
    $registrations = @(Get-RegisteredApplications -IncludeUnnamed)
    $native = Get-NativeWindowsArchitecture
    foreach ($d in @(Get-ArtCraftDefinitions)) {
        $related = @(Get-ArtCraftRelatedProducts $d)
        $candidates = @($registrations | Where-Object {
            (Test-ArtCraftGuid $_.ProductCode) -and $_.WindowsInstaller -and
            ($_.ProductCode -in $related -or $_.DisplayName -match ('^' + [regex]::Escape($d.DisplayName) + '(?:\s+[0-9].*)?$'))
        })
        $seen = @{}
        foreach ($r in $candidates) {
            $key = $r.ProductCode + ':' + $r.Scope
            if ($seen.ContainsKey($key)) { continue }; $seen[$key] = $true
            $metadata = Get-ArtCraftRegistrationMetadata $r
            if ($metadata.UpgradeCode -ne $d.UpgradeCode -or $metadata.ProductCode -ne $r.ProductCode) { continue }
            [void](ConvertTo-ArtCraftVersion $metadata.Version)
            $ambiguous = -not (Test-MsiClassicLookupSafe -Registration $r -Registrations $registrations)
            $location = [string]$r.InstallLocation
            $exeName = ($d.ExecutableRelativePath -split '\\')[-1]
            $executable = if ($location) { Join-Path $location $exeName } else { '' }
            if (-not $executable -or -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
                # Expensive Component evidence is read only after family identity
                # is proven, and only when ARP does not provide an executable.
                $evidence = Get-MsiRegistrationEvidence -Registration $r
                if ($evidence) {
                    $paths = @($evidence.ExecutablePaths | Where-Object { [IO.Path]::GetFileName($_) -ieq $exeName } | Select-Object -Unique)
                    if ($evidence.UpgradeCode -eq $d.UpgradeCode -and $paths.Count -eq 1) {
                        $executable = $paths[0]; $location = [IO.Path]::GetDirectoryName($executable)
                    }
                }
            }
            $systemAppData = Test-SystemProfileAppDataPath -Path $location
            $safePath = Test-ArtCraftMachinePath $location
            [pscustomobject]@{
                PackageId = $d.PackageId; Alias = $d.Alias; Version = $metadata.Version; Architecture = $metadata.Architecture
                Scope = $r.Scope; ProductCode = $r.ProductCode; InstallLocation = $location; ExecutablePath = $executable
                Healthy = (-not $ambiguous -and $r.Scope -eq 'machine' -and $metadata.Architecture -eq $native -and
                    $safePath -and (Test-Path -LiteralPath $executable -PathType Leaf))
                Ambiguous = $ambiguous; SystemAppData = $systemAppData
            }
        }
        # Related products lacking an ARP scope are identity evidence, NOT safe
        # uninstall targets. Surface the conflict instead of guessing context.
        foreach ($product in $related) {
            if (@($candidates | Where-Object { $_.ProductCode -eq $product }).Count -eq 0) {
                [pscustomobject]@{ PackageId=$d.PackageId; Alias=$d.Alias; ProductCode=$product; Version=''; Architecture='unknown';
                    Scope='unknown'; InstallLocation=''; ExecutablePath=''; Healthy=$false; Ambiguous=$true; SystemAppData=$false }
            }
        }
    }
}

function Assert-ArtCraftHttpUri {
    param([Parameter(Mandatory)][uri]$Uri, [Parameter(Mandatory)]$Definition, [string]$Tag, [string]$AssetName, [switch]$Latest)
    if ($Uri.Scheme -cne 'https' -or -not $Uri.IsDefaultPort -or $Uri.UserInfo -or $Uri.Fragment) { throw 'Unsafe ArtCraft HTTPS URL.' }
    if ($Latest) {
        $prefix = '/' + $Definition.Repository + '/releases/'
        if ($Uri.Host -cne 'github.com' -or $Uri.Query -or
            ($Uri.AbsolutePath -cne ($prefix+'latest') -and $Uri.AbsolutePath -cnotmatch ('^'+[regex]::Escape($prefix)+'tag/v[0-9]+\.[0-9]+\.[0-9]+$'))) { throw 'Latest redirect left the fixed repository.' }
    }
    elseif ($Uri.Host -ceq 'github.com') {
        $expected = '/' + $Definition.Repository + '/releases/download/' + $Tag + '/' + $AssetName
        if ($Uri.AbsolutePath -cne $expected -or $Uri.Query) { throw 'Asset redirect changed the frozen release.' }
    }
    elseif ($Uri.Host -cnotin @('release-assets.githubusercontent.com','objects.githubusercontent.com')) { throw 'Asset redirect host is not allowed.' }
}

function Invoke-ArtCraftHttp {
    param([Parameter(Mandatory)][uri]$Uri, [Parameter(Mandatory)]$Definition, [string]$Tag, [string]$AssetName,
        [switch]$Latest, [string]$Destination, [long]$MaxBytes = 1048576)
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object Net.Http.HttpClient($handler)
    $client.Timeout = [timespan]::FromSeconds(300)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('Softwarekatalog-ArtCraft/1.0')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $cancellation = New-Object Threading.CancellationTokenSource 300000
    try {
        for ($redirect = 0; $redirect -le 5; $redirect++) {
            Assert-ArtCraftHttpUri -Uri $Uri -Definition $Definition -Tag $Tag -AssetName $AssetName -Latest:$Latest
            $method = if ($Latest) { [Net.Http.HttpMethod]::Head } else { [Net.Http.HttpMethod]::Get }
            $request = New-Object Net.Http.HttpRequestMessage($method,$Uri)
            $response = $null
            try {
                try { $response = Send-ArtCraftHttpRequest -Client $client -Request $request -CancellationToken $cancellation.Token }
                catch { throw (New-ArtCraftNetworkException ('ArtCraft HTTP transport unavailable: '+$_.Exception.Message)) }
                $status = [int]$response.StatusCode
                if ($status -in @(301,302,303,307,308)) {
                    if ($redirect -eq 5 -or -not $response.Headers.Location) { throw 'ArtCraft redirect limit/missing Location.' }
                    $Uri = New-Object uri($Uri,$response.Headers.Location)
                    continue
                }
                if ($status -in @(403,408,429) -or $status -ge 500) { throw (New-ArtCraftNetworkException "ArtCraft HTTP failure: $status (last metadata retained).") }
                if ($status -ne 200) { throw "ArtCraft HTTP failure: $status (last metadata retained)." }
                if ($Latest) { return [pscustomobject]@{ Uri = $Uri; Text = $null } }
                if ($response.Content.Headers.ContentLength -gt $MaxBytes) { throw 'ArtCraft download exceeds size limit.' }
                $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $output = if ($Destination) { [IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None) } else { New-Object IO.MemoryStream }
                try {
                    $buffer = New-Object byte[] 65536; $total = [long]0
                    while ($true) {
                        $readTask = $stream.ReadAsync($buffer,0,$buffer.Length,$cancellation.Token)
                        if (-not $readTask.Wait(30000)) { throw 'ArtCraft read timed out.' }
                        $read = $readTask.GetAwaiter().GetResult()
                        if ($read -eq 0) { break }
                        $total += $read
                        if ($total -gt $MaxBytes -or $watch.Elapsed.TotalSeconds -gt 300) { throw 'ArtCraft transfer exceeded size/time budget.' }
                        $output.Write($buffer,0,$read)
                    }
                    if ($Destination) { $output.Flush($true); return [pscustomobject]@{ Uri=$Uri; Text=$null } }
                    return [pscustomobject]@{ Uri=$Uri; Text=[Text.Encoding]::UTF8.GetString($output.ToArray()) }
                }
                finally { $output.Dispose(); $stream.Dispose() }
            }
            finally { if ($response) { $response.Dispose() }; $request.Dispose() }
        }
    }
    finally { $cancellation.Dispose(); $client.Dispose(); $handler.Dispose() }
}

function Send-ArtCraftHttpRequest {
    param([Parameter(Mandatory)]$Client,[Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][Threading.CancellationToken]$CancellationToken)
    $Client.SendAsync($Request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$CancellationToken).GetAwaiter().GetResult()
}

function New-ArtCraftNetworkException {
    param([Parameter(Mandatory)][string]$Message)
    $exception = New-Object InvalidOperationException($Message)
    $exception.Data['ArtCraftNetworkFailure']=$true
    $exception
}

function Get-ArtCraftChecksum {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$AssetName)
    $digests = @()
    foreach ($line in ($Text -split '\r?\n')) {
        if (-not $line.Trim()) { continue }
        if ($line -cnotmatch '^([0-9a-fA-F]{64}) [ *]([^\r\n]+)$') { throw 'Malformed release checksum row.' }
        if ($Matches[2] -ceq $AssetName) { $digests += $Matches[1].ToLowerInvariant() }
    }
    if ($digests.Count -ne 1) { throw 'Missing or duplicate native MSI checksum entry.' }
    $digests[0]
}

function Resolve-ArtCraftRelease {
    param([Parameter(Mandatory)]$Definition)
    $arch = Get-NativeWindowsArchitecture
    if ($arch -cnotin @('x64','arm64')) { throw 'No native ArtCraft MSI for this OS architecture.' }
    $response = Invoke-ArtCraftHttp -Uri ('https://github.com/'+$Definition.Repository+'/releases/latest') -Definition $Definition -Latest
    $prefix = 'https://github.com/' + $Definition.Repository + '/releases/tag/'
    if (-not $response.Uri.AbsoluteUri.StartsWith($prefix,[StringComparison]::Ordinal)) { throw 'Latest did not resolve to a stable release tag.' }
    $tag = $response.Uri.AbsoluteUri.Substring($prefix.Length)
    if ($tag -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Draft/prerelease/malformed release tag is forbidden.' }
    $version = $tag.Substring(1); [void](ConvertTo-ArtCraftVersion $version)
    $asset = '{0}-{1}-windows-{2}.msi' -f $Definition.Alias,$version,$arch
    $checksums = Invoke-ArtCraftHttp -Uri ('https://github.com/'+$Definition.Repository+'/releases/download/'+$tag+'/SHA256SUMS.txt') -Definition $Definition -Tag $tag -AssetName 'SHA256SUMS.txt' -MaxBytes 1048576
    [pscustomobject]@{ Tag=$tag; Version=$version; Architecture=$arch; AssetName=$asset;
        Sha256=(Get-ArtCraftChecksum $checksums.Text $asset); ProductCode='' }
}

function Get-ArtCraftTargetPath {
    param([Parameter(Mandatory)]$Definition,[Parameter(Mandatory)]$Target)
    Assert-ArtCraftTarget $Definition $Target
    $path = Join-Path (Join-Path (Get-ArtCraftRoot) 'Cache') ($Target.Sha256.ToLowerInvariant() + '-' + $Target.AssetName)
    Assert-ArtCraftNoReparsePoint $path
    $path
}

function Assert-ArtCraftInstaller {
    param([Parameter(Mandatory)]$Definition,[Parameter(Mandatory)]$Target,[Parameter(Mandatory)][string]$Path)
    Assert-ArtCraftTarget $Definition $Target
    Assert-ArtCraftNoReparsePoint $Path
    if ((Get-Item -LiteralPath $Path).Length -gt 2147483648) { throw 'Cached ArtCraft MSI exceeds limit.' }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Target.Sha256) { throw 'ArtCraft MSI SHA256 mismatch.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$signature.Status -cne 'Valid' -or -not $signature.SignerCertificate) { throw 'ArtCraft Authenticode signature is not Valid.' }
    $approved = $false
    $flags = [Security.Cryptography.X509Certificates.X500DistinguishedNameFlags]::UseCommas
    $actualDn = $signature.SignerCertificate.SubjectName.Decode($flags)
    foreach ($subject in @(Get-ArtCraftAllowedSignerSubjects)) {
        $dn = New-Object Security.Cryptography.X509Certificates.X500DistinguishedName($subject)
        # Identical full X500 decoder/flags on BOTH sides permits equivalent
        # PrintableString/UTF8String encodings without dropping any RDN/value.
        if ($actualDn -ceq $dn.Decode($flags)) { $approved = $true }
    }
    if (-not $approved) { throw 'ArtCraft signer full distinguished name is not approved.' }
    $msi = Get-ArtCraftMsiMetadata $Path
    if ($msi.UpgradeCode -ine $Definition.UpgradeCode -or $msi.Version -cne $Target.Version -or
        $msi.Architecture -cne $Target.Architecture -or -not (Test-ArtCraftGuid $msi.ProductCode) -or
        ($Target.ProductCode -and $Target.ProductCode -ine $msi.ProductCode)) { throw 'ArtCraft MSI family/version/architecture identity mismatch.' }
    $msi
}

function Save-ArtCraftInstaller {
    param([Parameter(Mandatory)]$Definition,[Parameter(Mandatory)]$Target)
    $path = Get-ArtCraftTargetPath $Definition $Target
    if (Test-Path -LiteralPath $path) { $metadata = Assert-ArtCraftInstaller $Definition $Target $path }
    else {
        $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.partial'
        try {
            $null = Invoke-ArtCraftHttp -Uri ('https://github.com/'+$Definition.Repository+'/releases/download/'+$Target.Tag+'/'+$Target.AssetName) -Definition $Definition -Tag $Target.Tag -AssetName $Target.AssetName -Destination $temporary -MaxBytes 2147483648
            $metadata = Assert-ArtCraftInstaller $Definition $Target $temporary
            [IO.File]::Move($temporary,$path)
        }
        finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    }
    $Target.ProductCode = $metadata.ProductCode
    $path
}

function New-ArtCraftRecord {
    param([Parameter(Mandatory)]$Definition)
    [pscustomobject]@{ PackageId=$Definition.PackageId; Alias=$Definition.Alias; Stage='Owned'; Target=$null; Sources=@();
        InstallLocation=''; Version=''; Architecture=''; LastCheckedUtc=$null; LatestVersion=$null; LastError=$null; MetadataStale=$false; RebootRequired=$false }
}

function Set-ArtCraftRecord {
    param([Parameter(Mandatory)]$Record)
    $state = Read-ArtCraftState
    $state.Records = @($state.Records | Where-Object { $_.PackageId -cne $Record.PackageId }) + @($Record)
    Write-ArtCraftState $state
}

function Invoke-ArtCraftMsi {
    param([Parameter(Mandatory)][string]$Arguments)
    Assert-ArtCraftSystem
    $exe = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    if ([IntPtr]::Size -eq 4 -and (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'Sysnative\msiexec.exe'))) { $exe = Join-Path $env:SystemRoot 'Sysnative\msiexec.exe' }
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $process = Start-Process -FilePath $exe -ArgumentList $Arguments -PassThru
        try {
            # Retain the native process handle immediately. Windows PowerShell
            # 5.1 can otherwise lose ExitCode for a very short-lived process.
            $handle = $process.Handle
            if (-not $process.WaitForExit(3600000)) { throw 'MSI timed out; journal retained. Do not start a competing installation.' }
            $code = $process.ExitCode
            if ($null -eq $code) { throw 'MSI process exit code is unavailable; refusing to assume success.' }
        } finally { $process.Dispose() }
        if ($code -ne 1618 -or $attempt -eq 2) { return [int]$code }
        Start-Sleep -Seconds (10 * ($attempt+1))
    }
}

function Get-ArtCraftLogPath {
    param([Parameter(Mandatory)]$Definition,[Parameter(Mandatory)][string]$Operation)
    $path = Join-Path (Join-Path (Get-ArtCraftRoot) 'Logs') ($Definition.Alias+'-'+$Operation+'-'+[guid]::NewGuid().ToString('N')+'.log')
    Assert-ArtCraftNoReparsePoint $path
    $path
}

function Assert-ArtCraftMsiCode {
    param([int]$Code)
    if ($Code -eq 1641) { throw 'MSI unexpectedly initiated a reboot (1641); journal retained.' }
    if ($Code -notin @(0,3010)) { throw "ArtCraft MSI failed: $Code" }
}

function Invoke-ArtCraftRecord {
    param([Parameter(Mandatory)]$Record)
    $d = Get-ArtCraftDefinition $Record.PackageId
    if ($Record.Stage -eq 'Owned') { return 0 }
    $uninstall = $Record.Stage -eq 'Uninstalling'
    $path = $null
    if (-not $uninstall) {
        # Reverify the exact frozen target even on recovery and before EVERY
        # removal. A changed cache/signature never destroys an old installation.
        $path = Save-ArtCraftInstaller $d $Record.Target
        if ($Record.Target.Architecture -cne (Get-NativeWindowsArchitecture)) { throw 'Recovery target is not native to this OS.' }
        if (-not (Test-ArtCraftMachinePath $Record.InstallLocation)) { throw 'Unsafe recovery destination; removal blocked.' }
        $before = @(Get-ArtCraftInventory | Where-Object { $_.PackageId -ceq $d.PackageId })
        if ($before.Count -gt 1) { throw 'Multiple family registrations block recovery before removal.' }
        foreach ($current in $before) {
            if ($current.Ambiguous -or (ConvertTo-ArtCraftVersion $current.Version) -gt (ConvertTo-ArtCraftVersion $Record.Target.Version)) {
                throw 'Ambiguous/newer installed version blocks recovery before removal.'
            }
        }
        if ($Record.Stage -in @('Removing','Installing')) {
            Write-Log ("ArtCraft {0}: resuming durable stage={1}, verified target version={2}, architecture={3}." -f $d.PackageId,$Record.Stage,$Record.Target.Version,$Record.Target.Architecture) 'INFO'
        }
    }
    if ($Record.Stage -in @('Prepared','Removing','Uninstalling')) {
        if (-not $uninstall) { $Record.Stage='Removing'; Set-ArtCraftRecord $Record }
        foreach ($source in @($Record.Sources)) {
            $inventory = @(Get-ArtCraftInventory | Where-Object { $_.PackageId -ceq $d.PackageId })
            $present = @($inventory | Where-Object { $_.ProductCode -eq $source.ProductCode })
            if ($present.Count -eq 0) { continue }
            if ($present.Count -ne 1 -or $present[0].Ambiguous -or $present[0].Scope -cne $source.Scope) { throw 'Source registration context changed/ambiguous; removal blocked.' }
            $log = Get-ArtCraftLogPath $d 'remove'
            $scopeArguments = if ($source.Scope -eq 'machine') { ' ALLUSERS=1' } else { '' }
            Write-Log ("ArtCraft {0}: removing registered MSI product={1}, scope={2}." -f $d.PackageId,$source.ProductCode,$source.Scope) 'INFO'
            $code = Invoke-ArtCraftMsi ('/x '+$source.ProductCode+$scopeArguments+' /qn /norestart /L*v "'+$log+'"')
            Assert-ArtCraftMsiCode $code
            if ($code -eq 3010) { $Record.RebootRequired=$true; Set-ArtCraftRecord $Record }
            if (@(Get-ArtCraftInventory | Where-Object { $_.PackageId -ceq $d.PackageId -and $_.ProductCode -eq $source.ProductCode }).Count -ne 0) { throw 'MSI removal did not remove the registered source.' }
            Write-Log ("ArtCraft {0}: removal verified for product={1}, scope={2}, rebootRequired={3}." -f $d.PackageId,$source.ProductCode,$source.Scope,$Record.RebootRequired) 'INFO'
        }
        if ($uninstall) {
            if (@(Get-ArtCraftInventory | Where-Object { $_.PackageId -ceq $d.PackageId }).Count -ne 0) { throw 'ArtCraft uninstall left a registration.' }
            # Keep ownership after removal: disabled policy must not hand this
            # logical identity back to an unrelated automatic WinGet operation.
            $Record.Stage='Owned'; $Record.Sources=@(); $Record.Version=''; $Record.Architecture=''; $Record.InstallLocation=''; $Record.Target=$null
            Set-ArtCraftRecord $Record
            if ($Record.RebootRequired) { return 3010 }; return 0
        }
        $Record.Stage='Installing'; Set-ArtCraftRecord $Record
    }
    $inventory = @(Get-ArtCraftInventory | Where-Object { $_.PackageId -ceq $d.PackageId })
    $correct = @($inventory | Where-Object { $_.Healthy -and $_.Version -ceq $Record.Target.Version -and $_.Architecture -ceq $Record.Target.Architecture -and $_.ProductCode -eq $Record.Target.ProductCode })
    if ($correct.Count -ne 1 -or $inventory.Count -ne 1) {
        foreach ($current in $inventory) {
            if ($current.Ambiguous -or (ConvertTo-ArtCraftVersion $current.Version) -gt (ConvertTo-ArtCraftVersion $Record.Target.Version)) { throw 'Ambiguous/newer installed version blocks recovery downgrade.' }
        }
        if (-not (Test-ArtCraftMachinePath $Record.InstallLocation)) { throw 'Unsafe destination machine install path.' }
        $log = Get-ArtCraftLogPath $d 'install'
        $arguments = '/i "'+$path+'" ALLUSERS=1 MSIINSTALLPERUSER="" INSTALLFOLDER="'+$Record.InstallLocation+'" /qn /norestart /L*v "'+$log+'"'
        $code = Invoke-ArtCraftMsi $arguments
        Assert-ArtCraftMsiCode $code
        if ($code -eq 3010) { $Record.RebootRequired=$true; Set-ArtCraftRecord $Record }
        $inventory = @(Get-ArtCraftInventory | Where-Object { $_.PackageId -ceq $d.PackageId })
        if ($inventory.Count -ne 1 -or -not $inventory[0].Healthy -or $inventory[0].Version -cne $Record.Target.Version -or
            $inventory[0].Architecture -cne $Record.Target.Architecture -or $inventory[0].ProductCode -ine $Record.Target.ProductCode) { throw 'ArtCraft post-install machine registration/version/native executable verification failed.' }
    }
    $Record.Stage='Owned'; $Record.Sources=@(); $Record.Version=$Record.Target.Version; $Record.Architecture=$Record.Target.Architecture
    $Record.InstallLocation=$inventory[0].InstallLocation
    if (-not $Record.MetadataStale) { $Record.LastError=$null }
    Set-ArtCraftRecord $Record
    Write-Log ("ArtCraft {0}: verified healthy machine installation version={1}, architecture={2}, product={3}, path='{4}', rebootRequired={5}." -f $d.PackageId,$Record.Version,$Record.Architecture,$Record.Target.ProductCode,$Record.InstallLocation,$Record.RebootRequired) 'INFO'
    if ($Record.RebootRequired) { return 3010 }; 0
}

function Set-ArtCraftFailure {
    param([string]$PackageId,[string]$Message)
    Write-Log ("ArtCraft {0}: {1}" -f $PackageId,$Message) 'ERROR'
    # Never turn unreadable state into empty ownership to record an error.
    try {
        $record = @(Get-ArtCraftOwnership | Where-Object { $_.PackageId -ceq $PackageId })
        if ($record.Count -eq 1) { $record[0].LastError=$Message; Set-ArtCraftRecord $record[0] }
    } catch { Write-Log ("ArtCraft diagnostic state could not be written: "+$_.Exception.Message) 'ERROR' }
}

function Invoke-ArtCraftInstall {
    param([Parameter(Mandatory)][string]$PackageId,[string]$QueueItemId)
    try {
        Assert-ArtCraftSystem; Initialize-ArtCraftStorage
        $d = Get-ArtCraftDefinition $PackageId
        $PackageId = $d.PackageId
        $existing = @(Get-ArtCraftOwnership | Where-Object { $_.PackageId -ceq $PackageId })
        if ($existing.Count -eq 1 -and $existing[0].Stage -ne 'Owned') {
            # Once destruction began it must finish even if the checkbox changed.
            if ($existing[0].Stage -eq 'Prepared' -and -not (Test-ArtCraftEnabled)) { throw 'ArtCraft disabled before destructive migration began.' }
            return Invoke-ArtCraftRecord $existing[0]
        }
        if (-not (Test-ArtCraftEnabled)) { throw 'ArtCraft offering/installation is disabled.' }
        $inventory = @(Get-ArtCraftInventory | Where-Object { $_.PackageId -ceq $PackageId })
        if ($inventory.Count -gt 1 -or @($inventory | Where-Object { $_.Ambiguous -or $_.Scope -cnotin @('machine','user') }).Count) { throw 'Ambiguous ArtCraft installation; no mutation allowed.' }
        $record = if ($existing.Count) { $existing[0] } else { New-ArtCraftRecord $d }
        if ($inventory.Count -eq 1 -and $inventory[0].Healthy) {
            $record.Version=$inventory[0].Version; $record.Architecture=$inventory[0].Architecture; $record.InstallLocation=$inventory[0].InstallLocation
            Set-ArtCraftRecord $record # Offline adoption precedes network checks.
            if ($existing.Count -eq 0) {
                Write-Log ("ArtCraft {0}: adopted healthy machine MSI version={1}, architecture={2}, path='{3}' without reinstall." -f $d.PackageId,$record.Version,$record.Architecture,$record.InstallLocation) 'INFO'
            }
        }
        try {
            $target = Resolve-ArtCraftRelease $d
            $record.LastCheckedUtc=[datetime]::UtcNow.ToString('o'); $record.LatestVersion=$target.Version; $record.LastError=$null; $record.MetadataStale=$false
        }
        catch {
            # Only transport/rate-limit failures qualify. A changed tag, absent
            # native asset, bad checksum or other identity error is NOT offline.
            if ($_.Exception.Data['ArtCraftNetworkFailure']) {
                Write-Log ("ArtCraft {0}: release metadata unavailable/offline; last successful check retained. A frozen cache is usable only after full verification." -f $d.PackageId) 'WARN'
            }
            if (-not $_.Exception.Data['ArtCraftNetworkFailure'] -or -not $record.Target) { throw }
            $record.LastError=$_.Exception.Message; $record.MetadataStale=$true
            $target=$record.Target
            if ($target.Architecture -cne (Get-NativeWindowsArchitecture)) { throw 'Cached target has no native architecture; emulation fallback forbidden.' }
            $cached=Get-ArtCraftTargetPath $d $target
            if (-not (Test-Path -LiteralPath $cached -PathType Leaf)) { throw 'Offline cached target is missing; no installation may be removed.' }
            $null=Save-ArtCraftInstaller $d $target # hash + current trust + MSI identity, not just a prior flag
            Set-ArtCraftRecord $record # Keep last successful check time, visibly stale.
        }
        foreach ($current in $inventory) {
            if ((ConvertTo-ArtCraftVersion $current.Version) -gt (ConvertTo-ArtCraftVersion $target.Version)) {
                if (-not $current.Healthy) { throw 'Native migration would downgrade the existing version.' }
                Set-ArtCraftRecord $record; return 0
            }
            if ($current.Healthy -and $current.Version -ceq $target.Version) { Set-ArtCraftRecord $record; return 0 }
            if (-not $current.Healthy -and -not $current.SystemAppData -and $current.Architecture -ceq $target.Architecture) { throw 'Unhealthy/non-SYSTEM user installation has no approved migration profile.' }
            if ($current.Scope -eq 'user' -and -not $current.SystemAppData) { throw 'Only proven SYSTEM-AppData per-user migration is permitted.' }
        }
        $null = Save-ArtCraftInstaller $d $target
        Write-Log ("ArtCraft {0}: verified native target version={1}, architecture={2}, product={3}." -f $d.PackageId,$target.Version,$target.Architecture,$target.ProductCode) 'INFO'
        $record.Target=$target
        $record.InstallLocation = if ($inventory.Count -eq 1 -and $inventory[0].Healthy) { $inventory[0].InstallLocation } else {
            $root = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
            if (-not $root) { throw 'Missing native Program Files root.' }
            Join-Path $root (($d.ExecutableRelativePath -split '\\' | Select-Object -SkipLast 1) -join [IO.Path]::DirectorySeparatorChar)
        }
        $record.Sources = @($inventory | Where-Object { -not $_.Healthy } | ForEach-Object { [pscustomobject]@{ ProductCode=$_.ProductCode; Scope=$_.Scope } })
        # Healthy older machine installs use the normal major upgrade, not /x.
        $record.Stage='Prepared'; Set-ArtCraftRecord $record
        $intent = if ($record.Sources.Count) { 'migration' } else { 'machine-install/update' }
        Write-Log ("ArtCraft {0}: durable {1} intent saved before mutation; target version={2}, architecture={3}, removalSources={4}, path='{5}'." -f $d.PackageId,$intent,$target.Version,$target.Architecture,$record.Sources.Count,$record.InstallLocation) 'INFO'
        Invoke-ArtCraftRecord $record
    }
    catch { Set-ArtCraftFailure $PackageId $_.Exception.Message; if ($_.Exception.Message -match '\b1618\b') { return 1618 }; 1 }
}

function Invoke-ArtCraftUninstall {
    param([Parameter(Mandatory)][string]$PackageId,[string]$QueueItemId)
    try {
        Assert-ArtCraftSystem; Initialize-ArtCraftStorage
        $d = Get-ArtCraftDefinition $PackageId
        $PackageId = $d.PackageId
        if (-not (Test-ArtCraftManagedPackage $PackageId)) { throw 'Package is not ArtCraft-managed.' }
        $records = @(Get-ArtCraftOwnership | Where-Object { $_.PackageId -ceq $PackageId })
        if ($records.Count -eq 1 -and $records[0].Stage -notin @('Owned','Uninstalling')) { throw 'Complete pending installation recovery before uninstall.' }
        if ($records.Count -eq 1 -and $records[0].Stage -eq 'Uninstalling') { return Invoke-ArtCraftRecord $records[0] }
        $inventory = @(Get-ArtCraftInventory | Where-Object { $_.PackageId -ceq $PackageId })
        if (@($inventory | Where-Object { $_.Ambiguous -or $_.Scope -cnotin @('machine','user') -or ($_.Scope -eq 'user' -and -not $_.SystemAppData) }).Count) { throw 'Ambiguous or unapproved user registration; uninstall blocked.' }
        $record = if ($records.Count) { $records[0] } else { New-ArtCraftRecord $d }
        $record.Sources=@($inventory | ForEach-Object { [pscustomobject]@{ ProductCode=$_.ProductCode; Scope=$_.Scope } })
        $record.Stage='Uninstalling'; Set-ArtCraftRecord $record
        Invoke-ArtCraftRecord $record
    }
    catch { Set-ArtCraftFailure $PackageId $_.Exception.Message; if ($_.Exception.Message -match '\b1618\b') { return 1618 }; 1 }
}

function Initialize-ArtCraftProvider {
    try {
        Assert-ArtCraftSystem; Initialize-ArtCraftStorage
        $result = 0
        foreach ($record in @(Get-ArtCraftOwnership)) {
            if ($record.Stage -in @('Removing','Installing','Uninstalling') -or ($record.Stage -eq 'Prepared' -and (Test-ArtCraftEnabled))) {
                try { $code = Invoke-ArtCraftRecord $record; if ($code -eq 3010 -and $result -eq 0) { $result=3010 } }
                catch { Set-ArtCraftFailure $record.PackageId $_.Exception.Message; $result=1 }
            }
        }
        if (-not (Test-ArtCraftEnabled)) { return $result }
        $owned = @(Get-ArtCraftOwnership)
        foreach ($group in @(Get-ArtCraftInventory | Group-Object PackageId)) {
            if (@($owned | Where-Object { $_.PackageId -ceq $group.Name }).Count) { continue }
            if ($group.Count -eq 1 -and $group.Group[0].Healthy) {
                $installed=$group.Group[0]; $record=New-ArtCraftRecord (Get-ArtCraftDefinition $group.Name)
                $record.Version=$installed.Version; $record.Architecture=$installed.Architecture; $record.InstallLocation=$installed.InstallLocation
                Set-ArtCraftRecord $record
                Write-Log ("ArtCraft {0}: adopted healthy machine MSI version={1}, architecture={2}, path='{3}' without reinstall." -f $record.PackageId,$record.Version,$record.Architecture,$record.InstallLocation) 'INFO'
            }
            else {
                $code=Invoke-ArtCraftInstall -PackageId $group.Name
                if ($code -notin @(0,3010)) { $result=$code }
                elseif ($code -eq 3010 -and $result -eq 0) { $result=3010 }
            }
        }
        $result
    }
    catch { Write-Log ('ArtCraft initialization failed: '+$_.Exception.Message) 'ERROR'; 1 }
}

function Invoke-ArtCraftUpdates {
    try {
        Assert-ArtCraftSystem
        $result = Initialize-ArtCraftProvider
        if (-not (Test-ArtCraftEnabled)) { return $result }
        # Only real installed families are eligible, never all fourteen offers.
        foreach ($id in @(Get-ArtCraftInventory | Select-Object -ExpandProperty PackageId -Unique)) {
            $record = @(Get-ArtCraftOwnership | Where-Object { $_.PackageId -ceq $id })
            if ($record.Count -eq 1 -and $record[0].Stage -eq 'Owned' -and $record[0].LastCheckedUtc) {
                $lastChecked = $record[0].LastCheckedUtc
                # PS7 JSON may already contain a UTC DateTime. Parse(DateTime)
                # first stringifies it without its Kind/offset, shifting the
                # instant by the machine's timezone and delaying update checks.
                $checked = if ($lastChecked -is [datetime]) { $lastChecked.ToUniversalTime() }
                elseif ($lastChecked -is [datetimeoffset]) { $lastChecked.UtcDateTime }
                else { [datetime]::Parse([string]$lastChecked,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
                # Persisted success timestamp plus stable per-client jitter avoids
                # fourteen REST requests and synchronized fleet polling.
                $jitter = 0
                foreach ($character in (($env:COMPUTERNAME+$id).ToCharArray())) { $jitter=($jitter*31+[int]$character) % 997 }
                if (([datetime]::UtcNow-$checked).TotalMinutes -lt (120+($jitter % 21))) { continue }
            }
            $code=Invoke-ArtCraftInstall -PackageId $id
            if ($code -notin @(0,3010)) { $result=$code }
            elseif ($code -eq 3010 -and $result -eq 0) { $result=3010 }
        }
        $result
    }
    catch { Write-Log ('ArtCraft update pass failed: '+$_.Exception.Message) 'ERROR'; 1 }
}
