"""Verify that the OpsTalX directory honors customer and folder permissions."""
from base64 import urlsafe_b64decode
import json
from pathlib import Path
import sqlite3
import sys
from types import SimpleNamespace
import unittest

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from flask import Flask, abort, g, redirect, request
from jinja2 import ChoiceLoader, DictLoader

portal = Path(__file__).resolve().parent / "portal"
sys.path.insert(0, str(portal))
import opstalx_vas


class Directory(unittest.TestCase):
    def setUp(self):
        db = sqlite3.connect(":memory:")
        self.addCleanup(db.close)
        db.row_factory = sqlite3.Row
        db.executescript("""
            CREATE TABLE customers (id INTEGER PRIMARY KEY, parent_id INTEGER, name TEXT);
            CREATE TABLE devices (id INTEGER PRIMARY KEY, customer_id INTEGER, name TEXT,
                                  rustdesk_id TEXT, password TEXT);
            INSERT INTO customers VALUES (1,NULL,'Alpha'), (2,NULL,'Beta'), (3,1,'Alpha Mobil'),
                (4,1,'Alpha Intern'), (5,NULL,'Ohne TalX');
            INSERT INTO devices VALUES (1,1,'Notebook','111222333','secret'),
                (2,3,'Telefon <Mobil>','444555666','secret'),
                (3,3,'Zweites Telefon','444555666','secret'),
                (4,4,'Internes Testgerät','777888999','secret'),
                (5,2,'Fremder Kontakt','987654321','secret'),
                (6,5,'Ohne Freigabe','234567890','secret'),
                (7,3,'Ungültig','abc','secret');
        """)
        app = Flask(__name__, template_folder=str(portal / "templates"))
        app.jinja_loader = ChoiceLoader([
            app.jinja_loader, DictLoader({"base.html": "{% block content %}{% endblock %}"}),
        ])
        app.config["OPSTALX_CUSTOMER_IDS"] = [1, 2]
        self.key = Ed25519PrivateKey.generate()
        app.config["OPSTALX_SIGNING_KEY"] = self.key
        app.jinja_env.globals["csrf"] = lambda: "test-csrf"

        @app.before_request
        def identify():
            g.user = {"setup": False} if request.headers.get("X-Test-Login") else None

        @app.get("/login")
        def login():
            return redirect("/")

        self.browser = app.test_client()
        self.headers = {"X-Test-Login": "alpha"}
        self.address_book = {"Authorization": "Bearer fixture-address-book"}
        self.audit = []

        def native_identity():
            if request.headers.get("Authorization") != self.address_book["Authorization"]:
                abort(401)
            g.user = {"uid": 123, "setup": False}

        opstalx_vas.install(app, SimpleNamespace(
            db=lambda: db, access=lambda cid, _: cid in (1, 3, 5),
            limited=lambda *_: None, audit=lambda *event: self.audit.append(event),
            visible_customers=lambda _: [{"id": 1, "path": "Alpha"}, {"id": 3, "path": "Alpha › Mobil"}],
        ), native_identity, lambda: request.get_json())

    def test_requires_login_and_returns_to_directory(self):
        response = self.browser.get("/opstalx/directory")
        self.assertEqual(response.location, "/login")
        self.assertNotIn(b"111222333", response.data)
        self.assertEqual(self.browser.get("/login").location, "/opstalx/directory")

    def test_selects_only_visible_directory_contacts(self):
        page = self.browser.get("/opstalx/directory", headers=self.headers).get_data(as_text=True)
        self.assertIn("Notebook", page)
        self.assertIn("Telefon &lt;Mobil&gt;", page)
        self.assertEqual(page.count("#device=444555666"), 1)
        for absent in ("777888999", "987654321", "234567890", "secret", "value=\"2\""):
            self.assertNotIn(absent, page)
        self.assertEqual(self.browser.post("/opstalx/directory", data={"customer_id": "2"},
                                          headers=self.headers).status_code, 404)

    def test_search_accepts_formatted_id_and_finds_names(self):
        for search in ("444 555 666", "<mobil>"):
            page = self.browser.post("/opstalx/directory", data={"customer_id": "1", "q": search},
                                     headers=self.headers).get_data(as_text=True)
            self.assertIn("#device=444555666", page)
            self.assertNotIn("Notebook", page)

    def test_native_conference_uses_address_book_identity_and_selected_customer(self):
        route = "/client-addressbook/conference/start"
        response = self.browser.post(route, json={"device_id": 2}, headers=self.address_book)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertEqual(response.json["device"], "444555666")
        payload, signature = response.json["grant"].split(".")
        self.key.public_key().verify(urlsafe_b64decode(signature + "=="), payload.encode())
        claims = json.loads(urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        self.assertEqual(claims["customer_id"], 1)
        self.assertEqual(self.audit, [("opstalx_conference_start", 1)])

    def test_native_conference_does_not_grant_hidden_or_unapproved_devices(self):
        route = "/client-addressbook/conference/start"
        self.assertEqual(self.browser.post(route, json={"device_id": 2}).status_code, 401)
        for device_id, expected in [(4, 404), (5, 404), (6, 403), (7, 400), (True, 400)]:
            with self.subTest(device_id=device_id):
                response = self.browser.post(route, json={"device_id": device_id},
                                             headers=self.address_book)
                self.assertEqual(response.status_code, expected)
        self.assertEqual(self.audit, [])


if __name__ == "__main__":
    unittest.main()
