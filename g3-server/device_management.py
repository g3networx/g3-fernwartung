"""Portal-side management for explicitly enrolled OpsLinX installations."""

from contextlib import contextmanager
from base64 import urlsafe_b64encode
from hashlib import sha256
from hmac import compare_digest, digest
import os
import re
import secrets
import time

from flask import Blueprint, abort, g, redirect, render_template, request, url_for


INSTALLATION_ID = re.compile(r"[0-9a-f]{32}")
NATIVE_ID = re.compile(r"[A-Za-z0-9_-]{6,40}")
KEY_DIGEST = re.compile(r"[0-9a-f]{64}")
OPERATIONS = frozenset({"update", "uninstall"})
RESULTS = {"complete": "succeeded", "busy": "queued", "failed": "failed"}


@contextmanager
def write_transaction(db):
    db.execute("BEGIN IMMEDIATE")
    try:
        yield
        db.commit()
    except BaseException:
        db.rollback()
        raise


def install(app, portal):
    app.config.setdefault("DEVICE_MANAGEMENT_ENABLED", os.getenv("OPSLINX_DEVICE_MANAGEMENT") == "1")
    blueprint = Blueprint("device_management", __name__, template_folder="templates")
    initialize = portal.init

    def initialize_schema():
        with app.app_context():
            db = portal.db()
            existing = {row[0] for row in db.execute(
                "SELECT name FROM sqlite_master WHERE type IN ('table', 'index')"
            )}
            required = {"managed_installations", "managed_device_operations",
                        "managed_device_one_queued_operation", "managed_outbound_policy"}
            if required <= existing and any(
                column[1] == "claim_nonce" for column in db.execute("PRAGMA table_info(managed_device_operations)")
            ):
                return
            portal.run("""
                CREATE TABLE IF NOT EXISTS managed_installations (
                    device_id INTEGER NOT NULL,
                    installation_id TEXT NOT NULL,
                    customer_id INTEGER NOT NULL,
                    native_id TEXT NOT NULL,
                    key_digest TEXT NOT NULL,
                    variant TEXT NOT NULL CHECK (variant IN ('host', 'full')),
                    last_seen INTEGER NOT NULL,
                    PRIMARY KEY (device_id, installation_id)
                )
            """)
            portal.run("""
                CREATE TABLE IF NOT EXISTS managed_device_operations (
                    id INTEGER PRIMARY KEY,
                    device_id INTEGER NOT NULL,
                    installation_id TEXT NOT NULL,
                    operation TEXT NOT NULL CHECK (operation IN ('update', 'uninstall')),
                    state TEXT NOT NULL CHECK (state IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
                    created INTEGER NOT NULL,
                    created_by INTEGER NOT NULL,
                    receipt_digest TEXT,
                    claim_nonce TEXT,
                    last_exit_code INTEGER
                )
            """)
            columns = portal.db().execute("PRAGMA table_info(managed_device_operations)").fetchall()
            if "claim_nonce" not in {column[1] for column in columns}:
                portal.run("ALTER TABLE managed_device_operations ADD COLUMN claim_nonce TEXT")
            portal.run("""
                CREATE UNIQUE INDEX IF NOT EXISTS managed_device_one_queued_operation
                ON managed_device_operations (device_id, installation_id)
                WHERE state IN ('queued', 'running')
            """)
            portal.run("""
                CREATE TABLE IF NOT EXISTS managed_outbound_policy (
                    device_id INTEGER NOT NULL,
                    customer_id INTEGER NOT NULL,
                    native_id TEXT NOT NULL,
                    blocked INTEGER NOT NULL CHECK (blocked IN (0, 1)),
                    revision INTEGER NOT NULL,
                    PRIMARY KEY (device_id, customer_id, native_id)
                )
            """)

    def init():
        initialize()
        initialize_schema()

    portal.init = init
    app.config["DEVICE_MANAGEMENT_INITIALIZE"] = initialize_schema

    def enabled():
        return app.config.get("DEVICE_MANAGEMENT_ENABLED") is True

    def authenticated_installation(device_id, native_id, installation_id, variant, key_digest, ready=False):
        """Call after the installed client proves its device key in client-bootstrap."""
        if not enabled() or g.get("verified_device_id") != device_id:
            return {}
        if (not isinstance(installation_id, str) or not INSTALLATION_ID.fullmatch(installation_id)
                or not isinstance(native_id, str) or not NATIVE_ID.fullmatch(native_id)
                or not isinstance(key_digest, str) or not KEY_DIGEST.fullmatch(key_digest)
                or variant not in ("host", "full")):
            abort(400)
        db = portal.db()
        with write_transaction(db):
            device = db.execute("SELECT * FROM devices WHERE id = ?", (device_id,)).fetchone()
            if not device or device["rustdesk_id"] != native_id:
                abort(404)
            registered = db.execute("""
                INSERT INTO managed_installations VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(device_id, installation_id) DO UPDATE SET last_seen = excluded.last_seen
                WHERE managed_installations.customer_id = excluded.customer_id
                  AND managed_installations.native_id = excluded.native_id
                  AND managed_installations.key_digest = excluded.key_digest
                  AND managed_installations.variant = excluded.variant
            """, (device_id, installation_id, device["customer_id"], native_id,
                  key_digest, variant, int(time.time())))
            if not registered.rowcount:
                abort(409)
            policy = outbound_policy(db, device)
            result = {"outbound_blocked": bool(policy["blocked"]), "policy_revision": policy["revision"]}
            if ready:
                job = claim(db, device_id, installation_id, ready == "update")
                if job:
                    result["job"] = job
        return result

    app.config["DEVICE_MANAGEMENT_HEARTBEAT"] = authenticated_installation

    def bootstrap_response(request_data, device_id, native_id, verified_public_key, response):
        registration = request_data.get("management")
        if enabled() and isinstance(registration, dict):
            status = authenticated_installation(
                device_id, native_id, registration.get("installation_id"),
                registration.get("variant"), sha256(verified_public_key).hexdigest(),
                ready="update" if registration.get("update_ready") is True else False,
            )
            if status:
                response["management"] = status
        return response

    app.config["DEVICE_MANAGEMENT_BOOTSTRAP_RESPONSE"] = bootstrap_response

    def outbound_policy(db, device):
        return db.execute("""
            SELECT blocked, revision FROM managed_outbound_policy
            WHERE device_id = ? AND customer_id = ? AND native_id = ?
        """, (device["id"], device["customer_id"], device["rustdesk_id"])).fetchone() or {
            "blocked": 0, "revision": 0,
        }

    def matching_installations(db, device):
        return db.execute("""
            SELECT * FROM managed_installations
            WHERE device_id = ? AND customer_id = ? AND native_id = ?
            ORDER BY variant, last_seen DESC
        """, (device["id"], device["customer_id"], device["rustdesk_id"])).fetchall()

    def claim(db, device_id, installation_id, update_only):
        if db.execute("""
            SELECT 1 FROM activity_sessions
            WHERE device_id = ? AND closed = 0 AND last_seen >= ?
        """, (device_id, int(time.time()) - 120)).fetchone():
            return None
        secret = app.secret_key
        if not secret:
            return None
        key = secret.encode() if isinstance(secret, str) else secret
        row = db.execute("""
            SELECT id, operation, claim_nonce, receipt_digest FROM managed_device_operations
            WHERE device_id = ? AND installation_id = ? AND state IN ('queued', 'running')
              AND (? = 0 OR operation = 'update')
        """, (device_id, installation_id, update_only)).fetchone()
        if row is None:
            return None
        nonce = row["claim_nonce"] if row["claim_nonce"] and row["receipt_digest"] else secrets.token_hex(16)
        context = f"opslinx-operation:{device_id}:{installation_id}:{row['id']}:{nonce}".encode()
        receipt = urlsafe_b64encode(digest(key, context, "sha256")).rstrip(b"=").decode()
        receipt_digest = sha256(receipt.encode()).hexdigest()
        row = db.execute("""
            UPDATE managed_device_operations SET state = 'running', receipt_digest = ?, claim_nonce = ?
            WHERE id = ? AND (state = 'queued' OR (? AND state = 'running' AND receipt_digest = ?))
            RETURNING id, operation
        """, (receipt_digest, nonce, row["id"], update_only, receipt_digest)).fetchone()
        return {"id": row["id"], "operation": row["operation"], "receipt": receipt} if row else None

    @blueprint.post("/client-management/operations/<int:operation_id>/result")
    def operation_result(operation_id):
        authorization = request.headers.get("Authorization", "")
        if not enabled() or not re.fullmatch(r"Bearer [A-Za-z0-9_-]{43}", authorization):
            abort(404)
        data = request.get_json(silent=True)
        if not isinstance(data, dict) or not isinstance(data.get("result"), str):
            abort(400)
        state = RESULTS.get(data["result"])
        exit_code = data.get("exit_code")
        if (state is None or type(exit_code) is not int or not 0 <= exit_code <= 65535
                or (state == "queued") != (exit_code == 1618)
                or (state == "succeeded") != (exit_code in (0, 3010))):
            abort(400)
        receipt_digest = sha256(authorization[7:].encode()).hexdigest()
        db = portal.db()
        with write_transaction(db):
            row = db.execute("""
                SELECT o.state, o.last_exit_code FROM managed_device_operations o
                JOIN managed_installations i USING (device_id, installation_id)
                JOIN devices d ON d.id = i.device_id AND d.customer_id = i.customer_id AND d.rustdesk_id = i.native_id
                WHERE o.id = ? AND o.receipt_digest = ?
            """, (operation_id, receipt_digest)).fetchone()
            if not row:
                abort(404)
            if row["state"] != "running":
                if row["state"] == state and row["last_exit_code"] == exit_code:
                    return {"recorded": True}
                abort(409)
            db.execute("""
                UPDATE managed_device_operations SET state = ?, last_exit_code = ?, claim_nonce = NULL
                WHERE id = ?
            """, (state, exit_code, operation_id))
            db.execute("INSERT INTO audit(ts,actor,event,target,ip) VALUES (?,?,?,?,?)",
                       (int(time.time()), "OpsLinX-Client", "device_operation_" + state,
                        str(operation_id), request.remote_addr))
        return {"recorded": True}

    @blueprint.route("/devices/<int:did>/management", methods=["GET", "POST"])
    @portal.auth
    def manage(did):
        if not enabled() or g.user["role"] != "admin":
            abort(404)
        device = portal.device(did, "edit")
        db = portal.db()
        if request.method == "POST":
            submitted_csrf = request.form.get("csrf", "")
            if not submitted_csrf.isascii() or not compare_digest(submitted_csrf, portal.csrf()):
                abort(400)
            with write_transaction(db):
                device = portal.device(did, "edit")
                installations = {row["installation_id"]: row for row in matching_installations(db, device)}
                if not installations:
                    abort(409)
                action = request.form.get("action")
                if action == "uninstall" and not app.config.get("DEVICE_MANAGEMENT_UNINSTALL_ENABLED"):
                    abort(404)
                if action in ("block-outbound", "allow-outbound") and not app.config.get("DEVICE_MANAGEMENT_POLICY_ENABLED"):
                    abort(404)
                if action in OPERATIONS:
                    installation_id = request.form.get("installation_id")
                    if installation_id not in installations:
                        abort(404)
                    result = db.execute("""
                        INSERT INTO managed_device_operations
                        (device_id, installation_id, operation, state, created, created_by)
                        VALUES (?, ?, ?, 'queued', ?, ?) ON CONFLICT DO NOTHING
                    """, (did, installation_id, action, int(time.time()), g.user["uid"]))
                    if result.rowcount:
                        audit(db, f"device_{action}_queued", f"{did}/{result.lastrowid}")
                elif action == "cancel":
                    operation_id = request.form.get("operation_id", type=int)
                    operation = db.execute("""
                        SELECT * FROM managed_device_operations
                        WHERE id = ? AND device_id = ? AND state = 'queued'
                    """, (operation_id, did)).fetchone()
                    if not operation or operation["installation_id"] not in installations:
                        abort(404)
                    db.execute("UPDATE managed_device_operations SET state = 'cancelled' WHERE id = ?",
                               (operation_id,))
                    audit(db, "device_operation_cancelled", f"{did}/{operation_id}")
                elif action in ("block-outbound", "allow-outbound"):
                    blocked = int(action == "block-outbound")
                    if blocked != outbound_policy(db, device)["blocked"]:
                        db.execute("""
                            INSERT INTO managed_outbound_policy VALUES (?, ?, ?, ?, 1)
                            ON CONFLICT(device_id, customer_id, native_id) DO UPDATE
                            SET blocked = excluded.blocked, revision = managed_outbound_policy.revision + 1
                        """, (did, device["customer_id"], device["rustdesk_id"], blocked))
                        audit(db, "device_outbound_policy_changed", f"{did}/{blocked}")
                else:
                    abort(400)
            return redirect(url_for("device_management.manage", did=did), code=303)
        installations = matching_installations(db, device)
        operations = db.execute("""
            SELECT o.*, EXISTS (
                SELECT 1 FROM activity_sessions s
                WHERE s.device_id = o.device_id AND s.closed = 0 AND s.last_seen >= ?
            ) AS active_session FROM managed_device_operations o
            JOIN managed_installations i USING (device_id, installation_id)
            WHERE o.device_id = ? AND i.customer_id = ? AND i.native_id = ?
            ORDER BY o.id DESC LIMIT 25
        """, (int(time.time()) - 120, did, device["customer_id"], device["rustdesk_id"])).fetchall()
        return render_template(
            "device_management.html", device=device, installations=installations, operations=operations,
            policy=outbound_policy(db, device), management_csrf=portal.csrf(),
        )

    def audit(db, event, target):
        db.execute("INSERT INTO audit(ts,actor,event,target,ip) VALUES (?,?,?,?,?)",
                   (int(time.time()), g.user["username"], event, target, request.remote_addr))

    app.register_blueprint(blueprint)
