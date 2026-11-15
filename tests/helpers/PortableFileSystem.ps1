# Unit-test OS boundary only. Never included in a deployment or native SYSTEM
# scenario. Real Windows owner/DACL/no-follow/sharing tests use the production
# FileSystem.Security module without these doubles.
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/FileSystem.Security.ps1')

function Assert-TrustedFileSystemPath {
    param($Path, [switch]$Directory, [switch]$PublicDrop, [switch]$AncestorLeaf)
}

function New-TrustedDirectory {
    param($Path, [switch]$PublicDrop)
    [void][IO.Directory]::CreateDirectory($Path)
}

function Initialize-ServiceStorage {
    foreach ($name in @('Logs', 'Requests', 'AdminRequests', 'Processed', 'Failed', 'ArtCraft')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $BaseDir $name))
    }
}

function Open-TrustedFileRead {
    param($Path)
    return [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
}

function Write-TrustedBytes {
    param($Path, [AllowEmptyCollection()][byte[]]$Bytes, [switch]$Append, [switch]$CreateNew)

    $mode = if ($Append) { [IO.FileMode]::Append } elseif ($CreateNew) { [IO.FileMode]::CreateNew } else { [IO.FileMode]::Create }
    $stream = [IO.File]::Open($Path, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($Bytes, 0, $Bytes.Length) } finally { $stream.Dispose() }
}

function Open-RequestFileRead {
    param($Path)
    return [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
}

function Get-OpenRequestFileInformation {
    param($Stream)
    $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Stream.Name -Force
    return [pscustomobject]@{ ReparsePoint = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint); Directory = $false; Links = 1 }
}

function Remove-OpenRequestFile {
    param($Stream)
    $path = $Stream.Name
    $Stream.Dispose()
    Remove-Item -LiteralPath $path -Force
}
