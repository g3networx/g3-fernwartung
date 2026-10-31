"""Short-lived one-use native client handoff. No password in browser URI."""
import secrets,time,hashlib,re
from flask import g,request,abort,render_template,jsonify

def install(app,m):
 original=m.init
 def init():
  original()
  with app.app_context():
   m.run('CREATE TABLE IF NOT EXISTS client_handoffs(token TEXT PRIMARY KEY,sid TEXT NOT NULL,did INTEGER NOT NULL,expires INTEGER NOT NULL)')
   if 'purpose' not in {r[1] for r in m.db().execute('PRAGMA table_info(client_handoffs)')}:
    m.run("ALTER TABLE client_handoffs ADD COLUMN purpose TEXT NOT NULL DEFAULT 'reveal'")
 m.init=init
 def connection_credential(d):
  if d['credential']:return d['credential']
  return app.config.get('PROVISION_PASSWORD',lambda cid:'')(d['customer_id'])
 def connect(did):
  d=m.device(did);m.limited('connect:'+str(g.user['uid']),120)
  if not m.access(d['customer_id'],'reveal') or not connection_credential(d):
   uri='g3fernwartung://'+d['rustdesk_id']
   return jsonify(uri=uri) if request.accept_mimetypes.best=='application/json' else render_template('connect.html',d=d,uri=uri)
  token=secrets.token_urlsafe(40)
  m.run('DELETE FROM client_handoffs WHERE expires<?',(int(time.time()),))
  m.run("INSERT INTO client_handoffs(token,sid,did,expires,purpose) VALUES(?,?,?,?,'connect')",(hashlib.sha256(token.encode()).hexdigest(),g.sid,did,int(time.time())+60))
  uri='g3fernwartung://g3-session/'+token;m.audit('client_handoff_created',did)
  return jsonify(uri=uri) if request.accept_mimetypes.best=='application/json' else render_template('connect.html',d=d,uri=uri)
 app.config['CLIENT_CONNECT']=connect
 @app.get('/devices/<int:did>/connect-advanced')
 @m.auth
 def connect_advanced(did):
  d=m.device(did)
  return render_template('start.html',d=d,uri='rustdesk://'+d['rustdesk_id'])
 @app.route('/devices/<int:did>/autologin',methods=['GET','POST'])
 @m.auth
 def autologin(did):
  d=m.device(did,'reveal');uri=None;error=None
  if not d['credential']:abort(404)
  if request.method=='POST':
   m.limited('autologin:'+str(g.user['uid']))
   if app.config.get('CENTRAL_REAUTH') and app.config['CENTRAL_REAUTH'](g.user):
    token=secrets.token_urlsafe(40)
    m.run('DELETE FROM client_handoffs WHERE expires<?',(int(time.time()),))
    m.run('INSERT INTO client_handoffs(token,sid,did,expires) VALUES(?,?,?,?)',(hashlib.sha256(token.encode()).hexdigest(),g.sid,did,int(time.time())+60))
    uri='g3fernwartung://g3-session/'+token;m.audit('client_handoff_created',did)
   else:error='Anmeldung fehlgeschlagen. Bitte Passwort und neuen Einmalcode prüfen.'
  return render_template('autologin.html',d=d,uri=uri,error=error)
 @app.get('/client-handoff')
 def redeem_client_handoff():
  bearer=request.headers.get('Authorization','')
  if not re.fullmatch(r'Bearer [A-Za-z0-9_-]{54}',bearer):abort(404)
  token=hashlib.sha256(bearer[7:].encode()).hexdigest()
  # DELETE RETURNING consumes atomically, even when two requests race.
  r=m.db().execute('DELETE FROM client_handoffs WHERE token=? RETURNING *',(token,)).fetchone();m.db().commit()
  if not r or r['expires']<time.time():abort(404)
  s=m.db().execute('SELECT s.*,u.username,u.role,u.active,u.setup,u.password,u.totp,u.last_totp,u.central_sub,u.central_admin FROM sessions s JOIN users u ON u.id=s.uid WHERE s.token=?',(r['sid'],)).fetchone()
  native=m.db().execute('SELECT 1 FROM native_ab_sessions WHERE token=?',(r['sid'],)).fetchone() if r['purpose']=='connect' else None
  if not s or not s['active'] or (not native and (s['expires']<time.time() or s['seen']<time.time()-1800)):abort(404)
  check=app.config.get('NATIVE_CENTRAL_CHECK') if native else app.config.get('CENTRAL_CHECK')
  checked=check(dict(s)) if check else dict(s)
  if native and checked is None:abort(503)
  if not checked:abort(404)
  g.user=dict(s) if checked is True else dict(checked)
  if g.user['central_admin']:g.user['role']='admin'
  d=m.device(r['did'],'reveal')
  credential=connection_credential(d) if r['purpose']=='connect' else d['credential']
  if not credential:abort(404)
  peer=request.headers.get('X-G3-Client-ID','')
  if re.fullmatch(r'[A-Za-z0-9_-]{6,40}',peer):
   m.run('DELETE FROM launch_attributions WHERE expires<?',(int(time.time()),))
   m.run('INSERT INTO launch_attributions VALUES(?,?,?,?,?)',(r['did'],peer,g.user['uid'],g.user['username'],int(time.time())+300))
  m.audit('client_handoff_redeemed',r['did'])
  return {'id':d['rustdesk_id'],'password':m.dec(credential)}
