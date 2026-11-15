# Portable policy tests. Native ACL/no-follow/sharing is tested separately as SYSTEM.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'modules/FileSystem.Security.ps1')

$passed = 0
function Test-Security([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Output "PASS $Name"
}

function Reject([scriptblock]$Body) {
    try { & $Body }
    catch { return }

    throw 'Expected a security rejection.'
}

function New-Summary([string]$Owner = 'S-1-5-18', [object[]]$Rules = @()) {
    [pscustomobject]@{ Owner = $Owner; DaclPresent = $true; Rules = $Rules }
}

function New-Rule([string]$Sid, [int]$Mask, [bool]$Allow = $true, [bool]$InheritOnly = $false) {
    [pscustomobject]@{ Sid = $Sid; Mask = $Mask; Allow = $Allow; InheritOnly = $InheritOnly }
}

foreach ($owner in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')) {
    Test-Security "Trusted owner $owner is accepted with a present read-only DACL" {
        Assert-TrustedSecuritySummary (New-Summary -Owner $owner -Rules @((New-Rule 'S-1-5-32-545' 0x1200a9)))
    }
}

Test-Security 'Foreign owners and null DACLs are rejected, not repaired' {
    Reject { Assert-TrustedSecuritySummary (New-Summary -Owner 'S-1-5-21-1-2-3-1001') }
    $summary = New-Summary
    $summary.DaclPresent = $false
    Reject { Assert-TrustedSecuritySummary $summary }
}

foreach ($mask in @(2, 4, 16, 64, 256, 65536, 262144, 524288, 0x10000000, 0x40000000)) {
    Test-Security "Untrusted effective mutation bit $mask is rejected on private leaves" {
        Reject { Assert-TrustedSecuritySummary (New-Summary -Rules @((New-Rule 'S-1-5-32-545' $mask))) }
    }
}

Test-Security 'Ancestor allows new subdirectories, never deletion/replacement of existing children' {
    Assert-TrustedSecuritySummary (New-Summary -Rules @((New-Rule 'S-1-5-11' 4))) -Ancestor
    Assert-TrustedSecuritySummary (New-Summary -Rules @((New-Rule 'S-1-5-32-545' 0x116))) -Ancestor
    Reject { Assert-TrustedSecuritySummary (New-Summary -Rules @((New-Rule 'S-1-5-32-545' 0x116))) }
    Reject { Assert-TrustedSecuritySummary (New-Summary -Rules @((New-Rule 'S-1-5-11' 0x116))) -Ancestor }
    Reject { Assert-TrustedSecuritySummary (New-Summary -Rules @((New-Rule 'S-1-5-11' 64))) -Ancestor }
}

Test-Security 'Public drop permits Users input creation, not delete-child or ACL mutation' {
    Assert-TrustedSecuritySummary (New-Summary -Rules @((New-Rule 'S-1-5-32-545' 0x1201bf))) -PublicDrop
    Reject { Assert-TrustedSecuritySummary (New-Summary -Rules @((New-Rule 'S-1-5-32-545' 64))) -PublicDrop }
    Reject { Assert-TrustedSecuritySummary (New-Summary -Rules @((New-Rule 'S-1-5-11' 2))) -PublicDrop }
}

Test-Security 'Directory policy exceptions cannot be applied to file handles' {
    foreach ($flags in @(@{ Ancestor = $true }, @{ PublicDrop = $true })) {
        try { Assert-TrustedOpenFile -Handle ([object]::new()) @flags }
        catch {
            if ($_.Exception.Message -notlike '*exceptions apply only to directory objects*') { throw }

            continue
        }

        throw 'A directory policy exception reached native file handling.'
    }
}

Test-Security 'Inherit-only and deny ACEs do not grant effective parent writes' {
    Assert-TrustedSecuritySummary (New-Summary -Rules @(
        (New-Rule 'S-1-3-0' 0x1f01ff -InheritOnly $true),
        (New-Rule 'S-1-5-32-545' 0x1f01ff -Allow $false)
    ))
}

Test-Security 'Every privileged mode performs storage preflight as its first operation' {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'setup.ps1'), [ref]$tokens, [ref]$errors)
    foreach ($name in @('Install-Service', 'Invoke-ProcessRequestsMode', 'Invoke-ProcessRequestMode', 'Invoke-ProcessQueueMode', 'Invoke-UpgradeAllMode', 'Invoke-ApplyPolicyMode')) {
        $definition = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $name }
        if ($definition.Body.EndBlock.Statements[0].Extent.Text -ne 'Initialize-ServiceStorage') {
            throw "$name used storage before its trust preflight."
        }
    }
}

Test-Security 'Native filesystem structure sizes match BOOLEAN, DWORD and pointer ABI layouts' {
    Initialize-FileSystemSecurityNative
    $type = 'Softwarekatalog.TrustedFileSystemNative' -as [type]
    $disposition = $type.GetNestedType('FileDisposition', [Reflection.BindingFlags]::NonPublic)
    $attributes = $type.GetNestedType('SecurityAttributes', [Reflection.BindingFlags]::NonPublic)
    $expectedAttributes = if ([IntPtr]::Size -eq 8) { 24 } else { 12 }
    # Avoid Marshal.SizeOf's RuntimeType/Object overload ambiguity in PS7.
    $dispositionSize = [Runtime.InteropServices.Marshal]::SizeOf([Activator]::CreateInstance($disposition))
    $attributesSize = [Runtime.InteropServices.Marshal]::SizeOf([Activator]::CreateInstance($attributes))
    $informationSize = [Runtime.InteropServices.Marshal]::SizeOf((New-Object Softwarekatalog.TrustedFileSystemNative+FileInformation))
    if ($dispositionSize -ne 1 -or $attributesSize -ne $expectedAttributes -or $informationSize -ne 52) {
        throw 'Filesystem native interop structure sizes disagree with the Windows ABI.'
    }
}

if ($env:OS -eq 'Windows_NT') {
    Test-Security 'Real Windows security descriptors use native handles and byte-backed ACE flags in every engine lane' {
        Assert-TrustedFileSystemPath -Path $env:SystemRoot -Directory
        Assert-TrustedFileSystemPath -Path $env:ProgramData -Directory -AncestorLeaf
    }
}

Write-Output "Filesystem security policy: $passed passed."
