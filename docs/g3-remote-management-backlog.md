# Späteres Zusatzfeature: Remote-Verwaltung

Vom Nutzer am 24.10.2026 als späteres Projektfeature vorgemerkt. Kein Bestandteil des aktuellen FullClient-Adressbuchs und keine aktuelle Freigabe für Fernsteuerbefehle oder Host-Änderungen.

Gewünschte Funktionen:

- Ressourcen anzeigen: CPU, Arbeitsspeicher, Laufwerke mit Gesamtkapazität und freiem Speicher.
- Dienste anzeigen und mit gesonderter Berechtigung starten, stoppen und neu starten.
- Gerätespezifische Ansicht im Detailbereich des FullClients.

Vor Umsetzung festlegen: getrennte Rechte für Lesen und Steuern, authentifizierter Agentenkanal, Protokollierung von Steuerbefehlen, Schutz laufender Fernwartungen und kritischer Dienste. Keine Betriebssystem-Neustarts als implizite Aktion.

## Separates Zusatzfeature: RemotePowerShell

Zusätzlich ausdrücklich als spätere Funktion vorgemerkt: eine eigene RemotePowerShell-Konsole ohne Aufbau einer Desktop-Fernsteuerung.

- Separater Einstieg am ausgewählten Gerät, getrennt von „Verbinden“.
- Eigenes Terminalrecht, explizites Ausführungskonto und klarer Sitzungsstatus.
- Authentifizierter, verschlüsselter Kanal; nachvollziehbarer Beginn, Befehle und Ende der Sitzung, mit Behandlung sensibler Eingaben.
- Abbruch und Verbindungsverlust müssen vorhersehbar behandelt werden; kein stilles Erhöhen von Rechten oder Umgehen von Systemrichtlinien.
- Keine Umsetzung oder Ausführung im Rahmen des aktuellen Adressbuch-Features.
