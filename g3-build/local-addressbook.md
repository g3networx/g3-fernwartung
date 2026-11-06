# g3.6.1 Build 061126 — lokales Fullclient-Adressbuch

Der Fullclient bietet zusätzlich zum unveränderten g3-Adressbuch einen Reiter
„Lokales Adressbuch“. Name, Geräte-ID, Gruppe und Notiz liegen ausschließlich
unter `%LOCALAPPDATA%/g3NetworX/Fernwartung/local-addressbook-v1.json` im jeweiligen
Windows-Benutzerprofil. Der Reiter ist ohne Serveranmeldung verfügbar. Die
Speicherkomponente verwendet keine Server-API; Kennwörter und Anmeldetokens
gehören nicht zum Dateiformat. Verbindungen verwenden den bisherigen nativen
Desktop-/Dateiverbindungsweg und dessen Kennwortdialog.

Einträge lassen sich anlegen, bearbeiten, löschen und durchsuchen. Export und
Import verwenden UTF-8-JSON mit `format: "g3-local-addressbook"`, `version: 1`
und `entries` mit `id`, `name`, `group`, `notes`. Der Import wird vor dem Schreiben
vollständig validiert und bestätigt; bereits vorhandene IDs werden übersprungen.
Beschädigte bestehende Dateien werden nicht überschrieben. Limit: 2 MB und
5.000 Einträge. Aktualisierungen erfolgen mit Dateisperre und atomarem Austausch.

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
