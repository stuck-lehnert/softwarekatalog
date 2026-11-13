# Plan: eigener ArtCraft-Provider

Stand: 2026-11-13. **Akzeptierter und implementierter Provider-Entwurf.**
Implementierung: `modules/ArtCraft.Catalog.ps1`, `modules/ArtCraft.Provider.ps1`
und gemeinsame Worker-/Client-Integration in `setup.ps1`. Der Build bündelt
diese Quellen weiterhin in ein einzelnes auslieferbares Skript.
Opt-in, Migration und Betriebsdetails stehen in [README.md](../README.md);
die nachfolgenden Abschnitte dokumentieren die zugrunde liegenden Anforderungen.

## 1. Ziel und Bedienung

ArtCraft wird direkt aus den offiziellen stabilen Hersteller-Releases bezogen,
nicht mehr aus den zeitversetzt aktualisierten WinGet-Manifesten. Andere Software
bleibt beim bestehenden WinGet-Provider. Queue, Pflichtsoftware, Rechteprüfung,
Reparaturjournal und Oberfläche bleiben gemeinsam.

In die vorhandene Softwarekatalog-Richtlinie kommt genau eine zusätzliche Checkbox:

> **ArtCraft-Anwendungen anbieten**

Technischer Wert: `EnableArtCraft` (DWORD) unter
`HKLM\Software\Policies\STL\Softwarekatalog`. Aktiviert = `1`, deaktiviert/nicht
konfiguriert = `0` (Opt-in, keine überraschende Erweiterung bestehender Kataloge).

- Aktiviert: die untenstehenden 14 Anwendungen werden eingeblendet. Keine
  zusätzlichen `Catalog`-Registrywerte und keine einzelnen ArtCraft-GPOs nötig.
- Eine Aktivierung installiert **nicht** automatisch alle 14 Anwendungen.
  Installation erfolgt über Benutzeranforderung oder die bestehende Pflichtliste.
- In der vorhandenen Liste **Verpflichtende Programme** werden die Kurznamen
  verwendet, beispielsweise `pdfcraft = 1`, `gridcraft = 1`, `wordcraft = 1`.
  Die vorhandenen Regeln `EnforceRequired`, Benutzerinstallation und
  Deinstallationssperre für Pflichtsoftware gelten weiterhin.
- Deaktivierung entfernt keine installierte Software. Neue eingebaute Angebote,
  Pflichtinstallationen und automatische ArtCraft-Provider-Updates stoppen;
  unaufgelöste Pflicht-Kurznamen erzeugen eine verständliche Konfigurationswarnung.
  Ein bereits begonnenes destruktives Reparaturvorhaben muss trotzdem sicher
  abgeschlossen bzw. als wiederaufnehmbar angezeigt werden, nicht verschwinden.
- Bestehende explizite GPO-Katalogzeilen bleiben ohne Opt-in aus
  Kompatibilitätsgründen beim bisherigen Verhalten. Die Checkbox ist keine
  globale Sperrliste für ausdrücklich anderweitig freigegebene Pakete.

Der übergeordnete Schalter `Enabled` bleibt Voraussetzung. Der neue Schalter
ändert keine Benutzerrechte und benötigt keine GitHub-Zugangsdaten.

## 2. Fester Anwendungskatalog

Kurznamen, IDs, Anzeigenamen und Beschreibungen entsprechen der Nutzervorgabe.
Das leere Zwischenfeld in den gelieferten `ID|Name||Beschreibung`-Zeilen wird
**nicht** Teil der Beschreibung. Die Einträge werden strukturierte Datensätze,
keine neu interpretierten GPO-Zeichenketten; das bestehende WinGet-Dreifeldformat
`ID|Name|Beschreibung` bleibt davon unberührt.

| Kurzname | Logische/alte WinGet-ID | Anzeigename | Beschreibung |
| --- | --- | --- | --- |
| photocraft | ArtCraft.PhotoCraft | PhotoCraft | Open-Source-Bildbearbeitung mit Ebenen, Masken und PSD-Unterstützung |
| vectorcraft | ArtCraft.VectorCraft | VectorCraft | Open-Source-Vektorgrafikeditor für Illustrationen und SVG-Dateien |
| filmcraft | ArtCraft.FilmCraft | FilmCraft | Open-Source-Videobearbeitung mit Zeitleiste, Effekten und Farbkorrektur |
| lightcraft | ArtCraft.LightCraft | LightCraft | Fotoverwaltung und RAW-Entwicklung mit nicht-destruktiver Bildbearbeitung |
| pdfcraft | ArtCraft.PdfCraft | PdfCraft | Open-Source-PDF-Editor zum Lesen, Zusammenfügen, Aufteilen und Organisieren von PDF-Dokumenten |
| effectcraft | ArtCraft.EffectCraft | EffectCraft | Open-Source-Software für Motion Graphics, Animationen und visuelle Effekte |
| designcraft | ArtCraft.DesignCraft | DesignCraft | Open-Source-Layoutprogramm für Desktop-Publishing und Druckdokumente |
| texturecraft | ArtCraft.TextureCraft | TextureCraft | Open-Source-Software zur Erstellung und Bearbeitung von 3D-Texturen |
| materialcraft | ArtCraft.MaterialCraft | MaterialCraft | Node-basierter Open-Source-Editor für prozedurale Materialien |
| wordcraft | ArtCraft.WordCraft | WordCraft | Open-Source-Textverarbeitung zum Erstellen und Bearbeiten von Dokumenten |
| soundcraft | ArtCraft.SoundCraft | SoundCraft | Open-Source-Audiosoftware für Aufnahme, Schnitt, Mixing und Musikproduktion |
| deckcraft | ArtCraft.DeckCraft | DeckCraft | Open-Source-Präsentationssoftware zum Erstellen und Vorführen von Folien |
| cadcraft | ArtCraft.CadCraft | CADCraft | Open-Source-CAD-Software für technische Zeichnungen und Konstruktionen |
| gridcraft | ArtCraft.GridCraft | GridCraft | Open-Source-Tabellenkalkulation für Datenanalyse und Berechnungen |

Die IDs bleiben stabile interne Identitäten und Migrationsschlüssel, auch wenn
WinGet für diese Anwendungen nicht mehr ausgeführt wird. Der feste Datensatz
enthält zusätzlich `Provider=ArtCraft`, das explizit erlaubte Hersteller-Repository,
MSI-UpgradeCode, Installationsprofil und erwartete Programmdatei.

### Alte Einträge und Konflikte

- Bei aktivierter Checkbox werden vorhandene Katalogzeilen mit einer der 14
  exakten ArtCraft-IDs dem neuen Provider zugeordnet und nach Paketidentität
  zusammengeführt. Es erscheint nur ein Angebot je Anwendung.
- Frühere abweichende Aliase, etwa `grid` für `ArtCraft.GridCraft`, bleiben als
  Kompatibilitätsalias für Requests/Pflichtsoftware gültig, solange die alte
  Freigabe vorhanden ist. Neue Konfiguration verwendet `gridcraft`.
- Die 14 kanonischen Kurznamen sind bei aktiviertem Provider reserviert. Eine
  kollidierende GPO-Zeile für ein anderes Produkt wird mit Warnung abgewiesen;
  sie darf die eingebaute Anwendung oder deren Downloadquelle nicht ersetzen.
- Alte Einträge müssen nicht vorab gelöscht werden. Es werden keine
  domänenverwalteten Registrywerte eigenmächtig umgeschrieben.
- Der bestehende Grenzwert von 500 individuellen Katalog-/Pflichteinträgen bleibt;
  die 14 eingebauten Angebote belegen keine dieser 500 GPO-Katalogzeilen.

## 3. Überprüfte Herstellerbasis

Am 2026-11-13 liefern **alle 14** offiziellen Repositories unter `storytold`
stabile Releases mit jeweils `*-windows-x64.msi` und `*-windows-arm64.msi`.
Die folgenden Versionen sind eine Rechercheaufnahme, **keine künftigen Pins**:

| Anwendung / geprüftes Release | MSI-Scope laut gepinnter WiX-Quelle | Stabiler UpgradeCode |
| --- | --- | --- |
| [photocraft 0.23.1](https://github.com/storytold/photocraft/releases/tag/v0.23.1) | perUserOrMachine | D9660F32-2D0A-4ABE-B73D-17BE25F1542C |
| [vectorcraft 0.24.1](https://github.com/storytold/vectorcraft/releases/tag/v0.24.1) | perUserOrMachine | 601C6437-08AE-4645-ADCC-27F036C2EA2F |
| [filmcraft 0.20.1](https://github.com/storytold/filmcraft/releases/tag/v0.20.1) | perUserOrMachine | 31E6FB14-9DBC-41DD-B24B-26B71FB31B62 |
| [lightcraft 0.21.1](https://github.com/storytold/lightcraft/releases/tag/v0.21.1) | perUserOrMachine | 229BB552-5EFD-479A-BA86-8CB6D926390C |
| [pdfcraft 0.21.1](https://github.com/storytold/pdfcraft/releases/tag/v0.21.1) | perUserOrMachine | EA00C367-7270-4C50-9D8B-A7A5C88AD27F |
| [effectcraft 0.24.1](https://github.com/storytold/effectcraft/releases/tag/v0.24.1) | perUserOrMachine | AACA8593-C6ED-40A8-BA6C-CB325D8529F9 |
| [designcraft 0.20.1](https://github.com/storytold/designcraft/releases/tag/v0.20.1) | perUserOrMachine | 49E87D30-BB68-4896-AA1D-F45C833CFC3C |
| [texturecraft 0.6.1](https://github.com/storytold/texturecraft/releases/tag/v0.6.1) | perMachine | 7E670E60-BB22-4E6B-8749-DD3FD4CA8979 |
| [materialcraft 0.4.1](https://github.com/storytold/materialcraft/releases/tag/v0.4.1) | perMachine | 89DE105E-B6C8-4261-ADBE-25BCFA3A0C91 |
| [wordcraft 0.18.1](https://github.com/storytold/wordcraft/releases/tag/v0.18.1) | perUserOrMachine | 075497F9-E861-45D0-9C7F-A74F8C34E6BA |
| [soundcraft 0.20.1](https://github.com/storytold/soundcraft/releases/tag/v0.20.1) | perUserOrMachine | EE53D3E5-D0AE-40F9-808D-9417FDEBF61A |
| [deckcraft 0.18.1](https://github.com/storytold/deckcraft/releases/tag/v0.18.1) | perUserOrMachine | 6F9C69E7-7825-40D2-BF26-C274DA676425 |
| [cadcraft 0.20.1](https://github.com/storytold/cadcraft/releases/tag/v0.20.1) | perUserOrMachine | 119D7D76-0167-4A9E-8F37-09DA0235F68E |
| [gridcraft 0.19.1](https://github.com/storytold/gridcraft/releases/tag/v0.19.1) | perUserOrMachine | 5511327B-F305-41BE-92D0-EB84944E7C4D |

Die UpgradeCodes und Scopes stammen jeweils aus
`https://github.com/storytold/<kurzname>/blob/v<version>/packaging/windows/<kurzname>.wxs`
am in der Tabelle verlinkten Tag. Sie sind Identitätsprüfungen, kein Ersatz für
eine kryptografische Prüfung des heruntergeladenen Installers.

**Wichtiger Unterschied:** TextureCraft und MaterialCraft haben am geprüften Tag
keine `install-policy.wxi`. Ihre reinen Maschineninstaller verwenden
`ProgramFiles6432Folder\TextureCraft` bzw. `...\MaterialCraft`, nicht pauschal
`Program Files\ArtCraft\...`. Die übrigen zwölf enthalten die gemeinsame
Dual-Context-Richtlinie unter `packaging/windows/install-policy.wxi` und verwenden
den ArtCraft-Unterordner. Diese Unterschiede gehören in feste Paketprofile.

Weitere geprüfte Quellen:

- [GridCraft Installationsrichtlinie 0.19.1](https://github.com/storytold/gridcraft/blob/v0.19.1/packaging/windows/INSTALLATION.md)
- [GridCraft Scope-/Ordnerlogik 0.19.1](https://github.com/storytold/gridcraft/blob/v0.19.1/packaging/windows/install-policy.wxi)
- [GridCraft Release-/Signierungsdokumentation](https://github.com/storytold/gridcraft/blob/v0.19.1/docs/releasing.md)
- [TextureCraft MSI-Quelle](https://github.com/storytold/texturecraft/blob/v0.6.1/packaging/windows/texturecraft.wxs)
- [MaterialCraft MSI-Quelle](https://github.com/storytold/materialcraft/blob/v0.4.1/packaging/windows/materialcraft.wxs)

Die Releases enthalten `SHA256SUMS.txt`, `SHA256SUMS.txt.asc` und SHA-256-Digests in
den GitHub-Asset-Metadaten. Hier wurden Metadaten und Textquellen geprüft, **keine
Installer ausgeführt und keine Signaturen der tatsächlichen MSI-Dateien geprüft**.
Die Herstellerdokumentation beschreibt Windows-Codesignierung, warnt aber auch
vor unsignierten lokalen Builds bei fehlenden Signierungszugängen.

## 4. Release-Auflösung und Downloadvertrauen

Empfehlung: Clients beziehen die vom Hersteller als **Latest** veröffentlichte
stabile Version direkt. Keine Nightlies, Entwürfe, Prereleases, `main`-Builds oder
automatischen Downgrades. „Neueste“ heißt neueste erfolgreich geprüfte stabile
Herstellerversion beim letzten erfolgreichen Abgleich, nicht Echtzeitgarantie.

1. Feste Repository-Allowlist aus dem eingebauten Katalog, keine Repository-
   oder Download-URLs aus Requests, GPO-Katalogtexten oder benutzerschreibbaren Daten.
2. Latest-Release bestimmen; Tag und exakten Assetnamen streng validieren:
   `<kurzname>-<version>-windows-<x64|arm64>.msi`. Danach Tag, Asset und Prüfsumme
   für den gesamten Vorgang einfrieren; keine weiteren veränderlichen
   `latest/download`-Aufrufe mitten in einer Installation.
3. Für größere Flotten bevorzugt den offiziellen HTTPS-Latest-Redirect mit
   taggebundener Prüfsummendatei verwenden, statt pro Rechner dauerhaft 14
   unauthentifizierte REST-Abfragen auszuführen. Die GitHub-REST-API bleibt eine
   mögliche Metadatenquelle, benötigt aber Rate-Limit-/Backoff-Behandlung.
   Redirect-Ziel muss beim erwarteten Repository/Release bleiben; anschließend
   gelten feste erlaubte GitHub-Asset-Hosts, HTTPS und eine begrenzte Redirectzahl.
4. Nur das benötigte MSI herunterladen, nicht vorsorglich alle 28 Plattformpakete.
   Download in geschützten Cache, atomare Fertigstellung, Zeit-/Größenlimits,
   SHA-256 gegen die exakt zum Tag gehörende Prüfsummenzeile prüfen.
5. Vor Ausführung zusätzlich Windows-Authenticode-Vertrauen und freigegebene
   Hersteller-Signeridentität prüfen. Nur „irgendeine gültige Signatur“ genügt
   nicht. Die erlaubte Identität/Rotation muss anhand echter Release-MSIs unter
   Windows vor Freigabe ermittelt werden; hier wird kein Zertifikat erfunden.
   Unsignierte/unvertrauenswürdige Dateien werden nicht stillschweigend zugelassen.
   Eine spätere OpenPGP-Prüfung der `.asc` wäre zusätzliche Absicherung, benötigt
   aber einen unabhängig geprüften, gepinnten Schlüssel und verifizierten Prüfer.
6. MSI read-only inspizieren: UpgradeCode, Produktversion, erwartete Produktfamilie
   und SummaryInformation-Architektur müssen zum fest eingebauten Profil passen.
   Fehlende/mehrdeutige Assets, Hash-/Signaturfehler und geänderte MSI-Identität
   sind Fehler, kein Anlass zum WinGet- oder EXE-Fallback.

HTTP-Metadaten werden zentral im geschützten Clientzustand mit Prüfzeit gespeichert;
die GUI macht keine eigenen 14 Netzabfragen. Abgleich im bestehenden zweistündlichen
Updatezyklus mit Jitter, explizite Installationen prüfen die Frische erneut.
Timeouts, 403/429/5xx und Offlinebetrieb erhalten den letzten bekannten Zustand,
zeigen aber „Versionsstand nicht aktuell geprüft“ statt „alles aktuell“.
Bereits verifizierter Cache darf nach erneuter Integritäts-/Vertrauensprüfung
weiterverwendet werden; ohne brauchbaren Installer keine Bestandsdeinstallation.
Ein zentraler Caching-Proxy ist eine spätere Flottenoptimierung, kein benötigter
neuer Server und kein PAT auf Clients.

## 5. Systemweite Installation, Bestand und ARM64

Ausführung weiterhin ausschließlich im privilegierten Worker unter SYSTEM,
serialisiert mit den vorhandenen Queue-/Installer-Sperren. Für geprüfte MSI-Profile:

```text
msiexec.exe /i "<geprüftes-msi>" ALLUSERS=1 /qn /norestart /L*v "<geschütztes-log>"
```

Bei Dual-Context-Paketen darf `MSIINSTALLPERUSER=1` nicht übernommen werden.
Ein explizites `INSTALLFOLDER` darf nur aus dem festen, architekturrichtigen Profil
kommen, nie aus Benutzerinput. Ein gesunder bestehender Maschinenpfad bleibt bei
normalen Updates erhalten; TextureCraft/MaterialCraft behalten ihre eigenen Pfade.
Erfolg erfordert Maschinenregistrierung, passende Version/Architektur und die
erwartete Programmdatei außerhalb von Benutzer- und SYSTEM-AppData.
Exitcodes 0/3010 werden unterschieden (Erfolg / Erfolg mit Neustartbedarf),
1641 als unerwartet ausgelöster Neustart ausdrücklich behandelt und 1618 begrenzt
neu versucht; ein MSI-Erfolgscode allein beweist keine korrekte Installation.

Inventar aus Registry32/64 und den bestehenden nativen MSI-Hilfen, identifiziert
über die festen UpgradeCodes und tatsächliche Produktregistrierungen. Nicht allein
über Anzeigenamen, `winget export`, Verzeichnisexistenz oder `Win32_Product`.

Bestandsfälle:

| Bestand | Geplantes Verhalten |
| --- | --- |
| Gesundes älteres Maschinen-MSI, bisher von WinGet installiert | In neuen Provider übernehmen, normales MSI-Upgrade; keine unnötige Deinstallation |
| Gleiche oder neuere gesunde Maschinenversion | Kein Downgrade und keine Neuinstallation nur wegen Providerwechsel |
| Nachgewiesene falsche Installation im SYSTEM-AppData | Verifiziertes Ziel-MSI zuerst laden; Reparaturjournal schreiben; exakten registrierten Produkt-/Scope-Kontext deinstallieren; systemweit installieren und nachprüfen |
| Mehrdeutige Registrierung/fehlende Identität | Blockieren und diagnostizieren, keine beliebigen Registry-Uninstall-Befehle ausführen |
| Normale Benutzerinstallation eines anderen Kontos | Nicht automatisch entfernen oder dessen Profil manipulieren; Konflikt melden |
| Abbruch nach Deinstallation | Eingefrorenen Installer und Reparaturabsicht behalten, beim nächsten Worker fortsetzen |
| x64-Maschineninstallation auf ARM64 | Kontrollierter Architekturwechsel nur mit verifiziertem nativem Ziel und vorab geprüftem Migrationsprofil; nicht als gewöhnliches blindes In-place-Upgrade behandeln |

Ordner werden nicht als Deinstallationsersatz gelöscht. Die bestehende abgesicherte
MSI-Komponentenpfaderkennung und das Reparaturjournal werden auf die 14 verifizierten
Profile erweitert, nicht durch pauschales Erkennen von `ArtCraft.*` ersetzt.

Architekturauswahl über die **native OS-Architektur**, nicht die Bitness der
aufrufenden PowerShell: ARM64 nimmt das ARM64-MSI, x64 das x64-MSI. Eine x86-PS auf
x64 darf kein x86-Paket auswählen. Fehlendes natives Asset meldet „nicht verfügbar“;
kein stiller x64-Emulationsfallback auf ARM und kein erfundenes Windows-x86-Paket.

## 6. Notwendige Umbauten im bestehenden Code

1. **Gemeinsame Katalogdefinition:** `Get-AppCatalogObjects` und die beiden
   generierten Varianten in `New-UserRequestTool`/`New-CatalogGui` müssen dieselbe
   unveränderliche ArtCraft-Liste und dieselben Merge-Regeln erhalten. Kein dreifach
   von Hand gepflegter Satz aus Beschreibungen/URLs.
2. **Provider-Dispatch:** interne Install-/Uninstall-/Inventar-/Update-Funktionen
   wählen zwischen WinGet und ArtCraft. `Source` der Queue bleibt Herkunft
   (User/Required/System), nicht Provider. Der Worker löst Alias und erlaubten
   Provider vor Ausführung erneut aus der aktuellen Richtlinie auf. Requests
   können weder Provider noch Version, MSI-Argumente oder Downloadziel bestimmen.
3. **WinGet darf keine Voraussetzung für ArtCraft sein:** derzeit sind
   Verfügbarkeit, Snapshot und Worker stark an WinGet gekoppelt. ArtCraft-Aufträge
   müssen auch ohne WinGet verarbeitet werden können. Ein WinGet-Ausfall darf
   das unabhängig ermittelte ArtCraft-Inventar nicht löschen oder blockieren.
4. **Providerunabhängiger Snapshot:** installierte Version, Architektur, Scope,
   Herkunft/Provider, letzte Versionsprüfung und Zielversion ergänzen. Die bisherige
   ID-Liste bleibt kompatibel; ArtCraft-Daten kommen aus realem MSI-Inventar,
   nicht aus veralteten WinGet-Manifests. Fehlgeschlagene Reparaturen sind nicht
   „gesund installiert“. Zustände werden atomar und mit bisherigen ACLs gespeichert.
5. **Keine konkurrierenden Updates:** `Invoke-WingetUpgradeAll` verwendet aktuell
   `winget upgrade --all`. Das muss für Providertrennung durch explizite
   Einzel-Upgrades der übrigen inventarisierten WinGet-Pakete ersetzt werden;
   nicht nur die Queue filtern und anschließend doch `--all` ausführen.
   ArtCraft-Pakete bei aktiviertem Provider ausschließen. Dauerhaft protokollierte
   ArtCraft-Übernahmen bleiben auch nach Deaktivierung vor einem unbeabsichtigten
   WinGet-Rückwechsel geschützt. Keine globalen WinGet-Pins/Benutzereinstellungen.
   Alte, nie übernommene explizite WinGet-Konfigurationen bleiben kompatibel.
6. **GPO/Oberfläche:** eine ADMX-Boolean-Definition und Checkbox/Hilfetexte in beiden
   ADML-Sprachen, interne Katalog-IDs ohne neue GPO-Zeilen, vorhandene Required-Liste,
   verständliche Versions-/Fehler-/Neustartanzeigen. Der vorhandene Zeitplan kann
   beide Provider im selben Worker abarbeiten; keine zweite konkurrierende Task.

## 7. Umsetzung und Abnahmekriterien

In drei getrennten, überprüfbaren Schritten umsetzen:

1. Eingebauter Katalog, Merge-/Aliasregeln, Checkbox, Required-Verhalten und
   Provider-Schnittstelle. Noch keine ungeprüften Herstellerdownloads ausführen.
2. Release-Auflösung, sicherer Downloader, MSI-Inventar/Installation/Migration,
   providerunabhängiger Snapshot und sauber getrennte Updateausführung.
3. Native Windows-/ARM64-Integration, gezielte Hersteller-Smokes und dokumentierter
   Pilot; erst danach produktiv freigeben.

Die bestehende CI-Matrix bleibt verbindlich. Erweiterungen:

- Exakt 14 Datensätze, exakte deutsche Beschreibungen, IDs/Anzeigenamen,
  keine führenden `|`, keine Duplikate; Gleichheit von Worker/Helper/GUI.
- Checkbox an/aus/fehlend, global deaktiviert, gemischter Katalog, 500-Einträge-
  Grenze, Alias-/ID-Kollisionen, alte Aliase, Required nur über Kurzname und
  Required-Deinstallationssperre ohne einzelne ArtCraft-Katalogwerte.
- Deterministische Release-/HTTP-Fixtures: stabile Version, Prerelease, ungültiger
  Tag, fehlendes/doppeltes Asset, Rate-Limit, Timeout, Redirect auf fremdes Ziel,
  abgeschnittener Download, Hash-/Signer-/MSI-Identitätsfehler, Cache und Offlinefall.
- Höhere installierte Version wird nicht heruntergestuft; Providerwechsel ohne
  Neuinstallation; keine ArtCraft-ID im WinGet-Upgrade; kein verbliebenes `--all`;
  deaktivierter Provider ohne Rückfall auf WinGet; ArtCraft funktioniert ohne WinGet.
- Reale kleine Fixture-MSIs mit beiden Packaging-Modellen, x64 und ARM64:
  frische Maschineninstallation, gesundes Upgrade, SYSTEM-AppData-Migration,
  Neustartbedarf, Fehler vor/nach Deinstallation, Journal-Wiederaufnahme,
  Architekturwechsel und Zugriff eines echten zweiten Standardbenutzers.
- Downloads/Providerzustand genauso wenig benutzerschreibbar wie Skript/Queue;
  keine durch Request-Metadaten eingeschleusten Quellen, Argumente oder Identitäten.
- Separater geplanter/manueller Hersteller-Smoke: Metadaten aller 14 Releases,
  echte Hash-/Authenticode-/MSI-Prüfung und Installer-Lifecycle auf wegwerfbaren
  x64-/ARM64-VMs. Nicht jeden PR von allen aktuellen Fremd-Releases abhängig machen.

**Noch zu verifizieren, nicht als erledigt behauptet:** tatsächliche akzeptierte
Windows-Signeridentität und deren Rotation, reale aktuelle Installer-Lifecycles
aller 14 Anwendungen, tatsächlicher x64-zu-ARM64-Wechsel sowie Herstellerverhalten
bei künftigen Paketformat-/UpgradeCode-Änderungen. Fehlende Vertrauensnachweise
blockieren die betroffene Installation statt einen unsicheren Fallback zu aktivieren.
