"""One-use Ed25519 proof lets an existing enrolled client enable reporting after upgrade."""
import secrets,hashlib,time,json,base64,re
from flask import request,abort,g
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from bootstrap_polling import BootstrapTraffic,heartbeat,heartbeat_token

def install(app,m):
 traffic=BootstrapTraffic()
 old=m.init
 def init():
  old()
  with app.app_context():
   m.run('CREATE TABLE IF NOT EXISTS bootstrap_challenges(token TEXT PRIMARY KEY,device_id INTEGER NOT NULL,expires INTEGER NOT NULL)')
   m.run('CREATE TABLE IF NOT EXISTS system_customers(kind TEXT PRIMARY KEY,customer_id INTEGER NOT NULL)')
 m.init=init
 @app.route('/client-heartbeat',methods=['POST'])
 @app.route('/client-bootstrap',methods=['GET','POST'])
 def client_bootstrap():
  data=request.get_json(silent=True) or {} if request.method=='POST' else request.args
  if not isinstance(data,dict) and request.method=='POST':abort(400)
  if request.path=='/client-heartbeat':return heartbeat(app,m,data,traffic)
  rid=data.get('id','')
  if not isinstance(rid,str) or not re.fullmatch(r'[A-Za-z0-9_-]{6,40}',rid):abort(404)
  d=m.db().execute('SELECT id FROM devices WHERE rustdesk_id=?',(rid,)).fetchone()
  adhoc=data.get('adhoc') in (True,'1')
  if not d and not adhoc:abort(404)
  try:pk=bytes.fromhex(json.loads((m.DATA/'peer-public-keys.json').read_text(encoding='utf-8'))[rid])
  except (OSError,KeyError,ValueError,TypeError):abort(404)
  if request.method=='GET':
   traffic.limited(('device',rid,str(request.remote_addr)) if d else ('adhoc',str(request.remote_addr)),120 if d else 6000);nonce=secrets.token_urlsafe(32)
   traffic.cleanup(m)
   m.run('INSERT INTO bootstrap_challenges VALUES(?,?,?)',(hashlib.sha256(nonce.encode()).hexdigest(),d['id'] if d else 0,int(time.time())+60))
   return {'challenge':nonce}
  nonce=data.get('challenge','');signature=data.get('signature','')
  if not isinstance(nonce,str) or not isinstance(signature,str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}',nonce):abort(404)
  row=m.db().execute('DELETE FROM bootstrap_challenges WHERE token=? AND device_id=? RETURNING expires',(hashlib.sha256(nonce.encode()).hexdigest(),d['id'] if d else 0)).fetchone();m.db().commit()
  if not row or row[0]<time.time():abort(404)
  try:Ed25519PublicKey.from_public_bytes(pk).verify(base64.b64decode(signature,validate=True),('g3-bootstrap-v1:'+rid+':'+nonce).encode())
  except Exception:abort(404)
  g.verified_device_id=d['id'] if d else None
  if not d:
   name=data.get('name',rid)
   if not isinstance(name,str) or not name.strip() or len(name)>200:abort(400)
   m.db().execute('BEGIN IMMEDIATE')
   d=m.db().execute('SELECT id FROM devices WHERE rustdesk_id=?',(rid,)).fetchone()
   if not d:
    root=m.db().execute("SELECT c.id FROM system_customers s JOIN customers c ON c.id=s.customer_id WHERE s.kind='adhoc'").fetchone()
    if root:cid=root[0]
    else:
     cid=m.db().execute('INSERT INTO customers(name) VALUES(?)',('Nicht zugeordnete Soforthilfe',)).lastrowid
     m.db().execute("INSERT INTO system_customers VALUES('adhoc',?) ON CONFLICT(kind) DO UPDATE SET customer_id=excluded.customer_id",(cid,))
    did=m.db().execute('INSERT INTO devices(customer_id,name,rustdesk_id) VALUES(?,?,?)',(cid,name.strip(),rid)).lastrowid
    d={'id':did}
   m.db().commit()
  g.verified_device_id=d['id']
  if data.get('credential_policy')==2:
   result=app.config['ACTIVITY_OFFER'](d['id'],True)
   result.update(app.config['CREDENTIAL_OFFER'](d['id']))
   result['registered']=True
   result['heartbeat_token']=heartbeat_token(app,rid,pk)
   management=app.config.get('DEVICE_MANAGEMENT_BOOTSTRAP_RESPONSE')
   return management(data,d['id'],rid,pk,result) if management else result
  pending=m.db().execute('SELECT d.customer_id FROM devices d JOIN device_provisioning p ON p.device_id=d.id WHERE d.id=? AND p.applied=0',(d['id'],)).fetchone()
  result=app.config['PROVISION_OFFER'](d['id'],pending['customer_id'],True) if pending else app.config['ACTIVITY_OFFER'](d['id'],True)
  result['registered']=True
  return result
