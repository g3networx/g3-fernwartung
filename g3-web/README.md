# FullClient-Adressbuch

Separater nativer API-Vertrag für das vorhandene g3-Webadressbuch. Die bestehende Anmeldung, zentrale Identitätsprüfung, Kundenhierarchie, Rechteprüfung und einmalige Verbindungsfreigabe bleiben maßgeblich.

## Anmeldung

Der FullClient erzeugt einen kryptografischen PKCE-Verifier und fordert eine zehn Minuten gültige Anmeldung an. Im Systembrowser wird die vorhandene g3-Anmeldung verwendet. Der Benutzer vergleicht den angezeigten Bestätigungscode und gibt seinen eigenen Client ausdrücklich frei. Nur der Client mit Device-Code und passendem Verifier kann die Freigabe einmalig einlösen. Passwort und OTP werden nicht im Client gespeichert.

„Angemeldet bleiben“ speichert ausschließlich den widerrufbaren nativen Sitzungstoken in der Windows-Anmeldeinformationsverwaltung des aktuellen Windows-Benutzers. Andere Plattformen behalten die Anmeldung nur im Arbeitsspeicher. Maximale native Laufzeit 30 Tage, maximale Inaktivität sieben Tage; Ablauf oder Widerruf der zentralen g3-Sitzung begrenzt die Laufzeit zusätzlich. Abmelden löscht die native Server-Sitzung und den lokalen Vault-Eintrag. Eine native Abmeldung meldet den Browser nicht ebenfalls ab.

## Rechte und Verbindung

`GET /client-addressbook/tree` liefert nur aktuell sichtbare Kunden und Geräte, ohne Gerätepasswörter. Die Präsenz kommt aus dem bestehenden Cache; veraltete Daten werden als unbekannt angezeigt. `POST /client-addressbook/connect` prüft erneut die aktuellen Geräte-Rechte und nutzt `CLIENT_CONNECT`: Ohne Enthüllungsrecht erfolgt ein normaler Verbindungsstart ohne mitgeliefertes Passwort; mit Recht kann der bestehende kurzlebige Einmal-Handoff verwendet werden. Auch dessen Einlösung prüft das Recht erneut. Es werden keine Passwörter über Kommandozeilen oder URI-Parameter transportiert.

Native POST-Endpunkte verlangen JSON, `X-G3-Native: 1` und keinen Browser-Origin. Geschützte Daten und Aktionen benötigen zusätzlich den Bearer-Token. Die Browser-Freigabe behält die normale Cookie-Anmeldung und CSRF-Prüfung. Es werden keine CORS-Freigaben hinzugefügt.

## Integration und Regression-Surface

- `native_addressbook.py` neben dem bestehenden `app.py`, Template unter `templates/native_addressbook.html` ablegen. `app-integration.patch` enthält die drei notwendigen Hooks: Modulinstallation, gezielte Ausnahmen für die anders authentifizierten nativen JSON-POSTs und Erhaltung nativer Sitzungen bei der normalen Browser-Idle-Bereinigung. Die normale Browser-Sitzungsdauer wird nicht verlängert.
- Initialisierung legt nur zwei zusätzliche Tabellen an. Keine vorhandenen Konten, Rechte, Geräte-IDs oder Kennwörter werden verändert.
- `connection_page.dart` ersetzt den bisher leeren Bereich nur bei App-Name `g3Fernwartung` und nicht eingehendem Hostmodus durch das neue Widget.
- `main.dart` setzt nur für denselben FullClient eine Mindestgröße von 820×620 und bei noch nicht gespeicherter Fensterposition eine Anfangsgröße von 1080×780. Vorhandene Fensterpositionen und die bestehende Skalierbarkeit bleiben erhalten.
- Alle neue Clientlogik liegt in drei eigenen Dart-Modulen. Keine Änderungen am Rust-Dienst, IPC, nativen DLL oder Host-Paket. Host und Soforthilfe nehmen die bisherigen UI-Pfade.

## Prüfung und Freigabe

`test_native_addressbook.py` ist ein Integrationstest mit der tatsächlichen Web-App in einer temporären Datenbank. Keine Tests mit Produktionskonten oder echten Registrierungscodes. Die Fluttertests prüfen Baum/Suche/Details/Verbindungsstart, schmales Layout, Abmeldung/Widerruf sowie getrennt einen vollständig entfernten Testeintrag im tatsächlichen Windows-Vault. Vor einer regulären Veröffentlichung ist zusätzlich ein echter Benutzer-Anmelde- und Verbindungsdurchlauf aus dem Kandidaten erforderlich. Der separate Vorschau-Build ersetzt keinen veröffentlichten g3.29-Download.
