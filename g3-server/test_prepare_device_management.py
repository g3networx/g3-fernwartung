import runpy
import unittest
from pathlib import Path
from types import SimpleNamespace

from flask import Blueprint, Flask, abort, request


patch_application = runpy.run_path(
    str(Path(__file__).with_name("prepare-device-management.py"))
)["patch_application"]


class PortalPreparationTest(unittest.TestCase):
    def test_staged_portal_accepts_receipt_and_protects_browser_form(self):
        app = Flask(__name__)
        management = Blueprint("device_management", __name__)

        @management.post("/client-management/operations/7/result")
        def operation_result():
            if request.headers.get("Authorization") != "Bearer fixture-receipt":
                abort(404)
            return "", 200

        @management.post("/devices/1/management")
        def manage():
            return "", 204

        source = """\
@app.before_request
def guard():
    if request.method == 'POST' and request.endpoint not in ('client_bootstrap', 'client_session'):
        if request.form.get('csrf') != 'form-token':
            abort(403)
bootstrap_client.install(app, portal)
device_management.install(app, portal)
"""
        staged = patch_application(source)
        self.assertEqual(patch_application(staged), staged)
        exec(staged, dict(app=app, portal=None, request=request, abort=abort,
                          bootstrap_client=SimpleNamespace(install=lambda *_: None),
                          device_management=SimpleNamespace(install=lambda app, _: app.register_blueprint(management))))
        client = app.test_client()
        path = "/client-management/operations/7/result"
        self.assertEqual(client.post(path).status_code, 404)
        self.assertEqual(client.post(path, headers={"Authorization": "Bearer fixture-receipt"}).status_code, 200)
        self.assertEqual(client.post("/devices/1/management").status_code, 403)
