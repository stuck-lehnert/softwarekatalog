[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$WixPath,
    [Parameter(Mandatory)][ValidateSet('x64','arm64')][string]$Architecture
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop') { throw 'Build fixtures with Windows PowerShell 5.1.' }
$null = New-Item -ItemType Directory -Path $Root -Force
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'helpers/WindowsArchitecture.ps1')
$null = Assert-CiWindowsArchitecture -ExpectedArchitecture $Architecture -ExpectedOSArchitecture $Architecture `
    -RequireNative -OutputPath (Join-Path $Root 'fixture-builder-architecture.json')
$suffix = [Guid]::NewGuid().ToString('N')
$productCode = '{' + [Guid]::NewGuid().ToString().ToUpperInvariant() + '}'
$upgradeCode = '{' + [Guid]::NewGuid().ToString().ToUpperInvariant() + '}'
$machineDir = Join-Path $env:ProgramFiles "SoftwarekatalogCiFixture-$suffix"
$config = [ordered]@{
    Root = $Root; ProductCode = $productCode; UpgradeCode = $upgradeCode; Architecture = $Architecture
    PackageId = 'Softwarekatalog.CiFixture'; Name = 'Softwarekatalog CI Fixture'
    MachineDir = $machineDir; Msi = Join-Path $Root 'fixture.msi'
    LegacyDir = Join-Path $env:SystemRoot "System32\config\systemprofile\AppData\Local\Programs\SoftwarekatalogCiFixture-$suffix"
}
$config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'fixture-config.json') -Encoding UTF8
# AnyCPU deliberately uses the native .NET Framework CLR on both x64 and ARM64.
# The executable itself verifies IsWow64Process2: a successful x64-emulated
# launch on ARM64 cannot masquerade as a native ARM64 application test.
$nativeMachine = if ($Architecture -eq 'arm64') { 0xaa64 } else { 0x8664 }
$payloadSource = @"
using System;
using System.Runtime.InteropServices;
public static class ProbePayload {
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
    public static int Main(string[] args) {
        ushort processMachine, nativeMachine;
        if (!IsWow64Process2(GetCurrentProcess(), out processMachine, out nativeMachine)) return 41;
        if (processMachine != 0 || nativeMachine != $nativeMachine) {
            Console.Error.WriteLine("Fixture was not native $Architecture; processMachine=" + processMachine + "; nativeMachine=" + nativeMachine);
            return 42;
        }
        Console.WriteLine("Softwarekatalog CI fixture OK; process=$Architecture; os=$Architecture; native=True");
        return 0;
    }
}
"@
Add-Type -TypeDefinition $payloadSource -OutputAssembly (Join-Path $Root 'fixture.exe') -OutputType ConsoleApplication
Add-Type -Path (Join-Path $PSScriptRoot 'FixtureWinget.cs') -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Web.Extensions.dll') -OutputAssembly (Join-Path $Root 'winget-fixture.exe') -OutputType ConsoleApplication
$payload = [Security.SecurityElement]::Escape((Join-Path $Root 'fixture.exe'))
$wxs = @"
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="Softwarekatalog CI Fixture" Manufacturer="Softwarekatalog CI" Version="1.0.0" ProductCode="$productCode" UpgradeCode="$upgradeCode" Scope="perUserOrMachine" Compressed="yes">
    <MediaTemplate EmbedCab="yes" />
    <SetProperty Id="ARPINSTALLLOCATION" Value="[INSTALLFOLDER]" After="CostFinalize" Sequence="execute" />
    <StandardDirectory Id="ProgramFiles64Folder"><Directory Id="INSTALLFOLDER" Name="SoftwarekatalogCiFixture-$suffix" /></StandardDirectory>
    <StandardDirectory Id="ProgramMenuFolder" />
    <Feature Id="Main" Level="1">
      <Component Directory="INSTALLFOLDER" Guid="*">
        <File Source="$payload" KeyPath="yes">
          <Shortcut Id="CiShortcut" Directory="ProgramMenuFolder" Name="Softwarekatalog CI Fixture $suffix" Advertise="yes" />
        </File>
      </Component>
    </Feature>
  </Package>
</Wix>
"@
$source = Join-Path $Root 'fixture.wxs'
[IO.File]::WriteAllText($source, $wxs)
$stdout = Join-Path $Root 'wix.stdout.log'
$stderr = Join-Path $Root 'wix.stderr.log'
$arguments = 'build -arch {0} -o "{1}" "{2}"' -f $Architecture, $config.Msi, $source
$process = Start-Process -FilePath $WixPath -ArgumentList $arguments -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
# Retain the process handle: Windows PowerShell 5.1 otherwise loses ExitCode
# when Start-Process returns before a later WaitForExit call.
$handle = $process.Handle
if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'Fixture MSI build timed out.' }
$output = [IO.File]::ReadAllText($stdout) + [IO.File]::ReadAllText($stderr)
Write-Output $output
if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $config.Msi)) { throw "Fixture MSI build failed (exit=$($process.ExitCode), exists=$(Test-Path -LiteralPath $config.Msi)): $output" }
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace Softwarekatalog {
    public static class CiMsiSummary {
        [DllImport("msi.dll", CharSet = CharSet.Unicode)]
        static extern uint MsiGetSummaryInformation(uint database, string path, uint updates, out uint summary);
        [DllImport("msi.dll", CharSet = CharSet.Unicode)]
        static extern uint MsiSummaryInfoGetProperty(uint summary, uint property, out uint type,
            out int integer, out long fileTime, StringBuilder value, ref uint length);
        [DllImport("msi.dll")]
        static extern uint MsiCloseHandle(uint handle);
        public static string ReadTemplate(string path) {
            uint summary;
            uint code = MsiGetSummaryInformation(0, path, 0, out summary);
            if (code != 0) throw new InvalidOperationException("Cannot open MSI summary: " + code);
            try {
                var value = new StringBuilder(32768); uint length = 32768, type;
                int integer; long fileTime;
                code = MsiSummaryInfoGetProperty(summary, 7, out type, out integer, out fileTime, value, ref length);
                if (code != 0 || type != 30) throw new InvalidOperationException("Cannot read MSI Template: " + code + "; type=" + type);
                return value.ToString();
            } finally { MsiCloseHandle(summary); }
        }
    }
}
'@
$template = [Softwarekatalog.CiMsiSummary]::ReadTemplate([string]$config.Msi)
$expectedTemplate = if ($Architecture -eq 'arm64') { 'Arm64' } else { 'x64' }
if (($template -split ';')[0] -ine $expectedTemplate) { throw "MSI template '$template' does not target $expectedTemplate." }
$config['MsiTemplate'] = $template
$config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'fixture-config.json') -Encoding UTF8
Write-Output "Built disposable $Architecture MSI fixture $productCode (template=$template)"

# These are real MSI databases with production ArtCraft profile identities and
# only the harmless native-process probe as payload. Hash, Authenticode, MSI
# family and native-architecture checks stay entirely in the production code.
$catalogSource = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/ArtCraft.Catalog.ps1'
. ([scriptblock]::Create([IO.File]::ReadAllText($catalogSource, [Text.Encoding]::UTF8)))
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CiArtCraftExistingProducts {
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    public static extern uint MsiEnumRelatedProducts(string upgradeCode, uint reserved, uint index, StringBuilder productCode);
}
'@
foreach ($definition in @(Get-ArtCraftDefinitions | Where-Object { $_.Alias -in @('gridcraft','pdfcraft','wordcraft') })) {
    $foundCode = New-Object Text.StringBuilder 39
    $result = [CiArtCraftExistingProducts]::MsiEnumRelatedProducts($definition.UpgradeCode, 0, 0, $foundCode)
    if ($result -ne 259) { throw "Refusing pre-existing/uninspectable ArtCraft MSI family: $($definition.Alias), code=$result, product=$foundCode" }
    if (Test-Path -LiteralPath (Join-Path $env:ProgramFiles (Split-Path $definition.ExecutableRelativePath -Parent))) {
        throw "Refusing pre-existing ArtCraft target directory: $($definition.Alias)"
    }
}
$artConfigPath = Join-Path $Root 'artcraft-fixture-config.json'
$artConfig = [ordered]@{ Architecture = $Architecture; CertificateThumbprint = ''; CertificateSubject = ''; Packages = @() }
$certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject ('CN=Softwarekatalog Disposable CI ' + $suffix) `
    -CertStoreLocation 'Cert:\LocalMachine\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
    -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddDays(2)
$artConfig.CertificateThumbprint = $certificate.Thumbprint
$artConfig.CertificateSubject = $certificate.Subject
# Persist ownership before imports/builds can fail: the harness's finally
# removes precisely this leaf from all three stores and deletes its private key.
$artConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $artConfigPath -Encoding UTF8
$publicCertificate = Join-Path $Root 'artcraft-ci.cer'
Export-Certificate -Cert $certificate -FilePath $publicCertificate | Out-Null
# The ARM64 hosted runner's administrator cannot import into these machine
# stores (E_ACCESSDENIED). Use a real native SYSTEM token for both trust setup
# and revocation, without changing store ACLs/policy or weakening signature trust.
$certificateHelper = Join-Path $Root 'Manage-ArtCraftCertificate.ps1'
$certificateHelperSource = @'
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][ValidateSet('x64','arm64')][string]$ExpectedArchitecture,
    [Parameter(Mandatory)][ValidateSet('Trust','Remove')][string]$Operation,
    [switch]$SystemWorker)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath (Join-Path $Root '.disposable-ci-fixture'))) { throw 'Disposable fixture marker required.' }
. (Join-Path $Root 'WindowsArchitecture.ps1')
$resultPath = Join-Path $Root ("certificate-$Operation.result.json")
$architecturePath = Join-Path $Root ("certificate-$Operation.architecture.json")
if ($SystemWorker) {
    if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { throw 'Certificate store operation requires real SYSTEM.' }
    $success = $false; $detail = ''; $evidence = $null
    try {
        $evidence = Assert-CiWindowsArchitecture -ExpectedArchitecture $ExpectedArchitecture -ExpectedOSArchitecture $ExpectedArchitecture -RequireNative -OutputPath $architecturePath
        $config = Get-Content -LiteralPath (Join-Path $Root 'artcraft-fixture-config.json') -Raw | ConvertFrom-Json
        $thumbprint = [string]$config.CertificateThumbprint
        if ($thumbprint -notmatch '^[A-Fa-f0-9]{40}$') { throw 'Invalid owned certificate thumbprint.' }
        $publicPath = Join-Path $Root 'artcraft-ci.cer'
        $publicCert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($publicPath)
        if ($publicCert.Thumbprint -cne $thumbprint -or $publicCert.Subject -cne $config.CertificateSubject) { throw 'Public certificate does not match exact fixture ownership.' }
        $errors = @()
        $stores = if ($Operation -eq 'Trust') { @('Root','TrustedPublisher') } else { @('Root','TrustedPublisher','My') }
        foreach ($store in $stores) {
            try {
                $storePath = "Cert:\LocalMachine\$store"
                $certificatePath = "$storePath\$thumbprint"
                if ($Operation -eq 'Trust') {
                    Import-Certificate -FilePath $publicPath -CertStoreLocation $storePath | Out-Null
                    if (-not (Test-Path -LiteralPath $certificatePath)) { throw 'Certificate absent after real machine-store import.' }
                }
                else {
                    if (Test-Path -LiteralPath $certificatePath) {
                        if ($store -eq 'My') { Remove-Item -LiteralPath $certificatePath -DeleteKey -Force }
                        else { Remove-Item -LiteralPath $certificatePath -Force }
                    }
                    if (Test-Path -LiteralPath $certificatePath) { throw 'Certificate remains after removal.' }
                }
            }
            catch { $errors += "${store}: $($_ | Out-String)" }
        }
        if ($errors.Count) { throw ($errors -join "`n") }
        $success = $true
    }
    catch { $detail = $_ | Out-String }
    finally {
        [pscustomobject]@{ Success = $success; Operation = $Operation; Architecture = $evidence; Error = $detail } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    }
    if (-not $success) { exit 1 }; exit 0
}
$taskName = 'Softwarekatalog certificate CI ' + [guid]::NewGuid().ToString('N')
try {
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Root "' + $Root + '" -ExpectedArchitecture ' + $ExpectedArchitecture + ' -Operation ' + $Operation + ' -SystemWorker'
    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings | Out-Null
    $lastRun = (Get-ScheduledTaskInfo -TaskName $taskName).LastRunTime
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddMinutes(3)
    while (-not (Test-Path -LiteralPath $resultPath)) {
        if ((Get-Date) -gt $deadline) { throw "SYSTEM certificate $Operation timed out." }
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        if ($info.LastRunTime -gt $lastRun -and (Get-ScheduledTask -TaskName $taskName).State -notin @('Running','Queued')) {
            throw "SYSTEM certificate $Operation exited without evidence (task code $($info.LastTaskResult))."
        }
        Start-Sleep -Milliseconds 200
    }
    while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
        if ((Get-Date) -gt $deadline) { throw "SYSTEM certificate $Operation did not exit." }
        Start-Sleep -Milliseconds 200
    }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    if (-not $result.Success) { throw "SYSTEM certificate ${Operation}: $($result.Error)" }
    Assert-CiArchitectureRecord $result.Architecture $ExpectedArchitecture $ExpectedArchitecture -RequireNative
    if ($result.Architecture.Sid -ne 'S-1-5-18' -or (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult -ne 0) { throw 'Certificate operation lacked a successful native SYSTEM token.' }
    Write-Output "PASS native $ExpectedArchitecture SYSTEM certificate $Operation (real LocalMachine stores)"
}
finally {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
}
'@
[IO.File]::WriteAllText($certificateHelper, $certificateHelperSource, (New-Object Text.UTF8Encoding($true)))
& $certificateHelper -Root $Root -ExpectedArchitecture $Architecture -Operation Trust

function Build-ArtCraftFixtureMsi($Definition, [string]$Version, [string]$ProductCode, [string]$OutputPath) {
    $exe = Join-Path $Root ($Definition.Alias + '.exe')
    if (-not (Test-Path -LiteralPath $exe)) { Copy-Item -LiteralPath (Join-Path $Root 'fixture.exe') -Destination $exe }
    $exeXml = [Security.SecurityElement]::Escape($exe)
    $parts = [string[]]($Definition.ExecutableRelativePath -split '\\')
    $directoryXml = ''
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        $id = if ($i -eq $parts.Length - 2) { 'INSTALLFOLDER' } else { 'Parent' + $i }
        $directoryXml += '<Directory Id="' + $id + '" Name="' + $parts[$i] + '">'
    }
    for ($i = 0; $i -lt $parts.Length - 1; $i++) { $directoryXml += '</Directory>' }
    $text = @"
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="$($Definition.DisplayName)" Manufacturer="Softwarekatalog CI" Version="$Version" ProductCode="$ProductCode" UpgradeCode="$($Definition.UpgradeCode)" Scope="perUserOrMachine" Compressed="yes">
    <MediaTemplate EmbedCab="yes" />
    <MajorUpgrade DowngradeErrorMessage="A newer fixture is already installed." />
    <SetProperty Id="ARPINSTALLLOCATION" Value="[INSTALLFOLDER]" After="CostFinalize" Sequence="execute" />
    <StandardDirectory Id="ProgramFiles64Folder">$directoryXml</StandardDirectory>
    <StandardDirectory Id="ProgramMenuFolder" />
    <Feature Id="Main" Level="1">
      <Component Directory="INSTALLFOLDER" Guid="*">
        <File Source="$exeXml" KeyPath="yes">
          <Shortcut Id="ArtCraftShortcut" Directory="ProgramMenuFolder" Name="Softwarekatalog CI $($Definition.DisplayName) $suffix" Advertise="yes" />
        </File>
      </Component>
    </Feature>
  </Package>
</Wix>
"@
    $sourcePath = $OutputPath + '.wxs'
    [IO.File]::WriteAllText($sourcePath, $text)
    $p = Start-Process -FilePath $WixPath -ArgumentList ('build -arch {0} -o "{1}" "{2}"' -f $Architecture, $OutputPath, $sourcePath) `
        -PassThru -RedirectStandardOutput ($OutputPath + '.stdout.log') -RedirectStandardError ($OutputPath + '.stderr.log')
    $h = $p.Handle
    if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'ArtCraft fixture MSI build timed out.' }
    if ($p.ExitCode -ne 0) { throw "ArtCraft fixture build failed: $(Get-Content ($OutputPath + '.stderr.log') -Raw)" }
    $actualTemplate = [Softwarekatalog.CiMsiSummary]::ReadTemplate($OutputPath)
    if (($actualTemplate -split ';')[0] -ine $Architecture) { throw "Wrong ArtCraft MSI architecture: $actualTemplate" }
    $signature = Set-AuthenticodeSignature -LiteralPath $OutputPath -Certificate $certificate -HashAlgorithm SHA256
    if ($signature.Status -ne 'Valid' -or (Get-AuthenticodeSignature -LiteralPath $OutputPath).Status -ne 'Valid') {
        throw "Real fixture MSI Authenticode verification failed: $($signature.StatusMessage)"
    }
}

foreach ($alias in @('gridcraft', 'pdfcraft', 'wordcraft')) {
    $definition = Get-ArtCraftDefinitions | Where-Object Alias -eq $alias
    $machinePath = Join-Path $env:ProgramFiles (Split-Path $definition.ExecutableRelativePath -Parent)
    if (Test-Path -LiteralPath $machinePath) { throw "Refusing pre-existing ArtCraft path: $machinePath" }
    $oldCode = '{' + [Guid]::NewGuid().ToString().ToUpperInvariant() + '}'
    $newCode = '{' + [Guid]::NewGuid().ToString().ToUpperInvariant() + '}'
    $oldMsi = Join-Path $Root ("$alias-1.0.0-windows-$Architecture.msi")
    $assetName = "$alias-1.1.0-windows-$Architecture.msi"
    $newMsi = Join-Path $Root $assetName
    Build-ArtCraftFixtureMsi $definition '1.0.0' $oldCode $oldMsi
    Build-ArtCraftFixtureMsi $definition '1.1.0' $newCode $newMsi
    $artConfig.Packages += [pscustomobject]@{
        Alias = $alias; PackageId = $definition.PackageId; DisplayName = $definition.DisplayName
        UpgradeCode = $definition.UpgradeCode; Repository = $definition.Repository; Architecture = $Architecture
        OldProductCode = $oldCode; ProductCode = $newCode; OldMsi = $oldMsi; Msi = $newMsi
        Version = '1.1.0'; Tag = 'v1.1.0'; AssetName = $assetName
        Sha256 = (Get-FileHash -LiteralPath $newMsi -Algorithm SHA256).Hash.ToLowerInvariant()
        MachineDir = $machinePath; Executable = Join-Path $env:ProgramFiles $definition.ExecutableRelativePath
        LegacyDir = Join-Path $env:SystemRoot ("System32\config\systemprofile\AppData\Local\Programs\ArtCraftCi-$suffix-$alias")
        ShortcutName = "Softwarekatalog CI $($definition.DisplayName) $suffix"
    }
    $artConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $artConfigPath -Encoding UTF8
}
# Seed GridCraft through the same deterministic native CLI adapter used by the
# pre-existing WinGet integration lane, not by inventing an installed snapshot.
# Its mutation still runs real msiexec and records an actual old-provider call.
$gridFixture = $artConfig.Packages | Where-Object Alias -eq gridcraft
$adapterRoot = Join-Path $Root 'artcraft-old-winget'
New-Item -Path $adapterRoot -ItemType Directory | Out-Null
$gridFixture | Add-Member -NotePropertyName LegacyWingetAdapter -NotePropertyValue (Join-Path $adapterRoot 'winget-fixture.exe')
Copy-Item -LiteralPath (Join-Path $Root 'winget-fixture.exe') -Destination $gridFixture.LegacyWingetAdapter
@{ Root = $adapterRoot; ProductCode = $gridFixture.OldProductCode; PackageId = $gridFixture.PackageId; Name = $gridFixture.DisplayName
    MachineDir = $gridFixture.MachineDir; Msi = $gridFixture.OldMsi; LegacyDir = $gridFixture.LegacyDir } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $adapterRoot 'fixture-config.json') -Encoding UTF8
$artConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $artConfigPath -Encoding UTF8
