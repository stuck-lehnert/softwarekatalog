# Dependency-free helper regression tests plus actual Windows runtime evidence.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'helpers/WindowsArchitecture.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    try { & $Body | Out-Null } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; return }
    throw "Expected exception matching '$Pattern'."
}

$x64 = New-CiArchitectureRecord -ProcessMachine 0 -NativeMachine 0x8664
Assert-CiArchitectureRecord $x64 x64 x64 -RequireNative
Assert ($x64.IsNative -and $x64.ProcessArchitecture -eq 'x64') 'Native x64 decoded incorrectly.'
Write-Output 'PASS Native x64 machine-type decoding and contract'
$arm = New-CiArchitectureRecord -ProcessMachine 0 -NativeMachine 0xaa64
Assert-CiArchitectureRecord $arm arm64 arm64 -RequireNative
Assert ($arm.IsNative -and $arm.ProcessArchitecture -eq 'arm64') 'Native ARM64 decoded incorrectly.'
Write-Output 'PASS Native ARM64 machine-type decoding and contract'
$emulated = New-CiArchitectureRecord -ProcessMachine 0x8664 -NativeMachine 0xaa64
Assert-CiArchitectureRecord $emulated x64 arm64
Assert-Throws { Assert-CiArchitectureRecord $emulated x64 arm64 -RequireNative } 'Emulation is forbidden'
Assert-Throws { Assert-CiArchitectureRecord $emulated arm64 arm64 -RequireNative } 'Architecture mismatch'
Write-Output 'PASS x64 emulation on ARM64 is never accepted as native ARM64'
$x86 = New-CiArchitectureRecord -ProcessMachine 0x014c -NativeMachine 0x8664
Assert-CiArchitectureRecord $x86 x86 x64
Assert-Throws { Assert-CiArchitectureRecord $x86 x86 x64 -RequireNative } 'Emulation is forbidden'
Assert-Throws { Assert-CiArchitectureRecord $x64 x64 arm64 } 'Architecture mismatch'
Write-Output 'PASS Deliberate x86-on-x64 lane is distinct from native lanes'
Assert-Throws { ConvertTo-CiArchitectureName 0 } 'Unsupported Windows machine type'
Assert-Throws { ConvertTo-CiArchitectureName 0x01c4 } 'Unsupported Windows machine type'
Write-Output 'PASS Unknown/ARM32 machine types fail closed instead of being called ARM64'

if ($env:OS -eq 'Windows_NT') {
    $actual = Get-CiWindowsArchitecture
    Assert ($actual.ProcessId -eq $PID) 'Architecture evidence describes another process.'
    Assert ($actual.Executable -and $actual.Source -eq 'kernel32!IsWow64Process2') 'Missing real Win32 evidence.'
    Assert (($actual.ProcessArchitecture -eq 'x86' -and [IntPtr]::Size -eq 4) -or
        ($actual.ProcessArchitecture -in @('x64','arm64') -and [IntPtr]::Size -eq 8)) 'Pointer width contradicts Win32 evidence.'
    if ($env:SOFTKAT_EXPECTED_PROCESS_ARCH) {
        Assert-CiArchitectureRecord $actual $env:SOFTKAT_EXPECTED_PROCESS_ARCH $env:SOFTKAT_EXPECTED_OS_ARCH `
            -RequireNative:($env:SOFTKAT_REQUIRE_NATIVE -eq 'true')
    }
    Write-Output ('Runtime architecture evidence: ' + ($actual | ConvertTo-Json -Compress))
    Write-Output 'PASS Actual Windows process and OS architecture satisfy this CI lane'
}
else {
    Write-Output 'SKIP Native Windows API execution is verified only by Windows CI; portable contracts above passed'
}
