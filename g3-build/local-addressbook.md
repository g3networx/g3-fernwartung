# g3.6.1 Build 061126 — lokales Fullclient-Adressbuch

Der Fullclient bietet zusätzlich zum unveränderten g3-Adressbuch einen Reiter
„Lokales Adressbuch“. Name, Geräte-ID, Gruppe und Notiz liegen ausschließlich
unter `%LOCALAPPDATA%/g3NetworX/Fernwartung/local-addressbook-v1.json` im jeweiligen
Windows-Benutzerprofil. Der Reiter ist ohne Serveranmeldung verfügbar. Die
Speicherkomponente verwendet keine Server-API. Verbindungskennwörter werden mit
Windows-DPAPI im Benutzerkontext verschlüsselt und zusätzlich an die Geräte-ID
gebunden. Anmeldetokens gehören nicht zum Dateiformat. Gespeicherte Kennwörter
werden erst beim Verbindungsstart entschlüsselt und an den bestehenden nativen
Desktop-/Dateiverbindungsweg übergeben. Ein leeres Kennwort verwendet dessen
bisherigen Kennwortdialog.

Einträge lassen sich anlegen, bearbeiten, löschen und durchsuchen. Export und
Import verwenden einen vollständig verschlüsselten UTF-8-JSON-Container mit
`format: "g3-local-addressbook-encrypted"`, `version: 1`, AES-256-GCM und
PBKDF2-HMAC-SHA256 (600.000 Iterationen, zufälliges 16-Byte-Salt und 12-Byte-Nonce).
Das frei gewählte Exportkennwort (mindestens 12 Zeichen, Bestätigung erforderlich)
wird bei jedem Import dieser Datei benötigt. Der Schlüssel wird nicht gespeichert.
Die Entschlüsselung und Schlüsselableitung laufen außerhalb des UI-Isolates;
Kennwörter und unverschlüsselte Transferdaten werden nicht in temporäre Dateien
geschrieben. Falsche Kennwörter und manipulierte Dateien brechen vor dem Import ab.
Beim Import werden die Verbindungskennwörter für den aktuellen Windows-Benutzer
neu mit DPAPI verschlüsselt. Der Import wird vor dem Schreiben vollständig
validiert und bestätigt; bereits vorhandene IDs samt Kennwörtern bleiben erhalten.
Die lokale Datei bleibt am bisherigen Pfad, verwendet aber Formatversion 2 mit
dem verschlüsselten Feld `passwordProtected`. Vorhandene Version-1-Daten und alte
Version-1-Exporte ohne Kennwörter bleiben lesbar. Rohdateien mit lokalen
DPAPI-Kennwörtern sind keine portablen Exporte.
Beschädigte bestehende Dateien werden nicht überschrieben. Limit: 2 MB und
5.000 Einträge lokal beziehungsweise 4 MB für verschlüsselte Exportdateien.
Aktualisierungen erfolgen mit Dateisperre und atomarem Austausch.
Ohne Exportkennwort ist keine Wiederherstellung des Exports möglich.

Technische Grundlagen: [DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata),
[cryptography 2.7.0](https://pub.dev/packages/cryptography/versions/2.7.0).
Die zusätzliche, fest gepinnte Abhängigkeit wird für portable, authentifizierte
Exportverschlüsselung verwendet; keine eigene AES-/KDF-Implementierung.

## Build

Die neue Versionsquelle ist `g3-build/local-addressbook-release.json`:
`1.5.0-g3.61.20008`, Windows `1.61.20008`, Anzeige `g3.6.1 Build 061126`.
In der bestehenden, vorbereiteten Windows-Releaseumgebung (einschließlich der
geprüften Vorgängerarchive und Installerwerkzeuge) nacheinander ausführen:

1. `g3-build/build-local-addressbook-core.ps1`
2. `g3-build/build-local-addressbook-ui.ps1`
3. `python g3-build/package-local-addressbook.py package`

Der native Build übernimmt die vorhandenen Core- und Sitzungsschutztests mit
neuer Versionskennung. Die bisherigen Releaseabläufe und veröffentlichten
Pakete bleiben unverändert. Veröffentlichung und Rollout sind eigene Schritte.

Die Setup-EXE ist ein Download-Bootstrapper: Sie lädt auch dann das MSI über
`https://rust.g3nx.net/client/releases/<Version>/windows_msi`, wenn eine MSI-Datei
neben ihr liegt. Vor Übergabe eines normal startbaren Installers müssen die
signierten Pakete und das versionsgebundene Manifest veröffentlicht und über
die öffentlichen Servernamen mit Größen-/SHA256-Prüfung abgerufen werden.
Das Kopieren beider Dateien in denselben Ordner ersetzt diesen Schritt nicht.

## Bestehende betroffene Pfade

- `flutter/lib/desktop/pages/connection_page.dart`: nur im bestehenden
  Fullclient-Zweig wird das lokale Adressbuch neben dem Server-Adressbuch
  eingebunden. Desktop/Dateiexplorer verwenden `connect` unverändert.
- `flutter/lib/g3_update_check.dart`: Versionsvorgaben und sichtbare Bezeichnung
  für g3.6.1; g3.6 und ältere Versionsvergleiche behalten ihr Verhalten.
- `flutter/test/g3_version_display_test.dart`: zusätzlicher Versionsnachweis.

Alle übrigen Funktionsänderungen befinden sich in neuen Featuredateien. Die
Server-API, zentrale Adressbuchdaten, native Authentifizierung und Host-Ansicht
werden nicht umgebaut.

## Erweiterung vom 07.11.2026: lokale Unteradressbücher und Kopien

Entwicklungsstand, noch kein neu gebautes oder veröffentlichtes Releasepaket.

- Lokale Unteradressbücher werden über „Unteradressbuch“ angelegt. Die
  Zielauswahl unterstützt bis zu acht Ebenen und 500 Adressbücher. Leere
  Adressbücher bleiben gespeichert und können gelöscht werden, sofern sie
  keine Einträge oder Unteradressbücher enthalten.
- Einträge erhalten ein optionales `book`-Pfadfeld. Beim Bearbeiten kann das
  Zieladressbuch geändert werden; bestehende Gruppen und Kennwörter bleiben
  erhalten. Die Ansicht bietet alle Einträge, die oberste Ebene und einzelne
  Unteradressbücher an.
- Die lokale Datei verwendet Version 3, sobald Adressbuchpfade vorkommen;
  Versionen 1 und 2 bleiben lesbar. Ohne Unteradressbücher bleibt das bisherige
  Version-2-Format bestehen. Ältere Clients können Version 3 nicht lesen und
  weisen sie zurück, ohne sie zu überschreiben.
- Der kennwortgeschützte Export transportiert auch leere Unteradressbücher
  (inneres Transferformat Version 2). Ältere Transferdateien bleiben lesbar.
  DPAPI und die bestehende authentifizierte Exportverschlüsselung bleiben
  erhalten.
- „In lokales Adressbuch kopieren“ übernimmt Name und Geräte-ID des sichtbaren
  öffentlichen Eintrags in ein gewähltes lokales Ziel. Auch reine Leserechte
  genügen. Serverkennwörter und Freigabetokens werden nicht übernommen; ein
  eigenes Verbindungskennwort kann im Kopierdialog eingegeben werden.
  Doppelte Geräte-IDs werden abgewiesen. Der öffentliche Eintrag wird nicht
  verändert. Beim Wechsel zum lokalen Reiter wird dessen Inhalt neu geladen.

Regression-Surface-Prüfung: `g3_local_addressbook_store.dart` erweitert nur die
lokale Persistenz und den lokalen Transfer um Adressbuchpfade;
`g3_local_addressbook.dart` ergänzt deren Verwaltung/Zielauswahl und aktualisiert
den lokalen Reiter; `g3_addressbook.dart` ergänzt die lokale Kopieraktion in der
Gerätedetailansicht. Der neue Kopierdialog liegt separat in
`g3_local_addressbook_copy.dart`. Die Änderungen an beiden vorhandenen
Adressbuch-Testdateien prüfen diese Bedienwege. Keine Änderungen an nativer
Verbindung, Server-API, Update- oder Installerpfaden.

Validierung: 18 Adressbuch-/Kryptografie-/Widgettests erfolgreich; gezielte
Dart-Analyse aller sechs betroffenen Dart-Dateien ohne Befund. Die drei neuen
Tests prüfen verschachtelte/leere Adressbücher samt Kennworttransfer, lokale
Ansicht/Neuanlage und öffentliches Kopieren ohne Servermutation/Überschreiben.

## Icon-Korrektur, Build 091126

Die bisherige Tray-ICO enthielt ein anderes Motiv als die EXE-Ressource.
Beide enthalten jetzt dieselbe genehmigte Grafik einschließlich aller
Windows-Größen. `generate-app-icon.py` hält beide Dateien künftig zusammen;
`check-windows-icons.py` prüft dies vor jedem Release-Build.

`src/core_main.rs` lässt den Windows-g3-Tray durch den bereits vorhandenen
Sitzungsmutex entscheiden, ob er starten darf. Die vorgelagerte Prozesssuche
kann dessen Entscheidung nicht mehr verhindern. Andere Plattformen und
Produktnamen behalten ihren bisherigen Startpfad.

`flutter/windows/runner/main.cpp` setzt vor dem ersten Fenster eine feste
AppUserModelID je g3-Produkt; die Vorschau erhält eine eigene ID. Die
Startmenü-Verknüpfung aus `package-msi.py` erhält dieselbe Eigenschaft.
`CMakeLists.txt` verknüpft dafür shell32. Der MSI-Inhaltsprüfer liest die
tatsächlich erzeugte MsiShortcutProperty-Tabelle und prüft die Produkt-ID.
Grundlage: https://learn.microsoft.com/en-us/windows/win32/shell/appids

Dies sind die bestehenden Laufzeit-/Paketpfade der Korrektur. Weitere Änderungen
sind die neue Versionskennung, der Vorversionshash 081126 und der Release-Workflow.
Die Update-Freigabe muss nach der Veröffentlichung aktuelle, passende Metadaten
in `current.json` und `downloads.json` verwenden; eine Versionsroute allein
veröffentlicht kein Angebot für den eingebauten Update-Button.

## Einheitlicher Download-Stand im Cluster

`g3-build/cluster-release-sync/assets-pull.sh` ist der geprüfte Download-Sync.
Der Standby übernimmt neue Pakete und wählt den Katalog erst nach Größen-/SHA256-
Prüfung aller Referenzen. Bereits freigegebene neuere Client- oder Plattform-
Versionen dürfen durch einen älteren Peer-Katalog nicht zurückgestuft werden.
Gleich benannte Versionen mit abweichenden Paketen werden ebenfalls abgewiesen.
Ein inzwischen aktiver Schreibknoten übernimmt keine Peer-Auswahl.

Aktive Installation auf beiden Servern:
`/usr/local/lib/opslinx-release-sync/assets-pull.sh`, eingebunden durch
`/etc/systemd/system/opslinx-ha-assets.service.d/30-release-monotonic.conf`.
Der bestehende Sync-Timer bleibt zuständig; ein Austausch des älteren Scripts
unter `/usr/local/sbin` überschreibt diese Einbindung nicht. Für weitere
Änderungen an der Auswahl verwenden Veröffentlichung und Sync gemeinsam
`/opt/opslinx-ha/assets.lock`. Die Veröffentlichung prüft anschließend beide
Knoten sowie die HA-Adresse gegen dieselben Paket-Prüfsummen.

Regressionen: gültiges Upgrade mit geprüften Paketen, abgewiesener Altstand,
abgewiesene Paketbeschädigung und keine Übernahme nach Aktivierung des Writers.
Die drei Tests laufen mit temporären Verzeichnissen und ändern keine echten
Release-Auswahldateien. Client-Installationen erfolgen gemäß Projektvorgabe
ausschließlich über die Update-Funktion der Software.
