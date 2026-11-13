# Architecture evidence must come from the running process, not pointer size or
# inherited PROCESSOR_ARCHITECTURE (x64 emulation is 64-bit too).
function ConvertTo-CiArchitectureName {
    param([Parameter(Mandatory)][uint16]$Machine)
    switch ([int]$Machine) {
        0x014c { return 'x86' }
        0x8664 { return 'x64' }
        0xaa64 { return 'arm64' }
        default { throw ('Unsupported Windows machine type 0x{0:X4}.' -f $Machine) }
    }
}

function New-CiArchitectureRecord {
    param(
        [Parameter(Mandatory)][uint16]$ProcessMachine,
        [Parameter(Mandatory)][uint16]$NativeMachine,
        [string]$Executable,
        [string]$Identity,
        [string]$Sid
    )
    $effectiveMachine = if ($ProcessMachine -eq 0) { $NativeMachine } else { $ProcessMachine }
    [pscustomobject][ordered]@{
        Source = 'kernel32!IsWow64Process2'
        OSArchitecture = ConvertTo-CiArchitectureName $NativeMachine
        ProcessArchitecture = ConvertTo-CiArchitectureName $effectiveMachine
        IsNative = ($ProcessMachine -eq 0)
        ProcessMachine = [int]$ProcessMachine
        NativeMachine = [int]$NativeMachine
        PointerSize = [IntPtr]::Size
        ProcessId = $PID
        Executable = $Executable
        PowerShellVersion = [string]$PSVersionTable.PSVersion
        PSEdition = $PSVersionTable.PSEdition
        Identity = $Identity
        Sid = $Sid
        RunnerArchitecture = $env:RUNNER_ARCH
        EnvironmentArchitecture = $env:PROCESSOR_ARCHITECTURE
    }
}

function Get-CiWindowsArchitecture {
    if ($env:OS -ne 'Windows_NT') { throw 'Windows architecture evidence requires Windows.' }
    if (-not ('Softwarekatalog.CiProcessArchitecture' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Softwarekatalog {
    public static class CiProcessArchitecture {
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
    }
}
'@
    }
    $processMachine = [uint16]0
    $nativeMachine = [uint16]0
    $ok = [Softwarekatalog.CiProcessArchitecture]::IsWow64Process2(
        [Softwarekatalog.CiProcessArchitecture]::GetCurrentProcess(), [ref]$processMachine, [ref]$nativeMachine)
    if (-not $ok) { throw ('IsWow64Process2 failed: Win32 error {0}.' -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    New-CiArchitectureRecord -ProcessMachine $processMachine -NativeMachine $nativeMachine `
        -Executable ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Identity $identity.Name -Sid $identity.User.Value
}

function Assert-CiArchitectureRecord {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][ValidateSet('x86','x64','arm64')][string]$ExpectedArchitecture,
        [Parameter(Mandatory)][ValidateSet('x64','arm64')][string]$ExpectedOSArchitecture,
        [switch]$RequireNative
    )
    if ($Evidence.ProcessArchitecture -ne $ExpectedArchitecture -or $Evidence.OSArchitecture -ne $ExpectedOSArchitecture) {
        throw "Architecture mismatch: process=$($Evidence.ProcessArchitecture), OS=$($Evidence.OSArchitecture); expected process=$ExpectedArchitecture, OS=$ExpectedOSArchitecture."
    }
    if ($RequireNative -and -not $Evidence.IsNative) {
        throw "Emulation is forbidden for this lane: process=$($Evidence.ProcessArchitecture), OS=$($Evidence.OSArchitecture)."
    }
}

function Assert-CiWindowsArchitecture {
    param(
        [Parameter(Mandatory)][ValidateSet('x86','x64','arm64')][string]$ExpectedArchitecture,
        [Parameter(Mandatory)][ValidateSet('x64','arm64')][string]$ExpectedOSArchitecture,
        [switch]$RequireNative,
        [string]$OutputPath
    )
    $evidence = Get-CiWindowsArchitecture
    # Preserve evidence even when the assertion fails; emulation must be an
    # actionable test failure, never an implicit x64-to-ARM64 success fallback.
    if ($OutputPath) {
        $parent = Split-Path $OutputPath -Parent
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $evidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    }
    Assert-CiArchitectureRecord -Evidence $evidence -ExpectedArchitecture $ExpectedArchitecture `
        -ExpectedOSArchitecture $ExpectedOSArchitecture -RequireNative:$RequireNative
    return $evidence
}
