# Read-only installer trust smoke: real stable vendor downloads, no MSI install,
# no policy changes, no fixture transport/signers and no certificate imports.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('x64','arm64')][string]$ExpectedArchitecture,
    [switch]$AllPackages,
    [string]$ResultsDirectory,
    [string]$WorkerRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
    throw 'Vendor verification requires native Windows x64/ARM64 PowerShell 5.1.'
}
if ($WorkerRoot) {
    if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem -or
        -not (Test-Path -LiteralPath (Join-Path $WorkerRoot '.artcraft-vendor-smoke'))) { throw 'Protected SYSTEM smoke worker required.' }
    $settings = Get-Content -LiteralPath (Join-Path $WorkerRoot 'config.json') -Raw | ConvertFrom-Json
    . (Join-Path $WorkerRoot 'WindowsArchitecture.ps1')
    $architecture = Assert-CiWindowsArchitecture -ExpectedArchitecture $ExpectedArchitecture -ExpectedOSArchitecture $ExpectedArchitecture `
        -RequireNative -OutputPath (Join-Path $WorkerRoot 'system-architecture.json')
    $cases = New-Object 'System.Collections.Generic.List[object]'
    $script:vendorFailed = $false
    Start-Transcript -Path (Join-Path $WorkerRoot 'vendor.transcript.txt') | Out-Null
    try {
        # The same production definitions and helpers are used, without running
        # deployment/configuration/entry point or replacing ANY trust primitive.
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $settings.Repository 'setup.ps1'), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
        foreach ($statement in $ast.EndBlock.Statements) {
            if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($statement.Extent.Text)) }
        }
        foreach ($module in @('FileSystem.Security.ps1','ArtCraft.Catalog.ps1','ArtCraft.Provider.ps1')) {
            . ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path (Join-Path $settings.Repository 'modules') $module), [Text.Encoding]::UTF8)))
        }
        $BaseDir = Join-Path $WorkerRoot 'state'
        $LogDir = Join-Path $WorkerRoot 'logs'
        $LogFile = Join-Path $LogDir 'vendor.log'
        $WingetMutexName = 'Global\Softwarekatalog-Winget'
        New-TrustedDirectory -Path $BaseDir
        New-TrustedDirectory -Path $LogDir
        Invoke-WithWingetLock {
            Initialize-ArtCraftStorage
            $definitions = @(Get-ArtCraftDefinitions | Where-Object { $AllPackages -or $_.Alias -eq 'materialcraft' })
            foreach ($definition in $definitions) {
                $started = [datetime]::UtcNow
                try {
                    $target = Resolve-ArtCraftRelease -Definition $definition
                    $path = Save-ArtCraftInstaller -Definition $definition -Target $target
                    $metadata = Assert-ArtCraftInstaller -Definition $definition -Target $target -Path $path
                    $signature = Get-AuthenticodeSignature -LiteralPath $path
                    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ($signature.Status -ne 'Valid' -or $hash -cne $target.Sha256.ToLowerInvariant() -or
                        $metadata.UpgradeCode -ine $definition.UpgradeCode -or $metadata.Architecture -cne $ExpectedArchitecture -or
                        $target.Architecture -cne $ExpectedArchitecture -or $metadata.ProductCode -ine $target.ProductCode) {
                        throw 'Real vendor hash/AuthentiCode/MSI family/native-architecture evidence disagrees.'
                    }
                    $cases.Add([pscustomobject]@{
                        PackageId = $definition.PackageId; Success = $true; Error = ''; Repository = $definition.Repository
                        Tag = $target.Tag; Version = $target.Version; AssetName = $target.AssetName; Sha256 = $hash
                        SignatureStatus = [string]$signature.Status; SignerSubject = $signature.SignerCertificate.Subject
                        SignerThumbprint = $signature.SignerCertificate.Thumbprint; UpgradeCode = $metadata.UpgradeCode
                        ProductCode = $metadata.ProductCode; Architecture = $metadata.Architecture
                        Bytes = (Get-Item -LiteralPath $path).Length; CheckedUtc = [datetime]::UtcNow.ToString('o')
                        Seconds = ([datetime]::UtcNow - $started).TotalSeconds
                    })
                    Write-Output "PASS real vendor $($definition.PackageId) $($target.Version) ${ExpectedArchitecture}: SHA256, Authenticode Valid, exact pinned publisher, native MSI family"
                    # This smoke never executes MSI and does not accumulate up
                    # to fourteen large installers as CI artifacts.
                    Remove-Item -LiteralPath $path -Force
                }
                catch {
                    $script:vendorFailed = $true
                    $cases.Add([pscustomobject]@{ PackageId = $definition.PackageId; Success = $false; Error = ($_ | Out-String) })
                    Write-Warning "Real vendor verification failed for $($definition.PackageId): $_"
                }
            }
        }
    }
    catch { $script:vendorFailed = $true; $cases.Add([pscustomobject]@{ PackageId = 'Vendor smoke harness'; Success = $false; Error = ($_ | Out-String) }) }
    finally {
        [pscustomobject]@{ Success = (-not $script:vendorFailed); ReadOnly = $true; InstalledAnyMsi = $false; Architecture = $architecture; Cases = @($cases.ToArray()) } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $WorkerRoot 'summary.json') -Encoding UTF8
        Stop-Transcript | Out-Null
    }
    if ($script:vendorFailed) { exit 1 }
    return
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator required to schedule the read-only SYSTEM verification worker.' }
$repo = Split-Path $PSScriptRoot -Parent
if (-not $ResultsDirectory) { $ResultsDirectory = Join-Path $repo 'test-results\artcraft-vendor' }
New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null
. (Join-Path $PSScriptRoot 'helpers/WindowsArchitecture.ps1')
$architecture = Assert-CiWindowsArchitecture -ExpectedArchitecture $ExpectedArchitecture -ExpectedOSArchitecture $ExpectedArchitecture `
    -RequireNative -OutputPath (Join-Path $ResultsDirectory 'architecture.json')
$root = Join-Path $env:ProgramData ('Softwarekatalog-VendorSmoke-' + [guid]::NewGuid().ToString('N'))
$taskName = 'Softwarekatalog vendor smoke ' + [guid]::NewGuid().ToString('N')
$timeoutMinutes = if ($AllPackages) { 60 } else { 15 }
New-Item -ItemType Directory -Path $root | Out-Null
try {
    & icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not protect vendor-smoke scratch directory.' }
    Set-Content -LiteralPath (Join-Path $root '.artcraft-vendor-smoke') -Value 'Owned by read-only Softwarekatalog vendor smoke'
    @{ Repository = $repo } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'config.json') -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'helpers/WindowsArchitecture.ps1') -Destination (Join-Path $root 'WindowsArchitecture.ps1')
    $scriptPath = Join-Path $root 'Test-ArtCraftVendor.ps1'
    Copy-Item -LiteralPath $PSCommandPath -Destination $scriptPath
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '" -ExpectedArchitecture ' + $ExpectedArchitecture + ' -WorkerRoot "' + $root + '"'
    if ($AllPackages) { $arguments += ' -AllPackages' }
    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument $arguments
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes $timeoutMinutes) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $taskPrincipal -Settings $taskSettings | Out-Null
    $lastRun = (Get-ScheduledTaskInfo -TaskName $taskName).LastRunTime
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddMinutes($timeoutMinutes)
    $summaryPath = Join-Path $root 'summary.json'
    while (-not (Test-Path -LiteralPath $summaryPath)) {
        if ((Get-Date) -gt $deadline) { throw 'Read-only vendor smoke timed out.' }
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        if ($info.LastRunTime -gt $lastRun -and (Get-ScheduledTask -TaskName $taskName).State -notin @('Running','Queued')) {
            throw "Vendor smoke exited before writing results: task code $($info.LastTaskResult)."
        }
        Start-Sleep -Milliseconds 300
    }
    while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
        if ((Get-Date) -gt $deadline) { throw 'Vendor smoke worker did not exit.' }
        Start-Sleep -Milliseconds 200
    }
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    Assert-CiArchitectureRecord -Evidence $summary.Architecture -ExpectedArchitecture $ExpectedArchitecture -ExpectedOSArchitecture $ExpectedArchitecture -RequireNative
    $expectedCount = if ($AllPackages) { 14 } else { 1 }
    if (-not $summary.Success -or $summary.Architecture.Sid -ne 'S-1-5-18' -or @($summary.Cases).Count -ne $expectedCount -or
        @($summary.Cases | Where-Object { -not $_.Success }).Count -gt 0 -or
        (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult -ne 0) {
        throw ('Read-only real-vendor verification failed: ' + (($summary.Cases | Where-Object { -not $_.Success } | ForEach-Object { $_.Error }) -join "`n"))
    }
    Write-Output "$expectedCount real vendor native $ExpectedArchitecture MSI(s) passed SHA256, Valid Authenticode, exact production publisher and MSI identity verification. No installation performed."
}
finally {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    # Logs/results contain only public release/certificate metadata, not MSI
    # payloads, policy, certificate keys, or productive provider state.
    foreach ($name in @('summary.json','system-architecture.json','vendor.transcript.txt')) {
        $path = Join-Path $root $name
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $ResultsDirectory $name) -Force }
    }
    if (Test-Path -LiteralPath (Join-Path $root 'logs')) { Copy-Item -LiteralPath (Join-Path $root 'logs') -Destination $ResultsDirectory -Recurse -Force }
    Remove-Item -LiteralPath $root -Recurse -Force
}
