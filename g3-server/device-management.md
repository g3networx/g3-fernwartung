# Geräteverwaltung im Labor

Der Portalcode verwendet die vorhandene Anmeldung, die Gerätezuordnung und den Audit-Verlauf. `DEVICE_MANAGEMENT_ENABLED` schaltet die Funktion in einer Laborinstanz frei. Die Aktion für ausgehende Verbindungen gilt für die zugewiesene native Geräte-ID. Eingehende Fernwartung läuft über den vorhandenen Verbindungsweg.

## Portal-Anbindung

Das Hauptmodul unter `/opt/rustdesk-addressbook` registriert `device_management.install(app, portal)` vor dem Aufruf von `portal.init()`. Das Modul legt seine Tabellen über dieselbe Initialisierung an wie die übrigen Portal-Erweiterungen. Die Geräteansicht kann zur Route `/devices/<did>/management` verlinken. Die Route überprüft die Admin-Rolle und prüft die Formularanfragen per CSRF-Token.

Nach erfolgreicher Ed25519-Prüfung setzt `client-bootstrap` weiterhin `g.verified_device_id`. Im Zweig für `credential_policy == 2` ergänzt der Handler seine bisherige Antwort vor dem Senden:

```python
management = app.config.get("DEVICE_MANAGEMENT_BOOTSTRAP_RESPONSE")
if management:
    result = management(data, d["id"], rid, pk, result)
return result
```

Der installierte Windows-Dienst speichert die Sperrvorgabe im maschinenweiten Registrierungszweig. Der Vollclient prüft sie vor dem Aufbau jeder neuen ausgehenden Verbindung. Bei vorübergehend fehlender Serverantwort verwendet er die zuletzt bestätigte Vorgabe.

## Auftragsausführung

Die Oberfläche erfasst und protokolliert Update- und Deinstallationsaufträge. Der Windows-Installer enthält einen Deinstallations-Worker für das eigene registrierte MSI. Er verlangt SYSTEM-Rechte und dieselbe exklusive Sitzungssperre wie ein Update. Er gibt bei belegter Sperre oder unbekanntem installiertem Build Code 1618 zurück.

Der Update-Button im Vollclient und die manuelle Installation über den signierten Installer bleiben auch bei aktiver Sperre für ausgehende Fernsteuerung verfügbar. Lokale und zentrale Aufträge verwenden dieselbe Installations- und Sitzungssperre.

Für die nächste Laborstufe fehlen die Zustellung der Aufträge an den Windows-Dienst und seine Rückmeldung an das Portal. Die Zustellung muss die verifizierte Installation erneut prüfen. Der Laborversuch soll zuerst während einer laufenden Sitzung eine Zurückstellung nachweisen und anschließend den Abschluss des Auftrags prüfen.
