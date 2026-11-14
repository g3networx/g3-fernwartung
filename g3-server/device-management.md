# Geräteverwaltung im Labor

Der Portalcode verwendet die vorhandene Anmeldung, die Gerätezuordnung und den Audit-Verlauf. `DEVICE_MANAGEMENT_ENABLED` schaltet die Funktion in einer Laborinstanz frei. Die Aktion für ausgehende Verbindungen gilt für die zugewiesene native Geräte-ID. Eingehende Fernwartung läuft über den vorhandenen Verbindungsweg.

## Portal-Anbindung

`python prepare-device-management.py /pfad/zur/portal-kopie` bindet das Modul in einer Staging-Kopie ein. `OPSLINX_DEVICE_MANAGEMENT=1` aktiviert die Geräteverwaltung beim Start des Portals. Die HA-Knoten verwenden denselben bestehenden Flask-Sitzungsschlüssel, damit ein erneut abgefragter Auftrag dieselbe Quittung erhält.

Das Hauptmodul unter `/opt/rustdesk-addressbook` registriert `device_management.install(app, portal)` vor dem Aufruf von `portal.init()`. Das Modul legt seine Tabellen über dieselbe Initialisierung an wie die übrigen Portal-Erweiterungen. Admins öffnen die Geräteverwaltung über „Weitere Optionen“ am Gerät. Die Route überprüft die Admin-Rolle und prüft die Formularanfragen per CSRF-Token.

Nach erfolgreicher Ed25519-Prüfung setzt `client-bootstrap` weiterhin `g.verified_device_id`. Im Zweig für `credential_policy == 2` ergänzt der Handler seine bisherige Antwort vor dem Senden:

```python
management = app.config.get("DEVICE_MANAGEMENT_BOOTSTRAP_RESPONSE")
if management:
    result = management(data, d["id"], rid, pk, result)
return result
```

Der installierte Windows-Dienst speichert Sperrstatus und Revision in einem maschinenweiten Registrierungszweig, den Standardbenutzer lesen können. Die Zugangsschlüssel bleiben im geschützten Bereich. Der Vollclient prüft die Sperre vor jeder neuen ausgehenden Verbindung. Bei vorübergehend fehlender Serverantwort verwendet er die zuletzt bestätigte Vorgabe. Die Sperre setzt einen Client voraus, der diese Prüfung unterstützt.

## Auftragsausführung

Die Oberfläche erfasst und protokolliert Update- und Deinstallationsaufträge. Der Windows-Installer enthält einen Deinstallations-Worker für das eigene registrierte MSI. Er verlangt SYSTEM-Rechte und dieselbe exklusive Sitzungssperre wie ein Update. Er gibt bei belegter Sperre oder unbekanntem installiertem Build Code 1618 zurück.

Der Update-Button im Vollclient und die manuelle Installation über den signierten Installer bleiben auch bei aktiver Sperre für ausgehende Fernsteuerung verfügbar. Lokale und zentrale Aufträge verwenden dieselbe Installations- und Sitzungssperre.

Das Portal stellt Aufträge der verifizierten Installation zu, sobald deren Windows-Dienst Bereitschaft meldet und keine aktuelle Sitzung erfasst ist. Die Deinstallation muss für die Portalinstanz aktiviert sein, setzt einen kompatiblen Dienst voraus und erfordert eine ausdrückliche Bestätigung im Portal. Der Dienst startet den Installationshelfer, der den Launcher des installierten Builds gegen die integrierte OpsLinX-CA prüft. Ein Update prüft zusätzlich die MSI-Datei. Die lokale Sitzungssperre schützt auch laufende Verbindungen, die das Portal noch nicht erfasst hat.

Bei Code 1618 bleibt der Auftrag vorgemerkt. Der Updatehelfer speichert das Installationsergebnis vor der Rückmeldung. Bei einem Verbindungsfehler kann der Windows-Dienst die Rückmeldung beim nächsten Durchlauf erneut anstoßen. Nach erfolgreicher Deinstallation übernimmt der Helfer die Rückmeldung, da der Dienst bereits entfernt ist.
