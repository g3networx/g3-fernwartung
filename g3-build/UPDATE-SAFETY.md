# Windows update session protection

The g3.21 update path keeps the existing GUI running until the elevated installer obtains an exclusive Windows byte-range lock. Incoming connections and outgoing desktop, file-transfer, terminal and port-forward sessions hold shared leases for their complete connection lifetime. The OS arbitrates both operations atomically across processes and Windows sessions. A busy or unreadable gate aborts installation before service control or MSI execution.

The installer never uses Kill, taskkill, CloseMainWindow or Windows Restart Manager to close a session. Idle GUI/tray processes voluntarily exit only while the exclusive lease is held. The installed service is stopped only after acquiring that lease. The lease stays held through MSI execution, payload validation and service recovery. The launcher opens the client after the worker has released its lease.

Direct MSI installation/repair is rejected unless invoked by the guarded launcher; removal remains a separate explicit operation. The empty gate file is a permanent, never-overwritten MSI component, preserving the same file object through upgrades.

Legacy migration: clients without the protocol, or with an unknown native DLL hash, are never shut down by the new installer. They require a maintenance window with the old client and service already stopped. Do not lift the public automatic-update hold for legacy g3.20 and older: those clients themselves exit before handing off to the launcher. No remote session can be preserved by code they do not yet contain. After installing the guarded baseline, future updates use the protected handoff. Add verified prior release DLL SHA-256 hashes to `g3-build/update-gate-native-hashes.txt` when preparing subsequent versions.

Regression: `python g3-build/test-update-session-gate.py` runs three cross-process tests against the actual Rust and C# lock implementations. `g3-build/test-windows-update.ps1` additionally installs/repairs the real FullClient and verifies busy-session refusal and unchanged service PID, exclusively on a disposable GitHub runner. It refuses execution on a normal workstation. Neither script tests or manipulates customer systems.

Guarded clients use `/client/update-v2.json`. The web endpoint returns only releases marked `session_guard: 1` and supports its own `update-v2-hold`. The original `/client/update.json` stays held for legacy clients. Manual downloads remain independent of both holds.
