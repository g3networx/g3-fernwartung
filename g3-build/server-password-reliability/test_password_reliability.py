from test_bootstrap_client import BootstrapTests,module
import base64,re

class PasswordReliabilityTests(BootstrapTests):
 def setUp(self):
  super().setUp()
  self.previous_standard=module.app.config['SERVICE_PASSWORD']
  module.app.config['SERVICE_PASSWORD']=lambda:'Fixture standard password!'
 def tearDown(self):
  module.app.config['SERVICE_PASSWORD']=self.previous_standard
 def modern(self, key=None):
  nonce=self.client.get('/client-bootstrap?id=100001',base_url=self.base).json['challenge']
  sig=(key or self.secret).sign(('g3-bootstrap-v1:100001:'+nonce).encode())
  data=dict(id='100001',challenge=nonce,signature=base64.b64encode(sig).decode(),credential_policy=2)
  return data,self.client.post('/client-bootstrap',base_url=self.base,json=data)
 def test_standard_and_custom_and_previous_customer_default_are_additive(self):
  with module.app.app_context():
   module.run('INSERT INTO client_passwords VALUES(?,?)',(1,module.enc('Fixture customer password!')))
   before=module.db().execute('SELECT credential FROM devices WHERE id=1').fetchone()[0]
  data,response=self.modern()
  self.assertEqual(response.status_code,200)
  self.assertEqual(set(response.json['additional_passwords']),{'Fixture standard password!','vault-secret-1','Fixture customer password!'})
  self.assertEqual(response.json['credential_policy'],2)
  self.assertNotIn('permanent_password',response.json)
  self.assertNotIn('provisioning_token',response.json)
  with module.app.app_context():
   self.assertEqual(module.db().execute('SELECT credential FROM devices WHERE id=1').fetchone()[0],before)
   self.assertEqual(module.db().execute('SELECT count(*) FROM device_provisioning').fetchone()[0],0)
 def test_empty_book_field_remains_empty_and_handoff_uses_standard(self):
  with module.app.app_context():
   module.run("UPDATE devices SET credential='' WHERE id=1")
   module.run('INSERT INTO client_passwords VALUES(?,?)',(1,module.enc('Different inherited default!')))
  self.login_as(2)
  page=self.post('/devices/1/start').data.decode()
  token=re.search(r'g3-session/([A-Za-z0-9_-]{54})',page).group(1)
  response=self.client.get('/client-handoff',base_url=self.base,headers={'Authorization':'Bearer '+token})
  self.assertEqual(response.status_code,200)
  self.assertEqual(response.json['password'],'Fixture standard password!')
  _,response=self.modern();self.assertIn('Fixture standard password!',response.json['additional_passwords'])
  with module.app.app_context():self.assertEqual(module.db().execute('SELECT credential FROM devices WHERE id=1').fetchone()[0],'')
 def test_explicit_book_handoff_stays_custom(self):
  self.login_as(2)
  page=self.post('/devices/1/start').data.decode()
  token=re.search(r'g3-session/([A-Za-z0-9_-]{54})',page).group(1)
  response=self.client.get('/client-handoff',base_url=self.base,headers={'Authorization':'Bearer '+token})
  self.assertEqual(response.json['password'],'vault-secret-1')
 def test_previously_applied_devices_still_get_current_supplemental_passwords(self):
  with module.app.app_context():
   module.run('INSERT INTO device_provisioning VALUES(?,?,?,1)',(1,module.enc('old-receipt'),module.enc('old-password')))
  _,a=self.modern();self.assertEqual(a.status_code,200)
  module.app.config['SERVICE_PASSWORD']=lambda:'Fixture changed standard!'
  _,b=self.modern();self.assertEqual(b.status_code,200)
  self.assertIn('Fixture changed standard!',b.json['additional_passwords'])
  self.assertIn('vault-secret-1',b.json['additional_passwords'])
 def test_missing_standard_refuses_modern_policy_without_any_write(self):
  module.app.config['SERVICE_PASSWORD']=lambda:''
  _,r=self.modern();self.assertEqual(r.status_code,503)
  with module.app.app_context():self.assertEqual(module.db().execute('SELECT count(*) FROM device_provisioning').fetchone()[0],0)
 def test_wrong_device_key_and_replay_do_not_expose_passwords(self):
  from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
  _,r=self.modern(Ed25519PrivateKey.generate());self.assertEqual(r.status_code,404)
  data,r=self.modern();self.assertEqual(r.status_code,200)
  r=self.client.post('/client-bootstrap',base_url=self.base,json=data)
  self.assertEqual(r.status_code,404);self.assertNotIn(b'Fixture standard',r.data)
 def test_supplemental_values_not_written_to_audit_or_vault_rows(self):
  self.modern()
  with module.app.app_context():
   text=str([tuple(r) for r in module.db().execute('SELECT * FROM audit')])
   self.assertNotIn('Fixture standard password!',text)
   self.assertEqual(module.dec(module.db().execute('SELECT credential FROM devices WHERE id=1').fetchone()[0]),'vault-secret-1')
