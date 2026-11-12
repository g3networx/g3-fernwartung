import sqlite3
import time
import unittest
from functools import wraps
from hashlib import sha256

from flask import Flask, abort, g
from werkzeug.exceptions import Conflict

import device_management


class DeviceManagementTest(unittest.TestCase):
    installation_id = "a" * 32
    public_key = bytes(range(32))
    key_digest = sha256(public_key).hexdigest()
    route = "/devices/1/management"

    def setUp(self):
        self.app = Flask(__name__)
        self.app.config["TESTING"] = True
        self.app.config.update(DEVICE_MANAGEMENT_UNINSTALL_ENABLED=True, DEVICE_MANAGEMENT_POLICY_ENABLED=True)
        self.app.secret_key = "device-management-test-key"
        self.db = sqlite3.connect(":memory:")
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
            CREATE TABLE devices(id INTEGER PRIMARY KEY, customer_id INTEGER, rustdesk_id TEXT, name TEXT);
            CREATE TABLE audit(ts INTEGER, actor TEXT, event TEXT, target TEXT, ip TEXT);
            CREATE TABLE activity_sessions(device_id INTEGER, closed INTEGER, last_seen INTEGER);
            INSERT INTO devices VALUES (1, 10, '111111', 'Laborhost'), (2, 20, '222222', 'Anderer Host');
        """)
        self.role = "admin"

        @self.app.before_request
        def actor():
            g.user = {"role": self.role, "uid": 1, "username": "lab-admin"}

        class Portal:
            def __init__(self, db):
                self.connection = db

            def init(self):
                pass

            def db(self):
                return self.connection

            def run(self, sql):
                self.connection.execute(sql)
                self.connection.commit()

            def auth(self, handler):
                @wraps(handler)
                def checked(*args, **kwargs):
                    if not g.get("user"):
                        abort(404)
                    return handler(*args, **kwargs)

                return checked

            def device(self, did, permission):
                row = self.connection.execute("SELECT * FROM devices WHERE id = ?", (did,)).fetchone()
                if not row:
                    abort(404)
                return row

            def csrf(self):
                return "lab-csrf"

        portal = Portal(self.db)
        device_management.install(self.app, portal)
        portal.init()
        self.client = self.app.test_client()

    def tearDown(self):
        self.db.close()

    def heartbeat(self, *, key_digest=None, ready=False):
        with self.app.test_request_context():
            g.verified_device_id = 1
            return self.app.config["DEVICE_MANAGEMENT_HEARTBEAT"](
                1, "111111", self.installation_id, "host", key_digest or self.key_digest, ready,
            )

    def post(self, action, **fields):
        return self.client.post(self.route, data={"csrf": "lab-csrf", "action": action, **fields})

    def test_management_requires_feature_admin_csrf_and_enrollment(self):
        self.assertEqual(self.client.get(self.route).status_code, 404)
        self.assertEqual(self.heartbeat(), {})
        self.app.config["DEVICE_MANAGEMENT_ENABLED"] = True
        self.assertEqual(self.post("update", installation_id=self.installation_id).status_code, 409)
        self.heartbeat()
        self.assertEqual(self.post("update", csrf="wrong").status_code, 400)
        self.assertEqual(self.post("update", installation_id="b" * 32).status_code, 404)
        self.role = "tech"
        self.assertEqual(self.post("uninstall", installation_id=self.installation_id).status_code, 404)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM managed_device_operations").fetchone()[0], 0)

    def test_duplicate_requests_create_one_cancellable_job(self):
        self.app.config["DEVICE_MANAGEMENT_ENABLED"] = True
        self.heartbeat()
        self.assertEqual(self.client.get(self.route).status_code, 200)
        for action in ("update", "uninstall", "update"):
            self.assertEqual(self.post(action, installation_id=self.installation_id).status_code, 303)
        jobs = self.db.execute("SELECT * FROM managed_device_operations").fetchall()
        self.assertEqual(len(jobs), 1)
        self.assertEqual(jobs[0]["operation"], "update")
        self.assertEqual(self.post("cancel", operation_id=jobs[0]["id"]).status_code, 303)
        self.assertEqual(self.post("uninstall", installation_id=self.installation_id).status_code, 303)
        self.assertEqual(self.db.execute("SELECT event FROM audit ORDER BY rowid").fetchall()[1][0],
                         "device_operation_cancelled")

    def test_outbound_policy_is_reversible_and_bound_to_verified_installation(self):
        self.app.config["DEVICE_MANAGEMENT_ENABLED"] = True
        self.assertEqual(self.heartbeat(), {"outbound_blocked": False, "policy_revision": 0})
        self.assertEqual(self.post("block-outbound").status_code, 303)
        self.assertEqual(self.heartbeat(), {"outbound_blocked": True, "policy_revision": 1})
        self.assertEqual(self.post("block-outbound").status_code, 303)
        self.assertEqual(self.heartbeat()["policy_revision"], 1)
        self.assertEqual(self.post("allow-outbound").status_code, 303)
        self.assertEqual(self.heartbeat(), {"outbound_blocked": False, "policy_revision": 2})
        with self.assertRaises(Conflict):
            self.heartbeat(key_digest="2" * 64)
        self.db.execute("UPDATE devices SET customer_id = 20 WHERE id = 1")
        self.db.commit()
        self.assertEqual(self.post("uninstall", installation_id=self.installation_id).status_code, 409)

    def test_bootstrap_policy_requires_a_proven_native_id(self):
        self.app.config["DEVICE_MANAGEMENT_ENABLED"] = True
        bootstrap = self.app.config["DEVICE_MANAGEMENT_BOOTSTRAP_RESPONSE"]
        registration = {"management": {"installation_id": self.installation_id, "variant": "host"}}
        with self.app.test_request_context():
            response = bootstrap(registration, 1, "111111", self.public_key, {"registered": True})
            self.assertNotIn("management", response)
            g.verified_device_id = 1
            response = bootstrap(registration, 1, "111111", self.public_key, {"registered": True})
            self.assertEqual(response["management"], {"outbound_blocked": False, "policy_revision": 0})

    def test_claim_waits_for_session_and_busy_installer_can_retry(self):
        self.app.config["DEVICE_MANAGEMENT_ENABLED"] = True
        self.heartbeat()
        self.post("update", installation_id=self.installation_id)
        self.db.execute("INSERT INTO activity_sessions VALUES (1, 0, ?)", (int(time.time()),))
        self.db.commit()
        self.assertNotIn("job", self.heartbeat(ready="update"))
        self.db.execute("UPDATE activity_sessions SET closed = 1")
        self.db.commit()
        job = self.heartbeat(ready="update")["job"]
        self.assertEqual(job["operation"], "update")
        self.assertEqual(self.heartbeat(ready="update")["job"], job)
        self.assertEqual(self.post("cancel", operation_id=job["id"]).status_code, 404)
        route = "/client-management/operations/{}/result".format(job["id"])
        busy = {"result": "busy", "exit_code": 1618}
        self.assertEqual(self.client.post(route, json=busy, headers={"Authorization": "Bearer " + "x" * 43}).status_code, 404)
        headers = {"Authorization": "Bearer " + job["receipt"]}
        self.assertEqual(self.client.post(route, json=busy, headers=headers).status_code, 200)
        self.assertEqual(self.client.post(route, json=busy, headers=headers).status_code, 200)
        retry = self.heartbeat(ready="update")["job"]
        self.assertEqual(retry["id"], job["id"])
        self.assertNotEqual(retry["receipt"], job["receipt"])
        complete = {"result": "complete", "exit_code": 0}
        self.assertEqual(self.client.post(route, json=complete, headers=headers).status_code, 404)
        headers = {"Authorization": "Bearer " + retry["receipt"]}
        self.assertEqual(self.client.post(route, json=complete, headers=headers).status_code, 200)
        self.assertNotIn("job", self.heartbeat(ready=True))


if __name__ == "__main__":
    unittest.main()
