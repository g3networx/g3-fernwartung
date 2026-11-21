"""Issue short-lived OpsTalX launch grants from OpsLinX customer identities."""
from base64 import b64decode, urlsafe_b64encode
import json
import os
from pathlib import Path
import re
import secrets
import time

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from flask import abort, g, jsonify, redirect, render_template, request
from itsdangerous import BadData, URLSafeTimedSerializer


def b64(data):
    return urlsafe_b64encode(data).decode().rstrip("=")


def install(app, m, native_identity, native_json):
    @app.post("/client-vas-inbox")
    def opstalx_inbox():
        data = request.get_json(silent=True)
        if not isinstance(data, dict):
            abort(400)
        device = data.get("id")
        if not isinstance(device, str) or not re.fullmatch(r"[A-Za-z0-9_-]{6,40}", device):
            abort(400)
        key = app.config.get("OPSTALX_SIGNING_KEY")
        if key is None:
            abort(503)
        m.limited("vas-inbox:" + str(request.remote_addr), 240)
        challenges = URLSafeTimedSerializer(app.secret_key, salt="opslinx-vas-inbox-v1")
        if set(data) == {"id"}:
            nonce = secrets.token_urlsafe(32)
            return jsonify(challenge=challenges.dumps([device, nonce]), nonce=nonce)
        challenge, signature = data.get("challenge"), data.get("signature")
        if not isinstance(challenge, str) or len(challenge) > 256 or not isinstance(signature, str) or len(signature) != 88:
            abort(400)
        try:
            bound_device, nonce = challenges.loads(challenge, max_age=30)
            if bound_device != device:
                abort(403)
            peer = json.loads((m.DATA / "peer-public-keys.json").read_text(encoding="utf-8"))[device]
            Ed25519PublicKey.from_public_bytes(bytes.fromhex(peer)).verify(
                b64decode(signature, validate=True), f"g3-bootstrap-v1:{device}:{nonce}".encode()
            )
        except (BadData, InvalidSignature, KeyError, OSError, TypeError, ValueError):
            abort(403)
        now = int(time.time())
        payload = b64(json.dumps({
            "aud": "talx.opslinx.de", "iss": "opslinx-vas-inbox",
            "sub": device, "iat": now, "exp": now + 300,
        }, separators=(",", ":")).encode())
        return jsonify(token=payload + "." + b64(key.sign(payload.encode())), expires_in=300)

    def allowed_customers():
        configured = app.config.get("OPSTALX_CUSTOMER_IDS", ())
        return [
            dict(row)
            for row in m.db().execute(
                "SELECT id,name FROM customers WHERE parent_id IS NULL ORDER BY name"
            )
            if row["id"] in configured and m.access(row["id"], "view")
        ]

    def room_grant(customer_id, audit_event):
        if type(customer_id) is not int or not any(
            entry["id"] == customer_id for entry in allowed_customers()
        ):
            abort(403)
        key = app.config.get("OPSTALX_SIGNING_KEY")
        if key is None:
            abort(503)
        m.limited("opstalx-start:" + str(g.user["uid"]), 12)
        claim = {
            "aud": "talx.opslinx.de",
            "iss": "opslinx-portal",
            "customer_id": customer_id,
            "exp": int(time.time()) + 60,
            "jti": secrets.token_hex(16),
        }
        payload = b64(json.dumps(claim, separators=(",", ":")).encode())
        grant = payload + "." + b64(key.sign(payload.encode()))
        m.audit(audit_event, customer_id)
        return grant

    def launch(customer_id):
        return "https://talx.opslinx.de/vas/launch#grant=" + room_grant(customer_id, "opstalx_room_start")

    @app.get("/client-addressbook/vas/customers")
    def native_ab_vas_customers():
        native_identity()
        return jsonify(customers=allowed_customers())

    @app.post("/client-addressbook/vas/start", defaults={"conference": False})
    @app.post("/client-addressbook/conference/start", defaults={"conference": True})
    def native_ab_vas_start(conference):
        data = native_json()
        native_identity()
        if conference:
            return native_conference_launch(data)
        return jsonify(url=launch(data.get("customer_id")))

    def native_conference_launch(data):
        if not isinstance(data, dict):
            abort(400)
        device_id = data.get("device_id")
        if type(device_id) is not int or not 0 < device_id <= (2**63 - 1):
            abort(400)
        db = m.db()
        device = db.execute(
            "SELECT customer_id,rustdesk_id FROM devices WHERE id=?", (device_id,)
        ).fetchone()
        if device is None or not m.access(device["customer_id"], "view"):
            abort(404)
        native_id = device["rustdesk_id"]
        if not re.fullmatch(r"[0-9]{6,16}", native_id or ""):
            abort(400)
        customer = db.execute("""
            WITH RECURSIVE ancestry(id,parent_id) AS (
                SELECT id,parent_id FROM customers WHERE id=?
                UNION
                SELECT c.id,c.parent_id FROM customers c
                JOIN ancestry a ON c.id=a.parent_id
            )
            SELECT id FROM ancestry WHERE parent_id IS NULL
        """, (device["customer_id"],)).fetchone()
        if customer is None:
            abort(403)
        response = jsonify(
            grant=room_grant(customer["id"], "opstalx_conference_start"), device=native_id,
        )
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.route("/opstalx/vas", methods=["GET", "POST"])
    def opstalx_vas():
        if not g.get("user"):
            response = redirect("/login")
            response.set_cookie(
                "__Host-opstalx-resume", "1", max_age=300, secure=True,
                httponly=True, samesite="Lax", path="/"
            )
            return response
        if request.method == "POST":
            return render_template(
                "opstalx_vas_launch.html",
                launch_url=launch(request.form.get("customer_id", type=int)),
            )
        return render_template("opstalx_vas.html", customers=allowed_customers())

    @app.route("/opstalx/directory", methods=["GET", "POST"])
    def opstalx_directory():
        if not g.get("user"):
            response = redirect("/login")
            response.set_cookie(
                "__Host-opstalx-resume", "directory", max_age=300, secure=True,
                httponly=True, samesite="Lax", path="/"
            )
            return response
        if g.user["setup"]:
            abort(403)
        customers = allowed_customers()
        search = request.form.get("q", "").strip()
        if len(search) > 100:
            abort(400)
        selected = None
        contacts = []
        if customers:
            selected = request.form.get("customer_id", str(customers[0]["id"]))
            if selected not in {str(customer["id"]) for customer in customers}:
                abort(404)
            selected = int(selected)
            visible = {
                row["id"]: row["path"] for row in m.visible_customers("view")
            }
            rows = m.db().execute("""
                WITH RECURSIVE scope(id) AS (
                    SELECT id FROM customers WHERE id=?
                    UNION
                    SELECT c.id FROM customers c JOIN scope s ON c.parent_id=s.id
                )
                SELECT d.customer_id,d.name,d.rustdesk_id
                  FROM devices d JOIN scope s ON s.id=d.customer_id
                 ORDER BY d.name COLLATE NOCASE,d.id
            """, (selected,))
            query = search.casefold()
            id_query = "".join(search.split())
            seen = set()
            for row in rows:
                device = row["rustdesk_id"]
                if row["customer_id"] not in visible or not re.fullmatch(r"[0-9]{6,16}", device or ""):
                    continue
                folder = visible[row["customer_id"]]
                if query and query not in (row["name"] + " " + folder).casefold() and id_query not in device:
                    continue
                if device in seen:
                    continue
                seen.add(device)
                contacts.append(dict(name=row["name"], folder=folder, device=device))
                if len(contacts) == 201:
                    break
        return render_template("opstalx_directory.html", customers=customers, selected=selected,
                               search=search, contacts=contacts[:200], truncated=len(contacts) > 200)

    @app.after_request
    def resume_vas(response):
        target = {"1": "/opstalx/vas", "directory": "/opstalx/directory"}.get(request.cookies.get("__Host-opstalx-resume"))
        if (request.endpoint in ("login", "central_callback") and target
                and response.status_code == 302 and response.location == "/"):
            response.location = target
            response.delete_cookie("__Host-opstalx-resume", secure=True,
                                   httponly=True, samesite="Lax", path="/")
        return response


def configure(app):
    key_path = os.environ.get("OPSTALX_SIGNING_KEY_FILE")
    try:
        if key_path:
            customers = [
                int(value) for value in os.environ.get("OPSTALX_CUSTOMER_IDS", "").split(",")
                if value.strip()
            ]
        else:
            config_path = Path("/etc/opslinx/opstalx-vas.json")
            if not config_path.is_file():
                return
            configuration = json.loads(config_path.read_text(encoding="utf-8"))
            key_path = configuration["key_file"]
            customers = configuration["customer_ids"]
        if not isinstance(customers, list) or any(
            type(customer) is not int or customer <= 0 for customer in customers
        ):
            raise ValueError("Expected positive customer IDs")
        key = load_pem_private_key(Path(key_path).read_bytes(), password=None)
        if not isinstance(key, Ed25519PrivateKey):
            raise ValueError("Expected an Ed25519 key")
    except (KeyError, OSError, ValueError, TypeError):
        app.logger.warning("OpsTalX start disabled because the VAS configuration is invalid")
        return
    app.config.update(OPSTALX_SIGNING_KEY=key, OPSTALX_CUSTOMER_IDS=frozenset(customers))
