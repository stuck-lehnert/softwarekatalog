[CmdletBinding()]
param([string]$ResultsDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'test-results\unit'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$executable = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } elseif ($env:OS -eq 'Windows_NT') { 'pwsh.exe' } else { 'pwsh' }
$engine = Join-Path $PSHOME $executable
New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null
$failed = $false
foreach ($suite in @('Test-GeneratedScripts.ps1', 'Test-Core.ps1', 'Test-ScopeRepairs.ps1')) {
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
