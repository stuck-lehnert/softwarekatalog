Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $root 'modules/ArtCraft.Catalog.ps1'), [Text.Encoding]::UTF8)))
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'setup.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
. (Join-Path $PSScriptRoot 'helpers/PortableFileSystem.ps1')

# Generation must be safe without a Windows UI/session. Only the ACL boundary
# is replaced here; generated PowerShell is parsed by the current real engine.
function Set-FileAclAdminsOnly { param($Path) }
$base = Join-Path ([IO.Path]::GetTempPath()) ("softkat-generated-O'Brien-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base | Out-Null
try {
    $CatalogDisplayName = "Softwarekatalog O'Brien"
    $LogFile = Join-Path $base 'service.log'
    $InstalledPackagesPath = Join-Path $base 'Installed-Packages.json'
    $QueueStatePath = Join-Path $base 'Queue-State.json'
    $RequestsDir = Join-Path $base 'Requests'
    $PolicyRoot = 'HKLM:\Software\Policies\STL\Softwarekatalog'
    $PolicyCatalogRoot = "$PolicyRoot\Catalog"
    $PolicyRequiredRoot = "$PolicyRoot\Required"
    $PolicyMaxEntries = 500
    $RequestToolPath = Join-Path $base 'Request-App.ps1'
    $CatalogGuiPath = Join-Path $base 'Software-Catalog.ps1'
    $CatalogLauncherPath = Join-Path $base 'Launch.vbs'
    $PowerShellExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    New-UserRequestTool
    New-CatalogGui
    New-CatalogLauncher
    foreach ($path in @($RequestToolPath, $CatalogGuiPath)) {
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { throw "Missing UTF-8 BOM: $path" }
        $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
        Write-Output "PASS generated script syntax and UTF-8 BOM: $([IO.Path]::GetFileName($path))"
    }
    $bytes = [IO.File]::ReadAllBytes($CatalogLauncherPath)
    if ($bytes[0] -ne 0xFF -or $bytes[1] -ne 0xFE) { throw 'VBS launcher must have UTF-16LE BOM' }
    $vbs = [IO.File]::ReadAllText($CatalogLauncherPath)
    if ($vbs -notmatch '-STA' -or $vbs -notmatch 'False') { throw 'Launcher must use STA without waiting for the UI' }
    Write-Output 'PASS generated VBS launcher encoding and invocation'
    $guiAst = [Management.Automation.Language.Parser]::ParseFile($CatalogGuiPath, [ref]$tokens, [ref]$parseErrors)
    $snapshotFunction = $guiAst.Find({ param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-InstalledPackageState'
    }, $true)
    if (-not $snapshotFunction) { throw 'Generated GUI snapshot reader missing.' }
    . ([scriptblock]::Create($snapshotFunction.Extent.Text))
    Set-Content -LiteralPath $InstalledPackagesPath -Encoding UTF8 -Value '{"GeneratedAt":"2020-01-01T00:00:00Z","InstalledPackageIds":[]}'
    $snapshotState = Get-InstalledPackageState
    if (([datetime]$snapshotState.GeneratedAt).ToUniversalTime().Ticks -ne ([datetime]'2020-01-01T00:00:00Z').ToUniversalTime().Ticks) {
        throw 'Generated GUI lost the snapshot instant/offset during JSON deserialization.'
    }
    Write-Output 'PASS generated GUI snapshot preserves timestamp kind/offset across PS5 and PS7'
    $count = 5
    if ($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSEdition -eq 'Desktop') {
        Add-Type -AssemblyName System.Windows.Forms
        $guiAst = [Management.Automation.Language.Parser]::ParseFile($CatalogGuiPath, [ref]$tokens, [ref]$parseErrors)
        foreach ($node in $guiAst.FindAll({
            param($n)
            $n -is [Management.Automation.Language.StringConstantExpressionAst] -and
                $n.Value -match 'public (static )?class (ListViewColumnSorter|ShellIconExtractor)'
        }, $true)) {
            Add-Type -TypeDefinition $node.Value -ReferencedAssemblies @('System.dll', 'System.Windows.Forms.dll')
        }
        $sorter = New-Object ListViewColumnSorter
        $a = New-Object Windows.Forms.ListViewItem('alpha')
        $z = New-Object Windows.Forms.ListViewItem('zeta')
        if ($sorter.Compare($a, $z) -ge 0) { throw 'Generated GUI sorter ascending comparison failed.' }
        $sorter.Order = [Windows.Forms.SortOrder]::Descending
        if ($sorter.Compare($a, $z) -le 0) { throw 'Generated GUI sorter descending comparison failed.' }
        $form = New-Object Windows.Forms.Form
        try {
            $label = New-Object Windows.Forms.Label
            $form.Controls.Add($label)
            if ($form.Controls.Count -ne 1) { throw 'Windows Forms control creation failed.' }
        } finally { $form.Dispose() }
        Write-Output 'PASS generated GUI C# helpers compile, sort and create Windows Forms controls (no interactive dialog)'
        $count++
        $viewportOutput = @(& (Join-Path $PSScriptRoot 'windows/Test-CatalogViewport.ps1') -GuiPath $CatalogGuiPath)
        $viewportOutput | Write-Output
        $count += @($viewportOutput | Where-Object { $_ -like 'PASS *' }).Count
    }
    # Check every checked-in PS file, including Windows-only harnesses, with
    # Windows PowerShell 5.1 as well as PS7 in CI. Parsing does not execute them.
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -Recurse) {
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    }
    Write-Output 'PASS checked-in PowerShell syntax'
    Write-Output "$count tests passed."
}
finally { Remove-Item -LiteralPath $base -Recurse -Force }
