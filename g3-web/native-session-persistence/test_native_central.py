import json,time,unittest,urllib.error
from unittest.mock import patch
import test_native_addressbook as fixture
import central
m=fixture.m
(fixture.root/'keys/central.json').write_text(json.dumps({'client_secret':'fixture-only'}))
central.install(m.app,m)
class NativeCentral(unittest.TestCase):
 def test_durable_authority_outage_rights_and_block(self):
  base=fixture.NativeAddressBook();base.setUp()
  with m.app.test_request_context('/'):
   m.run("UPDATE users SET central_sub='1',central_admin=1 WHERE id=1")
   m.run("UPDATE sessions SET expires=0,central_token=?,central_checked=0 WHERE token=?",(m.enc('a'*96),base.sid))
   def row():return dict(m.db().execute('SELECT s.*,u.username,u.role,u.active,u.setup,u.central_sub,u.central_admin FROM sessions s JOIN users u ON u.id=s.uid WHERE s.token=?',(base.sid,)).fetchone())
   check=m.app.config['NATIVE_CENTRAL_CHECK']
   with patch('central.urllib.request.urlopen',side_effect=urllib.error.URLError('fixture outage')):
    self.assertIsNone(check(row()));self.assertIsNotNone(row())
   class Response:
    status=200
    def __init__(self,body):self.body=body
    def __enter__(self):return self
    def __exit__(self,*args):pass
    def read(self,*args):return json.dumps(self.body).encode()
   identity={'issuer':central.ISSUER,'sub':'1','login_id':'fixture','active':True,'mfa':True,'is_admin':False,'tenant_id':None}
   with patch('central.urllib.request.urlopen',return_value=Response({'active':True,'identity':identity})):
    refreshed=check(row());self.assertFalse(refreshed['central_admin']);self.assertEqual(refreshed['role'],'customer_tech')
   m.run('UPDATE sessions SET central_checked=0 WHERE token=?',(base.sid,))
   with patch('central.urllib.request.urlopen',return_value=Response({'active':False})):
    self.assertFalse(check(row()))
   self.assertIsNone(m.db().execute('SELECT 1 FROM sessions WHERE token=?',(base.sid,)).fetchone())
if __name__=='__main__':unittest.main()
