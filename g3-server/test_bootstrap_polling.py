import base64
import json
from unittest.mock import patch

from test_bootstrap_client import BootstrapTests, module
from bootstrap_polling import heartbeat_token


class PollingTests(BootstrapTests):
    def setUp(self):
        super().setUp()
        (module.KEYS / 'service-password').write_text(module.enc('bootstrap-lab-fixture-only'))
        with module.app.app_context():
            for table in ('managed_installations', 'managed_device_operations',
                          'managed_outbound_policy', 'activity_sessions'):
                module.run('DELETE FROM ' + table)

    def proof(self, management=None):
        challenge = self.client.get('/client-bootstrap?id=100001', base_url=self.base).json['challenge']
        payload = {'id': '100001', 'credential_policy': 2, 'challenge': challenge,
                   'signature': base64.b64encode(self.secret.sign(
                       ('g3-bootstrap-v1:100001:' + challenge).encode())).decode()}
        if management:
            payload['management'] = management
        response = self.client.post('/client-bootstrap', base_url=self.base, json=payload)
        self.assertEqual(response.status_code, 200)
        return response.json

    def heartbeat(self, token, **fields):
        return self.client.post('/client-heartbeat', base_url=self.base,
                                headers={'Authorization': 'Bearer ' + token},
                                json={'id': '100001', **fields})

    def test_many_devices_behind_nat_and_legacy_proof_do_not_use_sql_rate_limits(self):
        key = json.loads((module.DATA / 'peer-public-keys.json').read_text())['100001']
        with module.app.app_context():
            for i in range(200000, 200080):
                module.run('INSERT INTO devices(customer_id,name,rustdesk_id) VALUES(1,?,?)', ('Lab', str(i)))
        (module.DATA / 'peer-public-keys.json').write_text(json.dumps({
            '100001': key, **{str(i): key for i in range(200000, 200080)}}))
        with patch.object(module, 'limited', side_effect=AssertionError('SQL-backed limiter used')):
            for i in range(200000, 200080):
                response = self.client.get('/client-bootstrap?id=' + str(i), base_url=self.base)
                self.assertEqual(response.status_code, 200)
            self.assertTrue(self.proof()['registered'])
        self.assertEqual(self.client.get('/client-bootstrap', base_url=self.base).status_code, 404)

    def test_heartbeat_preserves_management_and_idle_reads_need_no_sql_writes(self):
        management = {'installation_id': 'b' * 32, 'variant': 'full',
                      'uninstall_supported': True, 'update_ready': True}
        offer = self.proof(management)
        token = offer['heartbeat_token']
        self.assertIn('activity_token', offer)
        self.assertIn('additional_passwords', offer)
        self.assertFalse(self.heartbeat(token).json.get('management', {}).get('outbound_blocked', False))
        with module.app.app_context():
            module.run("INSERT INTO managed_outbound_policy VALUES(1,1,'100001',1,1)")
            job = module.run('''INSERT INTO managed_device_operations
                (device_id,installation_id,operation,state,created,created_by)
                VALUES(1,?,'update','queued',strftime('%s','now'),0)''', ('b' * 32,)).lastrowid
            module.run("INSERT INTO activity_sessions VALUES('lab-live',1,0,1,strftime('%s','now'),0,0)")
        response = self.heartbeat(token, management=management)
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json['management']['outbound_blocked'])
        self.assertNotIn('job', response.json['management'])
        with module.app.app_context():
            module.run("UPDATE activity_sessions SET closed=1 WHERE event='lab-live'")
        self.assertEqual(self.heartbeat(token, management=management).json['management']['job']['id'], job)
        statements = []
        with module.app.app_context():
            module.db().set_trace_callback(statements.append)
            for _ in range(12):
                self.assertEqual(self.heartbeat(token).status_code, 200)
        self.assertFalse(any(sql.lstrip().upper().startswith(('INSERT', 'DELETE', 'UPDATE', 'BEGIN', 'COMMIT'))
                             for sql in statements), statements)

    def test_heartbeat_grant_is_not_an_activity_token_and_expires_or_key_changes_rebootstrap(self):
        offer = self.proof()
        self.assertEqual(self.heartbeat(offer['activity_token']).status_code, 404)
        self.assertEqual(self.heartbeat(offer['heartbeat_token'], id='100002').status_code, 404)
        key = bytes.fromhex(json.loads((module.DATA / 'peer-public-keys.json').read_text())['100001'])
        self.assertEqual(self.heartbeat(heartbeat_token(module.app, '100001', key, 1)).status_code, 404)
        (module.DATA / 'peer-public-keys.json').write_text(json.dumps({'100001': ('ff' * 32)}))
        self.assertEqual(self.heartbeat(offer['heartbeat_token']).status_code, 404)
