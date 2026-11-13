[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$WixPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop') { throw 'Build fixtures with Windows PowerShell 5.1.' }
$null = New-Item -ItemType Directory -Path $Root -Force
$suffix = [Guid]::NewGuid().ToString('N')
$productCode = '{' + [Guid]::NewGuid().ToString().ToUpperInvariant() + '}'
$upgradeCode = '{' + [Guid]::NewGuid().ToString().ToUpperInvariant() + '}'
$machineDir = Join-Path $env:ProgramFiles "SoftwarekatalogCiFixture-$suffix"
$config = [ordered]@{
    Root = $Root; ProductCode = $productCode; UpgradeCode = $upgradeCode
    PackageId = 'Softwarekatalog.CiFixture'; Name = 'Softwarekatalog CI Fixture'
    MachineDir = $machineDir; Msi = Join-Path $Root 'fixture.msi'
    LegacyDir = Join-Path $env:SystemRoot "System32\config\systemprofile\AppData\Local\Programs\SoftwarekatalogCiFixture-$suffix"
}
$config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'fixture-config.json') -Encoding UTF8
Add-Type -TypeDefinition 'public static class ProbePayload { public static int Main(string[] args) { System.Console.WriteLine("Softwarekatalog CI fixture OK"); return 0; } }' -OutputAssembly (Join-Path $Root 'fixture.exe') -OutputType ConsoleApplication
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
$arguments = 'build -arch x64 -o "{0}" "{1}"' -f $config.Msi, $source
$process = Start-Process -FilePath $WixPath -ArgumentList $arguments -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'Fixture MSI build timed out.' }
$output = [IO.File]::ReadAllText($stdout) + [IO.File]::ReadAllText($stderr)
Write-Output $output
if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $config.Msi)) { throw "Fixture MSI build failed: $output" }
Write-Output "Built disposable MSI fixture $productCode"
