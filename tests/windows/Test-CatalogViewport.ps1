# Called by Test-GeneratedScripts after compiling the actual generated C# helpers.
# Real native WinForms handles, but no interactive dialog or user input is needed.
param([Parameter(Mandatory=$true)][string]$GuiPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens=$null; $errors=$null
$guiAst=[Management.Automation.Language.Parser]::ParseFile($GuiPath,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Load-AppList','Sort-ListByColumn')) {
    $node=$guiAst.Find({ param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    },$true)
    if (-not $node) { throw "Generated GUI function missing: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
# Only data/other UI boundaries are replaced. The generated refresh, sorting,
# selection and native scroll restoration execute unchanged on a real ListView.
function Get-CatalogApps { $script:viewportApps }
function Get-InstalledPackageState { [pscustomobject]@{GeneratedAt=$null;Details=@()} }
function Get-AppStatus { param($App,$InstalledSet,$QueueItems) $script:viewportStatus }
function Update-ProgressArea {}
function Update-InstallButtonState {}
function Check($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
$script:LastInstalledIds=@(); $script:LastQueue=@(); $script:viewportStatus='Installierbar'
$script:viewportApps=@(0..99 | ForEach-Object {
    [pscustomobject]@{DisplayName=('App {0:d3}' -f $_);Description='Viewport fixture';Alias=('app{0:d3}' -f $_);PackageId="Vendor.App$_";Provider='WinGet'}
})
$allApps=@($script:viewportApps)
$snapshotLabel=[pscustomobject]@{Text=''}; $installedLabel=[pscustomobject]@{Text=''}
$form=New-Object Windows.Forms.Form
try {
    $form.ShowInTaskbar=$false
    $form.StartPosition='Manual'
    $form.Location=New-Object Drawing.Point(-10000,-10000)
    $form.ClientSize=New-Object Drawing.Size(480,240)
    $list=New-Object Windows.Forms.ListView
    $list.View='Details'; $list.MultiSelect=$false; $list.FullRowSelect=$true
    $list.HideSelection=$false; $list.Dock='Fill'
    foreach ($header in @('Anwendung','Beschreibung','Status','Alias','Paket-ID','Version / Ziel','Quelle')) {
        [void]$list.Columns.Add($header,160)
    }
    $columnSorter=New-Object ListViewColumnSorter
    $list.ListViewItemSorter=$columnSorter
    $form.Controls.Add($list)
    Load-AppList # Also exercise the first load, before showing/creating handles.
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    Check ($list.IsHandleCreated -and $list.Items.Count -eq 100) 'Real GUI list was not populated.'

    $list.TopItem=$list.Items[40]
    [ListViewViewport]::SetHorizontalOffset($list,220)
    $horizontal=[ListViewViewport]::GetHorizontalOffset($list)
    Check ($horizontal -gt 0 -and $list.TopItem.SubItems[3].Text -eq 'app040') 'Fixture must actually be scrolled in both directions.'
    Check ($list.SelectedItems.Count -eq 0) 'Unselected-scroll fixture unexpectedly has a selection.'
    1..3 | ForEach-Object {
        Load-AppList
        Check ($list.TopItem.SubItems[3].Text -eq 'app040' -and [ListViewViewport]::GetHorizontalOffset($list) -eq $horizontal) 'Unselected refresh reset vertical or horizontal scrolling.'
    }
    Write-Output 'PASS GUI refresh preserves both scroll axes without a selection, repeatedly'

    $list.Items[2].Selected=$true; $list.Items[2].Focused=$true
    $list.TopItem=$list.Items[40]
    [ListViewViewport]::SetHorizontalOffset($list,$horizontal)
    Load-AppList
    Check ($list.SelectedItems.Count -eq 1 -and $list.SelectedItems[0].SubItems[3].Text -eq 'app002') 'Refresh lost the selected application.'
    Check ($list.FocusedItem.SubItems[3].Text -eq 'app002') 'Refresh lost the keyboard-focus item.'
    Check ($list.TopItem.SubItems[3].Text -eq 'app040' -and [ListViewViewport]::GetHorizontalOffset($list) -eq $horizontal) 'An off-screen selection pulled the viewport away from its anchor.'
    Write-Output 'PASS GUI refresh keeps off-screen selection and focus without scrolling to it'

    $script:viewportApps=@([pscustomobject]@{DisplayName='AAA Added';Description='New';Alias='new';PackageId='Vendor.New';Provider='WinGet'})+$allApps
    $script:viewportStatus='Installiert'
    Load-AppList
    Check ($list.TopItem.SubItems[3].Text -eq 'app040' -and $list.TopItem.Index -eq 41) 'Refresh restored a row number instead of the stable application alias.'
    Check ($list.SelectedItems[0].SubItems[2].Text -eq 'Installiert') 'Preserving the viewport prevented real status updates.'
    Write-Output 'PASS GUI refresh anchors by application alias when rows are inserted and statuses change'

    Sort-ListByColumn -ColumnIndex 0
    Check ($columnSorter.Order -eq [Windows.Forms.SortOrder]::Descending) 'Fixture did not use actual descending GUI sorting.'
    $list.TopItem=$list.Items[35]
    $anchor=$list.TopItem.SubItems[3].Text
    Load-AppList
    Check ($columnSorter.Order -eq [Windows.Forms.SortOrder]::Descending -and $list.TopItem.SubItems[3].Text -eq $anchor) 'Refresh lost the current sort order or sorted viewport anchor.'
    Write-Output 'PASS GUI refresh preserves the viewport with descending column sorting'

    $index=$list.TopItem.Index
    $script:viewportApps=@($script:viewportApps | Where-Object { $_.Alias -notin @($anchor,'app002') })
    Load-AppList
    Check ($list.SelectedItems.Count -eq 0) 'A removed application remained selected.'
    Check ($list.TopItem.Index -eq $index) 'Removed viewport anchor did not fall back to the nearest remaining row.'
    Write-Output 'PASS GUI refresh handles removed selections and anchors without jumping to the beginning'

    $script:viewportApps=@($allApps | Select-Object -First 2)
    Load-AppList
    Check ($list.Items.Count -eq 2 -and $null -ne $list.TopItem) 'Shortened catalog did not clamp the saved position safely.'
    $script:viewportApps=@()
    Load-AppList
    Check ($list.Items.Count -eq 0 -and $list.SelectedItems.Count -eq 0) 'Empty catalog retained stale rows or selection.'
    $script:viewportApps=$allApps
    Load-AppList
    Check ($list.Items.Count -eq 100 -and $list.TopItem.Index -eq 0) 'Refilling an empty catalog did not start at a valid initial position.'
    Write-Output 'PASS GUI refresh safely handles short, empty and repopulated catalogs'
}
finally { $form.Dispose() }
