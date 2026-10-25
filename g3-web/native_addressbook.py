"""Scoped native address book, approved through the existing g3 browser login."""
import base64, hashlib, re, secrets, time
from flask import g, request, abort, redirect, render_template, jsonify
from native_addressbook_edit import install as install_edit, capabilities, book_permissions

def digest(value):
 return hashlib.sha256(value.encode()).hexdigest()

def install(app, m):
 previous=m.init
 def init():
  previous()
  with app.app_context():
   m.run('CREATE TABLE IF NOT EXISTS native_ab_requests(device_hash TEXT PRIMARY KEY,request_id TEXT UNIQUE NOT NULL,challenge TEXT NOT NULL,display_code TEXT NOT NULL,expires INTEGER NOT NULL,sid TEXT)')
   m.run('CREATE TABLE IF NOT EXISTS native_ab_sessions(token TEXT PRIMARY KEY)')
 m.init=init

 def native_json():
  if request.headers.get('Origin') is not None or request.headers.get('X-G3-Native')!='1' or not request.is_json:abort(403)
  return request.get_json(silent=True) or {}

 def identity():
  bearer=request.headers.get('Authorization','')
  if not re.fullmatch(r'Bearer [A-Za-z0-9_-]{43}',bearer):abort(401)
  sid=digest(bearer[7:]);now=int(time.time())
  row=m.db().execute('SELECT s.*,u.username,u.role,u.active,u.setup,u.password,u.totp,u.last_totp,u.central_sub,u.central_admin FROM native_ab_sessions n JOIN sessions s ON s.token=n.token JOIN users u ON u.id=s.uid WHERE n.token=?',(sid,)).fetchone()
  if not row or not row['active'] or row['setup']:abort(401)
  check=app.config.get('NATIVE_CENTRAL_CHECK') or app.config.get('CENTRAL_CHECK')
  checked=check(dict(row)) if check else dict(row)
  if checked is None:abort(503)
  if not checked:abort(401)
  g.sid=sid;g.user=dict(row) if checked is True else dict(checked)
  if g.user['central_admin']:g.user['role']='admin'
  m.run('UPDATE sessions SET seen=? WHERE token=?',(now,sid))
  return g.user

 @app.post('/client-addressbook/login/start')
 def native_ab_start():
  data=native_json();challenge=data.get('challenge','')
  if not isinstance(challenge,str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}',challenge):abort(400)
  m.limited('native-ab-start:'+request.remote_addr,30)
  now=int(time.time());device=secrets.token_urlsafe(32);rid=secrets.token_urlsafe(24);display=secrets.token_hex(3).upper()
  m.run('DELETE FROM native_ab_requests WHERE expires<?',(now,))
  m.run('INSERT INTO native_ab_requests VALUES(?,?,?,?,?,NULL)',(digest(device),rid,challenge,display,now+600))
  return dict(device_code=device,verification_uri='https://rust.g3nx.net/client-addressbook/authorize?request='+rid,display_code=display,expires_in=600)

 @app.route('/client-addressbook/authorize',methods=['GET','POST'])
 def native_ab_authorize():
  rid=request.values.get('request','')
  if not re.fullmatch(r'[A-Za-z0-9_-]{32}',rid):abort(404)
  row=m.db().execute('SELECT * FROM native_ab_requests WHERE request_id=? AND expires>?',(rid,int(time.time()))).fetchone()
  if not row:abort(404)
  if not g.get('user'):
   response=redirect('/login');response.set_cookie('__Host-g3-native-login',rid,max_age=600,secure=True,httponly=True,samesite='Lax',path='/');return response
  if g.user['setup']:abort(403)
  if request.method=='POST':
   if request.form.get('decision')=='deny':
    m.run('DELETE FROM native_ab_requests WHERE request_id=?',(rid,));return render_template('native_addressbook.html',done=True,denied=True)
   if request.form.get('decision')!='approve':abort(400)
   m.run('UPDATE native_ab_requests SET sid=? WHERE request_id=? AND sid IS NULL',(g.sid,rid));m.audit('native_addressbook_approved')
   return render_template('native_addressbook.html',done=True,denied=False)
  return render_template('native_addressbook.html',done=False,entry=row)

 @app.after_request
 def native_ab_login_return(response):
  rid=request.cookies.get('__Host-g3-native-login','')
  if request.endpoint in ('login','central_callback') and response.status_code==302 and response.location=='/' and re.fullmatch(r'[A-Za-z0-9_-]{32}',rid):
   response.location='/client-addressbook/authorize?request='+rid
   response.delete_cookie('__Host-g3-native-login',secure=True,httponly=True,samesite='Lax',path='/')
  return response

 @app.post('/client-addressbook/login/poll')
 def native_ab_poll():
  data=native_json();device=data.get('device_code','');verifier=data.get('verifier','')
  if not isinstance(device,str) or not isinstance(verifier,str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}',device) or not re.fullmatch(r'[A-Za-z0-9_-]{43,128}',verifier):abort(400)
  key=digest(device);row=m.db().execute('SELECT * FROM native_ab_requests WHERE device_hash=?',(key,)).fetchone()
  challenge=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
  if not row or row['expires']<=time.time() or not secrets.compare_digest(row['challenge'],challenge):abort(401)
  if not row['sid']:return dict(pending=True),202
  source=m.db().execute('SELECT s.*,u.username,u.role,u.active,u.setup,u.password,u.totp,u.last_totp,u.central_sub,u.central_admin FROM sessions s JOIN users u ON u.id=s.uid WHERE s.token=?',(row['sid'],)).fetchone()
  if not source or not source['active'] or source['setup'] or source['expires']<=time.time() or source['seen']<=time.time()-1800:abort(401)
  checked=app.config['CENTRAL_CHECK'](dict(source)) if app.config.get('CENTRAL_CHECK') else dict(source)
  if not checked:abort(401)
  consumed=m.db().execute('DELETE FROM native_ab_requests WHERE device_hash=? RETURNING device_hash',(key,)).fetchone();m.db().commit()
  if not consumed:abort(401)
  central_token=source['central_token']
  if app.config.get('NATIVE_CENTRAL_GRANT'):
   central_token=app.config['NATIVE_CENTRAL_GRANT'](dict(source))
  token=secrets.token_urlsafe(32);sid=digest(token);now=int(time.time())
  m.run('INSERT INTO sessions(token,uid,expires,seen,central_token,central_checked) VALUES(?,?,?,?,?,?)',(sid,source['uid'],0,now,central_token,0))
  m.run('INSERT INTO native_ab_sessions VALUES(?)',(sid,))
  return dict(token=token,expires_in=None)

 @app.get('/client-addressbook/tree')
 def native_ab_tree():
  user=identity();books=m.visible_customers('view');allowed={b['id'] for b in books}
  devices=[]
  for d in m.db().execute('SELECT id,customer_id,name,rustdesk_id FROM devices ORDER BY name COLLATE NOCASE'):
   if d['customer_id'] in allowed:
    devices.append(dict(d,presence=app.jinja_env.globals['device_presence'](d['rustdesk_id'])))
  return jsonify(username=user['username'].removeprefix('portal:'),capabilities=capabilities(m,user,books),books=[dict(id=b['id'],parent_id=b['parent_id'] if b['parent_id'] in allowed else None,name=b['name'],path=b['path'],**book_permissions(m,user,b)) for b in books],devices=devices)

 @app.post('/client-addressbook/connect')
 def native_ab_connect():
  data=native_json();identity();did=data.get('device_id')
  if type(did) is not int:abort(400)
  m.device(did,'view')
  m.limited('native-ab-connect:'+str(g.user['uid']),120)
  # Reuse the existing one-use handoff and its current permission check.
  return app.config['CLIENT_CONNECT'](did)

 @app.post('/client-addressbook/logout')
 def native_ab_logout():
  native_json();identity()
  if app.config.get('NATIVE_CENTRAL_REVOKE'):app.config['NATIVE_CENTRAL_REVOKE'](g.user)
  m.run('DELETE FROM native_ab_sessions WHERE token=?',(g.sid,));m.run('DELETE FROM sessions WHERE token=?',(g.sid,));m.audit('native_addressbook_logout')
  return dict(logged_out=True)

 install_edit(app,m,identity,native_json)
