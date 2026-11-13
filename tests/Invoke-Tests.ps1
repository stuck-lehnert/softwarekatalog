[CmdletBinding()]
param(
    [string]$ResultsDirectory,
    [ValidateSet('x86','x64','arm64')][string]$ExpectedArchitecture,
    [ValidateSet('x64','arm64')][string]$ExpectedOSArchitecture,
    [switch]$RequireNative
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PS5.1 can bind -File parameter defaults before initializing PSScriptRoot.
if (-not $ResultsDirectory) { $ResultsDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) 'test-results\unit' }
$executable = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } elseif ($env:OS -eq 'Windows_NT') { 'pwsh.exe' } else { 'pwsh' }
$engine = Join-Path $PSHOME $executable
New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null
$env:SOFTKAT_EXPECTED_PROCESS_ARCH = $ExpectedArchitecture
$env:SOFTKAT_EXPECTED_OS_ARCH = $ExpectedOSArchitecture
$env:SOFTKAT_REQUIRE_NATIVE = ([bool]$RequireNative).ToString().ToLowerInvariant()
if ($ExpectedArchitecture -or $ExpectedOSArchitecture -or $RequireNative) {
    if (-not $ExpectedArchitecture -or -not $ExpectedOSArchitecture) { throw 'Both expected process and OS architectures are required.' }
    . (Join-Path $PSScriptRoot 'helpers/WindowsArchitecture.ps1')
    $evidence = Assert-CiWindowsArchitecture -ExpectedArchitecture $ExpectedArchitecture -ExpectedOSArchitecture $ExpectedOSArchitecture `
        -RequireNative:$RequireNative -OutputPath (Join-Path $ResultsDirectory 'architecture.json')
    Write-Output ('Runtime architecture evidence: ' + ($evidence | ConvertTo-Json -Compress))
}
$failed = $false
foreach ($suite in @('Test-Architecture.ps1', 'Test-GeneratedScripts.ps1', 'Test-Core.ps1', 'Test-ScopeRepairs.ps1', 'Test-ArtCraftCatalog.ps1', 'Test-ArtCraftProvider.ps1')) {
    $name = [IO.Path]::GetFileNameWithoutExtension($suite)
    $stdout = Join-Path $ResultsDirectory "$name.stdout.log"
    $stderr = Join-Path $ResultsDirectory "$name.stderr.log"
    $suitePath = Join-Path $PSScriptRoot $suite
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $suitePath
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $engine -ArgumentList $arguments -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $handle = $process.Handle
    $timedOut = -not $process.WaitForExit(180000)
    if ($timedOut) { $process.Kill(); $process.WaitForExit() }
    $watch.Stop()
    $exitCode = if ($timedOut) { 124 } else { $process.ExitCode }
    $output = ([IO.File]::ReadAllText($stdout) + "`n" + [IO.File]::ReadAllText($stderr)) -replace '\x1B\[[0-9;]*m', ''
    $output = $output -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
    Write-Output $output
    $document = New-Object Xml.XmlDocument
    $root = $document.CreateElement('testsuite')
    $root.SetAttribute('name', "$name / $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)")
    $root.SetAttribute('time', $watch.Elapsed.TotalSeconds.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))
    [void]$document.AppendChild($root)
    $passed = @([regex]::Matches($output, '(?m)^PASS (.+)\r?$'))
    foreach ($match in $passed) {
        $case = $document.CreateElement('testcase')
        $case.SetAttribute('name', $match.Groups[1].Value.Trim())
        [void]$root.AppendChild($case)
    }
    if ($exitCode -ne 0 -or $passed.Count -eq 0) {
        $failed = $true
        if ($env:GITHUB_ACTIONS -eq 'true') {
            $detail = "Exit code $exitCode; timed out=$timedOut`n$output"
            if ($detail.Length -gt 12000) { $detail = $detail.Substring($detail.Length - 12000) }
            $detail = $detail.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
            Write-Output "::error title=$name::$detail"
        }
        $case = $document.CreateElement('testcase')
        $case.SetAttribute('name', 'Suite completed successfully with nonempty test output')
        $failure = $document.CreateElement('failure')
        $failure.SetAttribute('message', "Exit code $exitCode; timed out=$timedOut; passed checks=$($passed.Count)")
        $failure.InnerText = $output
        [void]$case.AppendChild($failure)
        [void]$root.AppendChild($case)
    }
    $root.SetAttribute('tests', [string]$root.ChildNodes.Count)
    $root.SetAttribute('failures', [string]@($root.SelectNodes('testcase/failure')).Count)
    $document.Save((Join-Path $ResultsDirectory "$name.junit.xml"))
}
if ($failed) { throw 'One or more suites failed; see test-results logs and JUnit XML.' }
