"""Actual app/permissions and one-use connection handoff, disposable database only."""
import os, pathlib, tempfile, secrets, hashlib, base64, time, unittest
from cryptography.fernet import Fernet
tmp=tempfile.TemporaryDirectory();root=pathlib.Path(tmp.name);(root/'keys').mkdir()
(root/'keys/vault.key').write_bytes(Fernet.generate_key());(root/'keys/session.key').write_text(secrets.token_urlsafe(64));(root/'keys/rustdesk.pub').write_text('fixture')
os.environ['ADDRESSBOOK_DATA']=str(root/'data');os.environ['ADDRESSBOOK_KEYS']=str(root/'keys')
import app as m
m.app.config['TESTING']=True;m.init()

class NativeAddressBook(unittest.TestCase):
 def setUp(self):
  self.client=m.app.test_client();self.browser=m.app.test_client();self.base='https://rust.g3nx.net'
  self.headers={'X-G3-Native':'1','Accept':'application/json'}
  self.verifier=secrets.token_urlsafe(32)
  with m.app.app_context():
   for name in ('native_ab_requests','native_ab_sessions','client_handoffs','grants','devices','sessions','customers','users','audit','attempts'):m.run('DELETE FROM '+name)
   m.run("INSERT INTO users(id,username,password,role,setup) VALUES(1,'portal:fixture','unused','customer_tech',0)")
   m.run("INSERT INTO customers(id,name,parent_id) VALUES(1,'Own',NULL),(2,'Hidden',NULL),(3,'Own child',1)")
   m.run('INSERT INTO grants VALUES(1,1,1,1)')
   for did,cid in ((1,1),(2,2),(3,3)):
    m.run('INSERT INTO devices(id,customer_id,name,rustdesk_id,credential) VALUES(?,?,?,?,?)',(did,cid,'Device'+str(did),str(10000000+did),m.enc('test-secret')))
   sid=secrets.token_urlsafe(32);self.sid=hashlib.sha256(sid.encode()).hexdigest()
   m.run('INSERT INTO sessions(token,uid,expires,seen) VALUES(?,?,?,?)',(self.sid,1,int(time.time())+3600,int(time.time())))
  self.browser.set_cookie('__Host-rdab',sid,domain='rust.g3nx.net',secure=True)
 def post(self,path,body,client=None,headers=None):
  return (client or self.client).post('/client-addressbook/'+path,json=body,headers=headers or self.headers,base_url=self.base)
 def start(self):
  challenge=base64.urlsafe_b64encode(hashlib.sha256(self.verifier.encode()).digest()).decode().rstrip('=')
  r=self.post('login/start',{'challenge':challenge});self.assertEqual(r.status_code,200);return r.json
 def approve(self,flow):
  page=self.browser.get(flow['verification_uri'],base_url=self.base);self.assertEqual(page.status_code,200)
  import re
  csrf=re.search('name="csrf" value="([^"]+)"',page.data.decode()).group(1)
  return self.browser.post(flow['verification_uri'],data={'csrf':csrf,'request':flow['verification_uri'].split('request=')[1],'decision':'approve'},base_url=self.base)
 def grant(self):
  flow=self.start();self.assertEqual(self.approve(flow).status_code,200)
  r=self.post('login/poll',{'device_code':flow['device_code'],'verifier':self.verifier});self.assertEqual(r.status_code,200)
  self.headers['Authorization']='Bearer '+r.json['token'];return flow
 def test_approval_pkce_and_single_redemption(self):
  flow=self.start()
  body={'device_code':flow['device_code'],'verifier':self.verifier}
  self.assertEqual(self.post('login/poll',body).status_code,202)
  self.assertEqual(self.post('login/poll',dict(body,verifier='x'*43)).status_code,401)
  self.assertEqual(self.approve(flow).status_code,200)
  self.assertEqual(self.post('login/poll',body).status_code,200)
  self.assertEqual(self.post('login/poll',body).status_code,401)
  self.assertEqual(self.post('login/start',{'challenge':'x'*43},headers=dict(self.headers,Origin='https://evil.invalid')).status_code,403)
 def test_tree_rights_connection_and_revocation(self):
  self.grant()
  tree=self.client.get('/client-addressbook/tree',headers=self.headers,base_url=self.base)
  self.assertEqual(tree.status_code,200);self.assertEqual({b['id'] for b in tree.json['books']},{1,3});self.assertEqual({d['id'] for d in tree.json['devices']},{1,3})
  self.assertNotIn(b'test-secret',tree.data);self.assertNotIn(b'credential',tree.data)
  self.assertEqual(self.post('connect',{'device_id':2}).status_code,404)
  handoff=self.post('connect',{'device_id':1});self.assertEqual(handoff.status_code,200);self.assertIn('/g3-session/',handoff.json['uri'])
  handoff_token=handoff.json['uri'].split('/')[-1]
  redeemed=self.client.get('/client-handoff',headers={'Authorization':'Bearer '+handoff_token},base_url=self.base)
  self.assertEqual(redeemed.status_code,200);self.assertEqual(redeemed.json,{'id':'10000001','password':'test-secret'})
  self.assertEqual(self.client.get('/client-handoff',headers={'Authorization':'Bearer '+handoff_token},base_url=self.base).status_code,404)
  with m.app.app_context():m.run('UPDATE grants SET can_reveal=0 WHERE uid=1')
  plain=self.post('connect',{'device_id':1});self.assertEqual(plain.json['uri'],'g3fernwartung://10000001')
  with m.app.app_context():m.run('DELETE FROM grants WHERE uid=1')
  self.assertEqual(self.post('connect',{'device_id':1}).status_code,404)
  self.assertEqual(self.client.get('/client-addressbook/tree',headers=self.headers,base_url=self.base).json['devices'],[])
  self.assertEqual(self.post('logout',{}).status_code,200)
  self.assertEqual(self.client.get('/client-addressbook/tree',headers=self.headers,base_url=self.base).status_code,401)
 def test_remembered_session_survives_age_idle_and_browser_cleanup(self):
  self.grant()
  token_hash=hashlib.sha256(self.headers['Authorization'][7:].encode()).hexdigest()
  with m.app.test_request_context('/login'):
   m.run('UPDATE sessions SET seen=? WHERE token=?',(int(time.time())-400*86400,token_hash))
   user=m.db().execute('SELECT * FROM users WHERE id=1').fetchone()
   m.create_session(user)
   self.assertIsNotNone(m.db().execute('SELECT 1 FROM sessions WHERE token=?',(token_hash,)).fetchone())
  self.assertEqual(self.client.get('/client-addressbook/tree',headers=self.headers,base_url=self.base).status_code,200)
  with m.app.app_context():m.run('UPDATE sessions SET expires=? WHERE token=?',(int(time.time())-1,token_hash))
  self.assertEqual(self.client.get('/client-addressbook/tree',headers=self.headers,base_url=self.base).status_code,200)
  handoff=self.post('connect',{'device_id':1});self.assertEqual(handoff.status_code,200)
  redeemed=self.client.get('/client-handoff',headers={'Authorization':'Bearer '+handoff.json['uri'].split('/')[-1]},base_url=self.base)
  self.assertEqual(redeemed.status_code,200)
 def test_native_outage_keeps_grant_and_account_block_denies(self):
  self.grant()
  m.app.config['NATIVE_CENTRAL_CHECK']=lambda row:None
  try:
   self.assertEqual(self.client.get('/client-addressbook/tree',headers=self.headers,base_url=self.base).status_code,503)
   m.app.config['NATIVE_CENTRAL_CHECK']=lambda row:dict(row)
   self.assertEqual(self.client.get('/client-addressbook/tree',headers=self.headers,base_url=self.base).status_code,200)
   m.app.config['NATIVE_CENTRAL_CHECK']=lambda row:False
   self.assertEqual(self.client.get('/client-addressbook/tree',headers=self.headers,base_url=self.base).status_code,401)
  finally:m.app.config.pop('NATIVE_CENTRAL_CHECK')
 def test_browser_csrf_and_disabled_user_central_revocation(self):
  flow=self.start()
  self.assertEqual(self.browser.post(flow['verification_uri'],data={'decision':'approve'},base_url=self.base).status_code,403)
  self.grant()
  m.app.config['CENTRAL_CHECK']=lambda row:False
  try:self.assertEqual(self.client.get('/client-addressbook/tree',headers=self.headers,base_url=self.base).status_code,401)
  finally:m.app.config.pop('CENTRAL_CHECK')
  with m.app.app_context():m.run('UPDATE users SET active=0 WHERE id=1')
  self.assertEqual(self.client.get('/client-addressbook/tree',headers=self.headers,base_url=self.base).status_code,401)
 def test_native_edit_create_update_delete_and_password_preservation(self):
  self.grant()
  created=self.post('books/save',{'name':'New book','parent_id':1});self.assertEqual(created.status_code,200);cid=created.json['id']
  self.assertEqual(self.post('books/save',{'name':'Root','parent_id':None}).status_code,403)
  new=self.post('devices/save',{'customer_id':cid,'name':'New device','rustdesk_id':'123456789','notes':'Note','username':'fixture-user','credential':'fixture-only-secret'});self.assertEqual(new.status_code,200);did=new.json['id']
  form=self.client.get('/client-addressbook/devices/'+str(did),headers=self.headers,base_url=self.base)
  self.assertEqual(form.json['username'],'fixture-user');self.assertTrue(form.json['has_credential']);self.assertNotIn(b'fixture-only-secret',form.data)
  self.assertEqual(self.post('books/delete',{'id':cid}).status_code,409)
  saved=self.post('devices/save',{'id':did,'customer_id':cid,'name':'Renamed','rustdesk_id':'123456789','notes':'New note'})
  self.assertEqual(saved.status_code,200)
  with m.app.app_context():
   row=m.db().execute('SELECT * FROM devices WHERE id=?',(did,)).fetchone();self.assertEqual(m.dec(row['credential']),'fixture-only-secret');self.assertEqual(m.decrypt_username(row['username']),'fixture-user');self.assertEqual(row['notes'],'New note')
  self.assertEqual(self.post('devices/delete',{'id':did}).status_code,200)
  self.assertEqual(self.post('books/delete',{'id':cid}).status_code,200)
 def test_native_edit_permission_rechecks_and_credentials_require_reveal(self):
  self.grant()
  self.assertEqual(self.post('devices/save',{'id':2,'customer_id':1,'name':'No','rustdesk_id':'12345678'}).status_code,404)
  with m.app.app_context():m.run('UPDATE grants SET can_reveal=0 WHERE uid=1')
  form=self.client.get('/client-addressbook/devices/1',headers=self.headers,base_url=self.base)
  self.assertFalse(form.json['can_reveal']);self.assertEqual(form.json['username'],'')
  body={'id':1,'customer_id':1,'name':'Allowed note','rustdesk_id':'10000001','notes':'Changed'}
  self.assertEqual(self.post('devices/save',dict(body,credential='denied')).status_code,403)
  self.assertEqual(self.post('devices/save',dict(body,username='denied')).status_code,403)
  self.assertEqual(self.post('devices/save',body).status_code,200)
  with m.app.app_context():self.assertEqual(m.dec(m.db().execute('SELECT credential FROM devices WHERE id=1').fetchone()[0]),'test-secret')
  self.assertEqual(self.post('devices/save',dict(body,customer_id=3)).status_code,403)
  with m.app.app_context():m.run('UPDATE grants SET can_edit=0 WHERE uid=1')
  self.assertEqual(self.post('devices/save',body).status_code,404)
  self.assertEqual(self.post('books/save',{'id':1,'name':'Denied'}).status_code,404)
 def test_native_mutations_reject_browser_origin_and_missing_authority(self):
  self.grant()
  body={'id':1,'name':'Denied'}
  self.assertEqual(self.post('books/save',body,headers=dict(self.headers,Origin='https://rust.g3nx.net')).status_code,403)
  self.assertEqual(self.post('books/save',body,headers={'X-G3-Native':'1'}).status_code,401)
  with m.app.app_context():m.run('UPDATE users SET active=0 WHERE id=1')
  self.assertEqual(self.post('devices/delete',{'id':1}).status_code,401)
if __name__=='__main__':unittest.main()
