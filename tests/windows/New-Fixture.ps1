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
$installer = $null
$summary = $null
try {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $summary = $installer.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $installer, @($config.Msi, [int]0))
    $template = [string]$summary.GetType().InvokeMember('Property', 'GetProperty', $null, $summary, @([int]7))
    $expectedTemplate = if ($Architecture -eq 'arm64') { 'Arm64' } else { 'x64' }
    if (($template -split ';')[0] -ine $expectedTemplate) { throw "MSI template '$template' does not target $expectedTemplate." }
    $config['MsiTemplate'] = $template
    $config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'fixture-config.json') -Encoding UTF8
}
finally {
    if ($summary) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary) }
    if ($installer) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) }
}
Write-Output "Built disposable $Architecture MSI fixture $productCode (template=$template)"
