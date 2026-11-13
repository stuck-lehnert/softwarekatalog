# Immutable product identities. Versions/download targets are resolved by the
# privileged provider, never supplied by policy strings or user requests.
function Get-ArtCraftDefinitions {
    $rows = @'
photocraft|ArtCraft.PhotoCraft|PhotoCraft|Open-Source-Bildbearbeitung mit Ebenen, Masken und PSD-Unterstützung|D9660F32-2D0A-4ABE-B73D-17BE25F1542C|perUserOrMachine|ArtCraft\PhotoCraft\photocraft.exe
vectorcraft|ArtCraft.VectorCraft|VectorCraft|Open-Source-Vektorgrafikeditor für Illustrationen und SVG-Dateien|601C6437-08AE-4645-ADCC-27F036C2EA2F|perUserOrMachine|ArtCraft\VectorCraft\vectorcraft.exe
filmcraft|ArtCraft.FilmCraft|FilmCraft|Open-Source-Videobearbeitung mit Zeitleiste, Effekten und Farbkorrektur|31E6FB14-9DBC-41DD-B24B-26B71FB31B62|perUserOrMachine|ArtCraft\FilmCraft\filmcraft.exe
lightcraft|ArtCraft.LightCraft|LightCraft|Fotoverwaltung und RAW-Entwicklung mit nicht-destruktiver Bildbearbeitung|229BB552-5EFD-479A-BA86-8CB6D926390C|perUserOrMachine|ArtCraft\LightCraft\lightcraft.exe
pdfcraft|ArtCraft.PdfCraft|PdfCraft|Open-Source-PDF-Editor zum Lesen, Zusammenfügen, Aufteilen und Organisieren von PDF-Dokumenten|EA00C367-7270-4C50-9D8B-A7A5C88AD27F|perUserOrMachine|ArtCraft\PdfCraft\pdfcraft.exe
effectcraft|ArtCraft.EffectCraft|EffectCraft|Open-Source-Software für Motion Graphics, Animationen und visuelle Effekte|AACA8593-C6ED-40A8-BA6C-CB325D8529F9|perUserOrMachine|ArtCraft\EffectCraft\effectcraft.exe
designcraft|ArtCraft.DesignCraft|DesignCraft|Open-Source-Layoutprogramm für Desktop-Publishing und Druckdokumente|49E87D30-BB68-4896-AA1D-F45C833CFC3C|perUserOrMachine|ArtCraft\DesignCraft\designcraft.exe
texturecraft|ArtCraft.TextureCraft|TextureCraft|Open-Source-Software zur Erstellung und Bearbeitung von 3D-Texturen|7E670E60-BB22-4E6B-8749-DD3FD4CA8979|perMachine|TextureCraft\texturecraft.exe
materialcraft|ArtCraft.MaterialCraft|MaterialCraft|Node-basierter Open-Source-Editor für prozedurale Materialien|89DE105E-B6C8-4261-ADBE-25BCFA3A0C91|perMachine|MaterialCraft\materialcraft.exe
wordcraft|ArtCraft.WordCraft|WordCraft|Open-Source-Textverarbeitung zum Erstellen und Bearbeiten von Dokumenten|075497F9-E861-45D0-9C7F-A74F8C34E6BA|perUserOrMachine|ArtCraft\WordCraft\wordcraft.exe
soundcraft|ArtCraft.SoundCraft|SoundCraft|Open-Source-Audiosoftware für Aufnahme, Schnitt, Mixing und Musikproduktion|EE53D3E5-D0AE-40F9-808D-9417FDEBF61A|perUserOrMachine|ArtCraft\SoundCraft\soundcraft.exe
deckcraft|ArtCraft.DeckCraft|DeckCraft|Open-Source-Präsentationssoftware zum Erstellen und Vorführen von Folien|6F9C69E7-7825-40D2-BF26-C274DA676425|perUserOrMachine|ArtCraft\DeckCraft\deckcraft.exe
cadcraft|ArtCraft.CadCraft|CADCraft|Open-Source-CAD-Software für technische Zeichnungen und Konstruktionen|119D7D76-0167-4A9E-8F37-09DA0235F68E|perUserOrMachine|ArtCraft\CADCraft\cadcraft.exe
gridcraft|ArtCraft.GridCraft|GridCraft|Open-Source-Tabellenkalkulation für Datenanalyse und Berechnungen|5511327B-F305-41BE-92D0-EB84944E7C4D|perUserOrMachine|ArtCraft\GridCraft\gridcraft.exe
'@
    foreach ($row in ($rows -split '\r?\n')) {
        $p = $row.Split('|')
        [pscustomobject]@{
            Alias = $p[0]; PackageId = $p[1]; DisplayName = $p[2]; Description = $p[3]
            UpgradeCode = '{' + $p[4] + '}'; InstallerScope = $p[5]; ExecutableRelativePath = $p[6]
            Provider = 'ArtCraft'; Repository = 'storytold/' + $p[0]; Visible = $true
        }
    }
}

function Get-ArtCraftAllowedSignerSubjects {
    # Read from the SHA256-verified MaterialCraft 0.4.1 release MSI, 2026-11-13.
    # Azure Trusted Signing uses short-lived leaf certificates; pin the verified
    # legal publisher identity, while Windows validates chain/timestamp/revocation.
    'CN=Learning Machines Inc, O=Learning Machines Inc, L=Atlanta, S=Georgia, C=US'
}

function Test-ArtCraftEnabled {
    ((Get-PolicyDword -Name 'Enabled' -Default 0) -eq 1) -and
        ((Get-PolicyDword -Name 'EnableArtCraft' -Default 0) -eq 1)
}

function Write-CatalogPolicyWarning {
    param([string]$Message)
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $Message 'WARN' }
    else { Write-Warning $Message }
}

function Merge-ArtCraftCatalog {
    param([AllowEmptyCollection()][object[]]$PolicyApps = @())
    $definitions = if (Test-ArtCraftEnabled) { @(Get-ArtCraftDefinitions) } else { @() }
    foreach ($definition in $definitions) { $definition }
    foreach ($app in $PolicyApps) {
        $reserved = @($definitions | Where-Object { $_.Alias -eq $app.Alias })
        if ($reserved.Count -gt 0) {
            if ($reserved[0].PackageId -ne $app.PackageId) {
                Write-CatalogPolicyWarning "Reserved ArtCraft alias '$($app.Alias)' conflicts with policy package '$($app.PackageId)'; policy row ignored."
            }
            continue
        }
        $definition = @($definitions | Where-Object { $_.PackageId -eq $app.PackageId })
        if ($definition.Count -gt 0) {
            # Keep explicitly configured legacy aliases usable, but show only the
            # canonical offer in GUI/-List. Metadata always comes from our table.
            $copy = $definition[0].PSObject.Copy()
            $copy.Alias = $app.Alias
            $copy.Visible = $false
            $copy
        }
        else {
            [pscustomobject]@{
                Alias = $app.Alias; PackageId = $app.PackageId; DisplayName = $app.DisplayName
                Description = $app.Description; Provider = 'WinGet'; Visible = $true
            }
        }
    }
}

function Expand-RequiredCatalogAliases {
    param([string[]]$Aliases = @(), [object[]]$Catalog = @())
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $result = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($alias in $Aliases) {
        [void]$result.Add($alias)
        foreach ($app in @($Catalog | Where-Object { $_.Alias -eq $alias })) { [void]$ids.Add($app.PackageId) }
    }
    foreach ($app in $Catalog) { if ($ids.Contains($app.PackageId)) { [void]$result.Add($app.Alias) } }
    foreach ($alias in $result) { $alias }
}
