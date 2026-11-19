# Bootstrap-Polling (AP41)

## Behavior

The installed Windows service proves its device key once on service start and
after the server refuses an expired/revoked heartbeat grant. The bootstrap
returns a purpose-bound HMAC grant valid for 24 hours, bound to the native ID
and current Ed25519 public key. It is held only in the service thread's memory.
The existing activity token does **not** authorize the new endpoint.

`POST /client-heartbeat` uses this grant for credential offers and the existing
device-management callback. Job admission, active-session deferral, outbound
policy and result receipts stay in `device_management.py` unchanged. A normal
heartbeat runs every 240–360 seconds; network/HTTP failures back off from
24–36 seconds to 12–18 minutes, resetting after success. Portal jobs and policy
changes therefore normally reach the device within six minutes, rather than
the previous 30 seconds. Rendezvous and active-session traffic are independent.

The new route deliberately shares the existing `client_bootstrap` Flask endpoint
so the device-only CSRF exemption and service-rotation wrapper still apply. Its
separate grant is issued only after the original one-use Ed25519 proof.
Unknown IDs, changed keys and expired grants are refused with 404. HTTPS and
redirect refusal remain enforced in the client.

Old clients retain the original GET/POST proof and replay protection. The
bootstrap limiter is bounded, locked, in-memory and per known device/source pair, not per
shared NAT IP. Limits are **per Gunicorn worker**, and reset after restart;
they are traffic protection, not authorization. Anonymous ad-hoc registrations
retain their existing IP budget. Expired challenge cleanup runs at most once
per five minutes per worker when bootstrap traffic arrives. Legacy challenge
issue/consumption still write SQLite; they are not falsely described as read-only.

## Lab evidence, 19 November 2026

The existing portal source and templates were copied read-only into an isolated
fixture. All identities, passwords and keys used in it were freshly generated
lab data. No production database or private keys were copied. Ubuntu's test
Gunicorn bound only to loopback, with four workers and two threads per worker.

80 devices behind one IP, ten compressed refresh cycles each:

| Server/client mode | Bootstrap cycles | Heartbeats | SQL commits |
|---|---:|---:|---:|
| Original server and legacy client | 800 | 0 | 4080 |
| Patched server and unchanged legacy client | 800 | 0 | 1684 |
| Patched server and new protocol | 80 | 720 | 244 |

All HTTP cycles succeeded. The database-backed `/health` p95 stayed below
40 ms in this fixture. This is a compressed workload comparison, **not** an
hour-long production measurement or a proof of cluster `/ready` behavior.
The seven-day absence of SQLite lock errors remains a production observation.

Seven focused portal tests passed: legacy proof/replay, unknown/wrong keys,
ad-hoc enrollment, provisioning acknowledgement, shared NAT, active-session
job deferral/policy delivery and heartbeat grant expiry/key binding. The two
Rust scheduling tests passed. Full Windows native compilation/installation
and measured production bootstrap request rates require the next client build.

Portal integration tests in `test_bootstrap_polling.py` run in a **staged portal**
with its existing `test_app.py` and `test_bootstrap_client.py`; they never import
the production app/data. The Rust build test filter covers all `g3_bootstrap::`
tests, including the scheduling submodule.

## Deployment and regression surface

Back up each node and compare its current bootstrap source hash with the tested
baseline before replacing `bootstrap_client.py` and adding `bootstrap_polling.py`.
Prepare standbys first; reload only the active Gunicorn master gracefully, never
hbbs/hbbr or active clients. Export the resulting primary snapshot and verify
both source files are present with their exact hashes. Do not force a role
handover during active remote support. The portal preparation script preserves
this version and copies its helper on future deployments.

Existing changed paths: `src/g3_bootstrap.rs` separates startup proof from
heartbeat requests and changes that service thread's cadence; the native build
script broadens only the bootstrap test filter; `prepare-device-management.py`
preserves the patched server source. The copied server bootstrap implementation
changes only its limiter/cleanup and adds the authenticated heartbeat dispatch
and grant. No session transport, renderer, installer or customer profile is
modified by this change. Production sources should be compared against the
read-only baseline because the portal implementation previously lived outside
this client repository.
