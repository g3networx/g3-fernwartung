"""Issue short-lived OpsTalX launch grants from OpsLinX customer identities."""
from base64 import urlsafe_b64encode
import json
import os
from pathlib import Path
import secrets
import time

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from flask import abort, g, jsonify, redirect, render_template, request


def b64(data):
    return urlsafe_b64encode(data).decode().rstrip("=")


def install(app, m, native_identity, native_json):
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
            return redirect(launch(request.form.get("customer_id", type=int)), code=303)
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
    if not key_path:
        return
    try:
        key = load_pem_private_key(Path(key_path).read_bytes(), password=None)
        if not isinstance(key, Ed25519PrivateKey):
            raise ValueError("Expected an Ed25519 key")
        customers = frozenset(
            int(value) for value in os.environ.get("OPSTALX_CUSTOMER_IDS", "").split(",")
            if value.strip()
        )
    except (OSError, ValueError, TypeError):
        app.logger.warning("OpsTalX start disabled because the VAS configuration is invalid")
        return
    app.config.update(OPSTALX_SIGNING_KEY=key, OPSTALX_CUSTOMER_IDS=customers)
