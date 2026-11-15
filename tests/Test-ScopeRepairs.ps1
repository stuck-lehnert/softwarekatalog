# No Pester dependency. Runs with Windows PowerShell 5.1 and PowerShell 7.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'setup.ps1'
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path (Split-Path $sourcePath -Parent) 'modules/ArtCraft.Catalog.ps1'), [Text.Encoding]::UTF8)))
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path (Split-Path $sourcePath -Parent) 'modules/ArtCraft.Provider.ps1'), [Text.Encoding]::UTF8)))
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
# Load only function definitions, never setup configuration or its entry point.
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
. (Join-Path $PSScriptRoot 'helpers/PortableFileSystem.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules/WinGet.Trust.ps1')
$realMsiEvidence = ${function:Get-MsiRegistrationEvidence}

$script:passed = 0
$script:tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('scope-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:tempRoot | Out-Null
$originalSystemRoot = $env:SystemRoot
$env:SystemRoot = 'C:\Windows'

function Assert($Condition, [string]$Message = 'Assertion failed') {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    try { & $Body } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected exception matching '$Pattern'."
}
function Assert-EmptyRepairJournal {
    $raw = Get-Content -LiteralPath $script:ScopeRepairPath -Raw
    Assert ($raw.TrimStart().StartsWith('[')) 'Repair journal must remain a JSON array'
    $parsed = $raw | ConvertFrom-Json
    Assert (@($parsed).Count -eq 0) 'Repair journal must contain no pending intents'
}
function Test([string]$Name, [scriptblock]$Body) {
    $script:events = @()
    $script:diagnosticLog = @()
    $script:registrations = @()
    $script:machineInstalled = $false
    $script:installCode = 0
    $script:ScopeRepairFailures = @()
    $script:MsiInspectionFailures = @()
    $script:BaseDir = Join-Path $script:tempRoot ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:BaseDir | Out-Null
    $script:ScopeRepairPath = Join-Path $script:BaseDir 'Scope-Repairs.json'
    $script:InstalledPackagesPath = Join-Path $script:BaseDir 'Installed-Packages.json'
    $script:WingetSourceName = 'winget'
    $script:catalog = @([pscustomobject]@{ PackageId = 'ArtCraft.GridCraft'; Alias = 'grid'; DisplayName = 'Custom catalog label' })
    try { & $Body }
    catch {
        Write-Output "FAIL $Name"
        Write-Output $_.ScriptStackTrace
        Write-Output "Events: $($script:events -join '; ')"
        $script:diagnosticLog | Select-Object -Last 15 | Write-Output
        throw
    }
    $script:passed++
    Write-Output "PASS $Name"
}
function New-Registration([string]$Location = 'C:\Windows\System32\config\systemprofile\AppData\Local\Programs\ArtCraft\GridCraft', [string]$Name = 'GridCraft') {
    [pscustomobject]@{
        ProductCode = '{EA4ACB4A-7AB6-43B8-9F85-944EBBFBE7A1}'
        DisplayName = $Name; InstallLocation = $Location; DisplayIcon = ''
        WindowsInstaller = $true; Scope = 'user'; RegistryView = 'Registry64'
    }
}
function Write-Log { param($Message, $Level) $script:diagnosticLog += [string]$Message }
function Test-SoftwareCatalogPolicyEnabled { return $true }
function Test-RunningAsLocalSystem { return $true }
function Get-AppCatalogObjects { $script:catalog }
function Get-RegisteredApplications { $script:registrations }
function Get-MsiRegistrationEvidence {
    param($Registration)
    [pscustomobject]@{
        UpgradeCode = '{5511327B-F305-41BE-92D0-EB84944E7C4D}'
        ExecutablePaths = @('C:\Windows\System32\config\systemprofile\AppData\Local\Programs\ArtCraft\GridCraft\gridcraft.exe')
    }
}
function Test-WingetMachineInstallation { param($WingetPath, $PackageId) return $script:machineInstalled }
function Invoke-WingetQuery {
    param($WingetPath, $Arguments)
    $script:events += ($Arguments -join ' ')
    if ($Arguments[0] -eq 'uninstall') {
        Assert (Test-Path -LiteralPath $script:ScopeRepairPath) 'Journal must precede uninstall'
        $script:registrations = @()
    }
    [pscustomobject]@{ ExitCode = 0; Output = 'GridCraft ArtCraft.GridCraft 0.16.0 winget' }
}
# Keep the real install/upgrade implementations available for argument tests.
$realInstall = ${function:Invoke-WingetInstall}
$realMachineTest = [scriptblock]::Create(($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Test-WingetMachineInstallation'
}).Body.Extent.Text.TrimStart('{').TrimEnd('}'))
function Invoke-WingetInstall {
    param($WingetPath, $PackageId)
    $script:events += 'machine-install'
    $script:machineInstalled = ($script:installCode -eq 0)
    return $script:installCode
}

try {
    Test 'Plausible WindowsApps names and architecture strings do not authenticate a WinGet path' {
        $arm = 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.9.0.0_arm64__8wekyb3d8bbwe\winget.exe'
        $x64 = 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_9.99.0.0_x64__8wekyb3d8bbwe\winget.exe'
        $alias = 'C:\Users\SYSTEM\AppData\Local\Microsoft\WindowsApps\winget.exe'
        Assert ($null -eq (Select-WingetPath -Candidates @($x64, $alias, $arm) -NativeArchitecture arm64))
        Assert ($null -eq (Select-WingetPath -Candidates @($arm, $x64) -NativeArchitecture x64))
        Assert ($null -eq (Select-WingetPath -Candidates @($arm, $x64) -NativeArchitecture x86))
    }
    Test 'Higher path versions and duplicate unauthenticated candidates cannot gain priority' {
        $old = 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.9.0.0_arm64__8wekyb3d8bbwe\winget.exe'
        $new = $old.Replace('1.9.0.0', '1.23.0.0')
        $x64 = $new.Replace('_arm64_', '_x64_')
        $x86 = $new.Replace('_arm64_', '_x86_')
        Assert ($null -eq (Select-WingetPath -Candidates @($old, $new, $new) -NativeArchitecture arm64))
        Assert ($null -eq (Select-WingetPath -Candidates @($x86, $x64) -NativeArchitecture arm64))
        Assert ($null -eq (Select-WingetPath -Candidates @($x86, $x64) -NativeArchitecture x64))
        Assert ($null -eq (Select-WingetPath -Candidates @() -NativeArchitecture arm64))
    }
    Test 'Native OS architecture is independent of PowerShell process bitness' {
        if ($env:OS -eq 'Windows_NT') {
            $actual = Get-NativeWindowsArchitecture
            Assert ($actual -in @('x86', 'x64', 'arm64'))
            if ($env:SOFTKAT_EXPECTED_OS_ARCH) { Assert ($actual -eq $env:SOFTKAT_EXPECTED_OS_ARCH) }
        } else {
            $architectureSource = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
                    $node.Value -match 'public static class NativeArchitecture'
            }, $true))[0].Value
            if (-not ('Softwarekatalog.NativeArchitecture' -as [type])) { Add-Type -TypeDefinition $architectureSource }
        }
    }
    Test 'Native MSI declarations compile and use context-aware APIs' {
        $nativeSource = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
                $node.Value -match 'public static class NativeMsi'
        }, $true))[0].Value
        if (-not ('Softwarekatalog.NativeMsi' -as [type])) { Add-Type -TypeDefinition $nativeSource }
        Assert ([Softwarekatalog.NativeMsi].GetMethod('MsiGetProductInfoEx').GetParameters().Count -eq 6)
        Assert ([Softwarekatalog.NativeMsi].GetMethod('MsiGetComponentPathEx').GetParameters().Count -eq 6)
        Assert ([Softwarekatalog.NativeMsi].GetMethod('GetProductInfo').GetParameters().Count -eq 5) 'PS boundary must not accept a nullable string SID'
        Assert ([Softwarekatalog.NativeMsi].GetMethod('GetComponentPath').GetParameters().Count -eq 5)
        Assert ($nativeSource -match 'MsiGetProductInfoEx\(product, null, context') 'Native NULL must be supplied inside C#'
        Assert ($nativeSource -match 'MsiGetComponentPathEx\(product, component, null, context')
        $inventory = ($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Get-RegisteredApplications' }).Extent.Text
        Assert ($inventory.Contains('Registry64') -and $inventory.Contains('Registry32'))
        Assert ($inventory.Contains('S-1-5-18\'))
    }
    Test 'SYSTEM classic MSI lookup rejects ambiguous registrations including unnamed copies' {
        $machine = New-Registration
        $machine.Scope = 'machine'
        $user = New-Registration
        $user.DisplayName = ''
        Assert (Test-MsiClassicLookupSafe -Registration $machine -Registrations @($machine))
        Assert (Test-MsiClassicLookupSafe -Registration $user -Registrations @($user))
        Assert (-not (Test-MsiClassicLookupSafe -Registration $machine -Registrations @($machine, $user)))
        Assert (-not (Test-MsiClassicLookupSafe -Registration $user -Registrations @($machine, $user)))
        Assert (-not (Test-MsiClassicLookupSafe -Registration $machine -Registrations @()))
        Assert (-not (Test-MsiClassicLookupSafe -Registration $machine -Registrations @($user)))
        $machine.WindowsInstaller = $false
        Assert (-not (Test-MsiClassicLookupSafe -Registration $machine -Registrations @($machine)))
        $inventory = ($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Get-RegisteredApplications' }).Extent.Text
        Assert ($inventory.Contains('$IncludeUnnamed'))
    }
    Test 'Native MSI failures remain visible with scope and Windows error diagnostics' {
        $script:diagnostics = @()
        function Write-Log { param($Message, $Level) $script:diagnostics += [string]$Message }
        foreach ($scope in @('machine', 'user')) {
            $registration = New-Registration
            $registration.ProductCode = '{' + [Guid]::NewGuid().ToString() + '}'
            $registration.Scope = $scope
            $evidence = & $realMsiEvidence -Registration $registration
            Assert ($null -eq $evidence) 'An unknown product must not supply executable evidence'
            Assert ($script:MsiInspectionFailures -contains $registration.ProductCode)
            $message = $script:diagnostics[-1]
            Assert ($message -match "scope='$scope'")
            if ($env:OS -eq 'Windows_NT') {
                # Exercise the real read-only API even in ordinary unit jobs.
                # A true NULL SID yields UNKNOWN_PRODUCT, not INVALID_PARAMETER.
                Assert ($message -match 'Win32=1605') $message
                Assert ($message -notmatch 'Win32=87\b') $message
            }
        }
    }
    Test 'AppData detection is case-insensitive, boundary-safe and includes WOW64' {
        foreach ($path in @(
            'C:\Windows\System32\config\systemprofile\AppData\Local\Programs\app',
            'c:\WINDOWS\syswow64\CONFIG\systemprofile\APPDATA\Roaming\app',
            '"C:\Windows\System32\config\systemprofile\AppData\Local\app.exe",0'
        )) { Assert (Test-SystemProfileAppDataPath $path) $path }
        foreach ($path in @('', 'C:\Users\Alice\AppData\Local\app', 'C:\Program Files\app',
            'C:\Windows\System32\config\systemprofile\AppDataOther\app',
            'C:\Windows\System32\config\systemprofile\AppData\..\other')) {
            Assert (-not (Test-SystemProfileAppDataPath $path)) $path
        }
    }
    Test 'MSI executable evidence detects WiX packages without ARP InstallLocation' {
        $reg = New-Registration -Location ''
        Assert (@(Get-SystemProfileApplications -Registrations @($reg)).Count -eq 1)
        function Get-MsiRegistrationEvidence { [pscustomobject]@{ UpgradeCode = ''; ExecutablePaths = @() } }
        Assert (@(Get-SystemProfileApplications -Registrations @($reg)).Count -eq 0)
    }
    Test 'Cached icons and ordinary user data are not mistaken for program payloads' {
        $reg = New-Registration -Location 'C:\Program Files\ArtCraft\GridCraft'
        $reg.DisplayIcon = 'C:\Windows\System32\config\systemprofile\AppData\Local\icons\app.ico'
        Assert (@(Get-SystemProfileApplications -Registrations @($reg)).Count -eq 0)
        $reg.InstallLocation = ''
        $reg.WindowsInstaller = $false
        Assert (@(Get-SystemProfileApplications -Registrations @($reg)).Count -eq 0)
        $reg.DisplayIcon = '"C:\Windows\System32\config\systemprofile\AppData\Local\app\app.exe",0'
        Assert (@(Get-SystemProfileApplications -Registrations @($reg)).Count -eq 1)
    }
    Test 'GridCraft MSI identity maps even without winget correlation or matching catalog display name' {
        $reg = New-Registration
        $candidate = @(Get-SystemProfileApplications -Registrations @($reg))[0]
        $app = Find-SystemProfileCatalogApp fake $candidate $script:catalog @($reg)
        Assert ($app.PackageId -eq 'ArtCraft.GridCraft')
        Assert (@(Find-SystemProfileCatalogApp fake $candidate @() @($reg)).Count -eq 0) 'Policy required'
    }
    Test 'PDFCraft shares explicit MSI scope handling and stable verified identity' {
        $script:catalog = @([pscustomobject]@{ PackageId = 'ArtCraft.PdfCraft'; Alias = 'pdf'; DisplayName = 'Custom PDF label' })
        $reg = New-Registration -Name PdfCraft
        $candidate = [pscustomobject]@{ Registration = $reg; MsiEvidence = [pscustomobject]@{ UpgradeCode = '{EA00C367-7270-4C50-9D8B-A7A5C88AD27F}' } }
        Assert ((Find-SystemProfileCatalogApp fake $candidate $script:catalog @($reg)).PackageId -eq 'ArtCraft.PdfCraft')
        Assert ((@(Get-MachineInstallerArguments ArtCraft.PdfCraft) -join ' ') -eq '--custom ALLUSERS=1')
        Assert (@(Get-MachineInstallerArguments ArtCraft.UnverifiedExe).Count -eq 0) 'Never send MSI properties to arbitrary ArtCraft EXEs'
    }
    Test 'Generic package uses exact winget correlation, not catalog display name' {
        function Get-MsiRegistrationEvidence { return $null }
        $reg = New-Registration -Name 'Some app'
        $reg.WindowsInstaller = $false
        $script:catalog = @([pscustomobject]@{ PackageId = 'Vendor.App'; Alias = 'a'; DisplayName = 'Different' })
        function Invoke-WingetQuery {
            param($WingetPath, $Arguments)
            Assert ($Arguments -contains '--exact')
            Assert ($Arguments -contains '--scope')
            [pscustomobject]@{ ExitCode = 0; Output = "Name Id Version`nSome app Vendor.App 1.0" }
        }
        $candidate = [pscustomobject]@{ Registration = $reg; MsiEvidence = $null }
        Assert ((Find-SystemProfileCatalogApp fake $candidate $script:catalog @($reg)).PackageId -eq 'Vendor.App')
        $duplicate = New-Registration -Name 'Some app'
        $duplicate.ProductCode = 'other-registration'
        Assert (@(Find-SystemProfileCatalogApp fake $candidate $script:catalog @($reg, $duplicate)).Count -eq 0)
        function Invoke-WingetQuery { [pscustomobject]@{ ExitCode = 0; Output = 'Some app Vendor.App.Other 1.0' } }
        Assert (@(Find-SystemProfileCatalogApp fake $candidate $script:catalog @($reg)).Count -eq 0) 'Reject ID prefixes'
    }
    Test 'Migration downloads, journals, uninstalls exact user product, installs and verifies' {
        $script:registrations = @(New-Registration)
        Invoke-SystemProfileRepairs fake
        Assert ($script:events[0] -match '^download .*--scope machine')
        Assert ($script:events[1] -match '^uninstall .*--product-code .*--scope user')
        Assert ($script:events[2] -eq 'machine-install')
        Assert-EmptyRepairJournal
        Assert ($script:ScopeRepairFailures.Count -eq 0)
        $script:events = @()
        Invoke-SystemProfileRepairs fake
        Assert ($script:events.Count -eq 0) 'Second pass must be idempotent'
    }
    Test 'Mislocated machine registration is repaired too, not only per-user registrations' {
        $reg = New-Registration
        $reg.Scope = 'machine'
        $script:registrations = @($reg)
        Invoke-SystemProfileRepairs fake
        Assert ($script:events[1] -match '^uninstall .*--scope machine')
        Assert ($script:events[2] -eq 'machine-install')
        Assert ($script:ScopeRepairFailures.Count -eq 0)
    }
    Test 'No machine installer/network failure retains original installation' {
        $script:registrations = @(New-Registration)
        function Invoke-WingetQuery { [pscustomobject]@{ ExitCode = 1; Output = '' } }
        Invoke-SystemProfileRepairs fake
        Assert ($script:registrations.Count -eq 1)
        Assert (-not (Test-Path $script:ScopeRepairPath))
        Assert ($script:ScopeRepairFailures -contains 'ArtCraft.GridCraft')
    }
    Test 'Failed reinstall persists intent and resumes even with old registration gone' {
        $script:registrations = @(New-Registration)
        $script:installCode = 42
        Invoke-SystemProfileRepairs fake
        Assert ($script:registrations.Count -eq 0)
        Assert (@(Get-Content $script:ScopeRepairPath -Raw | ConvertFrom-Json).Count -eq 1)
        Assert ($script:ScopeRepairFailures -contains 'ArtCraft.GridCraft')
        $script:installCode = 0
        $script:events = @()
        Invoke-SystemProfileRepairs fake
        Assert ($script:events.Count -eq 2) 'Resume: download and install, no second uninstall'
        Assert-EmptyRepairJournal
    }
    Test 'Retained uninstall registration blocks reinstall and leaves repair intent' {
        $script:registrations = @(New-Registration)
        function Invoke-WingetQuery { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Invoke-SystemProfileRepairs fake
        Assert (-not $script:machineInstalled)
        Assert ($script:ScopeRepairFailures.Count -eq 1)
        Assert (Test-Path $script:ScopeRepairPath)
    }
    Test 'Existing valid machine copy is kept when removing a stray SYSTEM-user copy' {
        $script:registrations = @(New-Registration)
        $script:machineInstalled = $true
        Invoke-SystemProfileRepairs fake
        Assert ($script:events.Count -eq 2) 'Only preflight and old-user uninstall, no machine reinstall'
        Assert ($script:machineInstalled)
        Assert ($script:ScopeRepairFailures.Count -eq 0)
    }
    Test 'Pending intent cannot reinstall packages removed from policy' {
        Write-ScopeRepairJournal @([pscustomobject]@{ PackageId = 'Removed.App' })
        Invoke-SystemProfileRepairs fake
        Assert ($script:events.Count -eq 0)
        Assert ((Get-Content $script:ScopeRepairPath -Raw) -match 'Removed.App')
    }
    Test 'Unknown SYSTEM-profile programs are reported but never removed' {
        $script:registrations = @(New-Registration)
        function Get-MsiRegistrationEvidence { return $null }
        function Invoke-WingetQuery { [pscustomobject]@{ ExitCode = 0; Output = 'Unlisted.App' } }
        Invoke-SystemProfileRepairs fake
        Assert ($script:registrations.Count -eq 1)
        Assert (-not (Test-Path $script:ScopeRepairPath))
    }
    Test 'Policy disabled and non-SYSTEM execution cannot mutate installations' {
        function Test-RunningAsLocalSystem { return $false }
        Assert-Throws { Invoke-SystemProfileRepairs fake } 'LocalSystem'
        function Test-SoftwareCatalogPolicyEnabled { return $false }
        Invoke-SystemProfileRepairs fake
        Assert ($script:events.Count -eq 0)
    }
    Test 'Corrupt journal fails closed' {
        Set-Content $script:ScopeRepairPath -Value '{ broken json'
        Assert-Throws { Invoke-SystemProfileRepairs fake } '.'
        Assert ($script:events.Count -eq 0)
    }
    Test 'Journal loading tolerates Windows PowerShell 5.1 non-enumerating JSON arrays' {
        function ConvertFrom-Json {
            param([Parameter(ValueFromPipeline)]$InputObject)
            process {
                $value = Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject
                Write-Output -NoEnumerate @($value)
            }
        }
        Write-ScopeRepairJournal -Entries @()
        Invoke-SystemProfileRepairs fake
        Assert ($script:events.Count -eq 0)
        Add-ScopeRepairIntent -PackageId 'Removed.App'
        Add-ScopeRepairIntent -PackageId 'Other.RemovedApp'
        Invoke-SystemProfileRepairs fake
        Assert ($script:events.Count -eq 0)
        $journalText = Get-Content $script:ScopeRepairPath -Raw
        Assert ($journalText -match 'Removed.App' -and $journalText -match 'Other.RemovedApp')
    }
    Test 'MSI fallback only for missing correlation, using registered GUID and no arbitrary command' {
        $reg = New-Registration
        function Invoke-WingetQuery { [pscustomobject]@{ ExitCode = -1978335212; Output = '' } }
        function Join-Path { param($Path, $ChildPath) return "$Path\$ChildPath" }
        function Start-Process {
            param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
            Assert ($FilePath -eq 'C:\Windows\System32\msiexec.exe')
            Assert (($ArgumentList -join ' ') -eq "/x $($reg.ProductCode) /qn /norestart")
            [pscustomobject]@{ ExitCode = 0 }
        }
        Uninstall-SystemProfileApplication fake ArtCraft.GridCraft $reg
        function Invoke-WingetQuery { [pscustomobject]@{ ExitCode = 1603; Output = '' } }
        function Start-Process { throw 'Fallback must not run for an arbitrary installer error' }
        Assert-Throws { Uninstall-SystemProfileApplication fake ArtCraft.GridCraft $reg } 'returned 1603'
        $reg.ProductCode = 'not-a-guid & bad.exe'
        function Invoke-WingetQuery { [pscustomobject]@{ ExitCode = -1978335212; Output = '' } }
        Assert-Throws { Uninstall-SystemProfileApplication fake ArtCraft.GridCraft $reg } 'returned'
    }
    Test 'Real install arguments retain machine/source/silent flags and append ALLUSERS only for verified MSI profiles' {
        function Fake-Winget { $script:nativeArgs = @($args); $global:LASTEXITCODE = 0 }
        function Set-WingetOutputEncoding {}
        function Test-WingetMachineInstallation { return $true }
        function Get-SystemProfileApplications { return @() }
        $result = & $realInstall -WingetPath Fake-Winget -PackageId ArtCraft.GridCraft
        Assert ($result -eq 0)
        $line = $script:nativeArgs -join ' '
        Assert ($line -match '--scope machine')
        Assert ($line -match '--source winget')
        Assert ($line -match '--custom ALLUSERS=1')
        Assert ($line -notmatch '--override')
        $null = & $realInstall -WingetPath Fake-Winget -PackageId ArtCraft.PdfCraft
        Assert (($script:nativeArgs -join ' ') -match '--custom ALLUSERS=1')
        $null = & $realInstall -WingetPath Fake-Winget -PackageId Vendor.Other
        Assert ($script:nativeArgs -notcontains '--custom')
        function Test-WingetMachineInstallation { return $false }
        Assert-Throws { & $realInstall -WingetPath Fake-Winget -PackageId ArtCraft.GridCraft } 'could not be verified'
        Assert ($script:ScopeRepairFailures -contains 'ArtCraft.GridCraft')
        Assert (Test-Path $script:ScopeRepairPath) 'False success must retain repair intent'
    }
    Test 'Reported machine success with payload in SYSTEM AppData is rejected and journaled' {
        function Fake-Winget { $global:LASTEXITCODE = 0 }
        function Set-WingetOutputEncoding {}
        function Test-WingetMachineInstallation { return $true }
        $script:registrations = @(New-Registration)
        Assert-Throws { & $realInstall -WingetPath Fake-Winget -PackageId ArtCraft.GridCraft } 'SYSTEM AppData'
        Assert ($script:ScopeRepairFailures -contains 'ArtCraft.GridCraft')
        Assert (Test-Path $script:ScopeRepairPath)
    }
    Test 'Machine verification requires exact winget scope and each verified vendor executable' {
        function Invoke-WingetQuery {
            param($WingetPath, $Arguments)
            Assert (($Arguments -join ' ') -match '--scope machine')
            $id = $Arguments[[array]::IndexOf($Arguments, '--id') + 1]
            [pscustomobject]@{ ExitCode = 0; Output = "Application $id 0.16.0" }
        }
        function Join-Path { param($Path, $ChildPath) "$Path\$ChildPath" }
        function Test-Path { param($LiteralPath) return $script:payloadExists -and $LiteralPath -eq $script:expectedPayload }
        $oldProgramFiles = $env:ProgramFiles
        $env:ProgramFiles = 'C:\Program Files'
        try {
            foreach ($profile in @(
                @{ Id = 'ArtCraft.GridCraft'; Exe = 'ArtCraft\GridCraft\gridcraft.exe' }
                @{ Id = 'ArtCraft.PdfCraft'; Exe = 'ArtCraft\PdfCraft\pdfcraft.exe' }
            )) {
                $script:expectedPayload = "C:\Program Files\$($profile.Exe)"
                $script:payloadExists = $false
                Assert (-not (& $realMachineTest fake $profile.Id))
                $script:payloadExists = $true
                Assert (& $realMachineTest fake $profile.Id)
            }
        } finally { $env:ProgramFiles = $oldProgramFiles }
    }
    Test 'Legacy WinGet upgrades use individual ALLUSERS commands without a competing blanket upgrade' {
        Set-Content $script:InstalledPackagesPath -Value '{"InstalledPackageIds":["ArtCraft.GridCraft","ArtCraft.PdfCraft"]}'
        $script:machineInstalled = $true
        function Invoke-WingetQuery {
            param($WingetPath, $Arguments)
            $script:events += ($Arguments -join ' ')
            [pscustomobject]@{ ExitCode = -1978335189; Output = '' }
        }
        function Fake-Winget { $script:events += ($args -join ' '); $global:LASTEXITCODE = 0 }
        function Set-WingetOutputEncoding {}
        Assert ((Invoke-WingetUpgradeAll Fake-Winget) -eq 0)
        Assert ($script:events[0] -match '^upgrade --id ArtCraft.GridCraft .*--custom ALLUSERS=1')
        Assert ($script:events[1] -match '^upgrade --id ArtCraft.PdfCraft .*--custom ALLUSERS=1')
        Assert ($script:events.Count -eq 2)
        Assert (@($script:events | Where-Object { $_ -match '--all' }).Count -eq 0)
        $script:ScopeRepairFailures = @('ArtCraft.GridCraft')
        Assert-Throws { Invoke-WingetUpgradeAll Fake-Winget } 'repairs failed'
    }
    Test 'Installed and required sets retain set semantics for zero, one and multiple values' {
        $set = Get-InstalledPackageIdSet
        Assert ($set -is [Collections.Generic.HashSet[string]])
        Assert (-not $set.Contains('ArtCraft.GridCraft'))
        Set-Content $script:InstalledPackagesPath -Value '{"InstalledPackageIds":["ArtCraft.GridCraft"]}'
        Assert ((Get-InstalledPackageIdSet).Contains('artcraft.gridcraft'))
        Set-Content $script:InstalledPackagesPath -Value '{"InstalledPackageIds":["ArtCraft.GridCraft","Vendor.Other"]}'
        $set = Get-InstalledPackageIdSet
        Assert ($set.Contains('artcraft.gridcraft'))
        Assert (-not $set.Contains('GridCraft'))
        function Get-RequiredAliases { 'grid' }
        Assert ((Get-RequiredAliasSet).Contains('GRID'))
    }
    Test 'Snapshot excludes failed migrations rather than calling SYSTEM-user copies installed' {
        $script:ScopeRepairFailures = @('ArtCraft.GridCraft')
        function Fake-Winget {
            $pathIndex = [array]::IndexOf($args, '--output') + 1
            Set-Content -LiteralPath $args[$pathIndex] -Value '{"Sources":[{"Packages":[{"PackageIdentifier":"ArtCraft.GridCraft"},{"PackageIdentifier":"Vendor.Other"}]}]}'
            $global:LASTEXITCODE = 0
        }
        function Set-WingetOutputEncoding {}
        Assert (Update-InstalledPackagesSnapshot -WingetPath Fake-Winget)
        $set = Get-InstalledPackageIdSet
        Assert ($set.Contains('Vendor.Other'))
        Assert (-not $set.Contains('ArtCraft.GridCraft'))
    }
    Test 'Failed repair bypasses the installed shortcut with a failure, not already installed' {
        $script:ScopeRepairFailures = @('ArtCraft.GridCraft')
        function Get-RequiredAliases { return @() }
        function Test-UserInstallsAllowed { return $true }
        function Test-ServerOperatingSystem { return $false } # OS boundary; authorization has its own suite.
        $item = [pscustomobject]@{ Action = 'Install'; Alias = 'grid'; Id = 'test' }
        Assert-Throws { Invoke-QueuedItem -Item $item -WingetPath fake } 'repair.*failed'
        Assert ($script:events.Count -eq 0)
    }
    Test 'Worker repairs before snapshot/installed shortcut and deployment starts inventory without pending work' {
        $worker = ($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Invoke-ProcessQueueMode' }).Extent.Text
        Assert ($worker.IndexOf('Invoke-SystemProfileRepairs') -lt $worker.IndexOf('Update-InstalledPackagesSnapshot'))
        $service = ($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Install-Service' }).Extent.Text
        Assert ($service -match 'Start-QueueWorkerIfAvailable')
        Assert ($service -notmatch 'Test-QueueHasPendingWork')
    }
    Write-Output "$script:passed tests passed."
}
finally {
    $env:SystemRoot = $originalSystemRoot
    Remove-Item -LiteralPath $script:tempRoot -Recurse -Force
}
