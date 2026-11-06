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
