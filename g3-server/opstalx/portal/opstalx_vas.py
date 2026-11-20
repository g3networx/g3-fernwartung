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
        payload = b64(json.dumps({
            "aud": "talx.opslinx.de", "iss": "opslinx-vas-inbox",
            "sub": device, "iat": int(time.time()), "exp": int(time.time()) + 300,
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

    def launch(customer_id):
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
        m.audit("opstalx_room_start", customer_id)
        return "https://talx.opslinx.de/vas/launch#grant=" + grant

    @app.get("/client-addressbook/vas/customers")
    def native_ab_vas_customers():
        native_identity()
        return jsonify(customers=allowed_customers())

    @app.post("/client-addressbook/vas/start")
    def native_ab_vas_start():
        data = native_json()
        native_identity()
        return jsonify(url=launch(data.get("customer_id")))

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

    @app.after_request
    def resume_vas(response):
        if (request.endpoint in ("login", "central_callback")
                and request.cookies.get("__Host-opstalx-resume") == "1"
                and response.status_code == 302 and response.location == "/"):
            response.location = "/opstalx/vas"
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
