"""Native editing with the existing address-book edit/reveal boundaries."""
import re, sqlite3
from flask import g, abort, jsonify


def capabilities(m, user, books):
 return dict(can_create_root=user['role'] in ('admin','tech'),can_move_devices=user['role'] in ('admin','tech'),can_delete_devices=user['role'] in ('admin','tech','customer_tech'))


def book_permissions(m, user, book):
 edit=m.access(book['id'],'edit')
 return dict(can_edit=edit,can_add_book=edit and user['role'] in ('admin','tech','customer_tech'),can_delete=edit and user['role'] in ('admin','tech','customer_tech') and not book['central_tenant'],can_reveal=m.access(book['id'],'reveal'))


def install(app, m, identity, native_json):
 def text(data, key, limit=200, required=True):
  value=data.get(key,'')
  if not isinstance(value,str):abort(400)
  value=value.strip()
  if len(value)>limit or (required and not value):abort(400)
  return value

 def integer(data,key,optional=False):
  value=data.get(key)
  if optional and value is None:return None
  if type(value) is not int or value<=0:abort(400)
  return value

 def book(cid,permission='edit'):
  row=m.db().execute('SELECT * FROM customers WHERE id=?',(cid,)).fetchone()
  if not row or not m.access(cid,permission):abort(404)
  return row

 def mutation():
  data=native_json();identity();m.limited('native-ab-edit:'+str(g.user['uid']),60)
  return data

 @app.get('/client-addressbook/devices/<int:did>')
 def native_ab_device_form(did):
  identity();d=m.device(did,'edit');reveal=m.access(d['customer_id'],'reveal')
  return jsonify(id=d['id'],customer_id=d['customer_id'],name=d['name'],rustdesk_id=d['rustdesk_id'],notes=d['notes'],username=m.decrypt_username(d['username']) if reveal else '',can_reveal=reveal,has_credential=bool(d['credential']))

 @app.post('/client-addressbook/devices/save')
 def native_ab_device_save():
  data=mutation();did=integer(data,'id',True);d=m.device(did,'edit') if did else None
  cid=integer(data,'customer_id');book(cid)
  if d and cid!=d['customer_id'] and g.user['role'] not in ('admin','tech'):abort(403)
  rid=re.sub(r'\s+','',text(data,'rustdesk_id',40))
  if not re.fullmatch(r'[A-Za-z0-9_-]{6,32}',rid):abort(400)
  name=text(data,'name');notes=text(data,'notes',4000,False)
  username=d['username'] if d else '';password=data.get('credential','');clear=data.get('clear_credential',False)
  if not isinstance(password,str) or len(password)>4096 or type(clear) is not bool:abort(400)
  if 'username' in data:
   value=text(data,'username',200,False)
   if not m.access(cid,'reveal'):abort(403)
   username=m.encrypt_username(value)
  if (password or clear) and not m.access(cid,'reveal'):abort(403)
  credential=m.enc(password) if password or clear else (d['credential'] if d else '')
  try:
   if d:m.run('UPDATE devices SET customer_id=?,name=?,rustdesk_id=?,username=?,notes=?,credential=? WHERE id=?',(cid,name,rid,username,notes,credential,did))
   else:did=m.run('INSERT INTO devices(customer_id,name,rustdesk_id,username,notes,credential) VALUES(?,?,?,?,?,?)',(cid,name,rid,username,notes,credential)).lastrowid
  except sqlite3.IntegrityError:abort(400)
  m.audit('device_saved',did);return dict(saved=True,id=did)

 @app.post('/client-addressbook/devices/delete')
 def native_ab_device_delete():
  data=mutation();did=integer(data,'id')
  if g.user['role'] not in ('admin','tech','customer_tech'):abort(403)
  m.device(did,'edit');m.run('DELETE FROM devices WHERE id=?',(did,));m.audit('device_deleted',did)
  return dict(deleted=True)

 @app.post('/client-addressbook/books/save')
 def native_ab_book_save():
  data=mutation();cid=integer(data,'id',True);name=text(data,'name')
  if cid:
   book(cid);m.run('UPDATE customers SET name=? WHERE id=?',(name,cid));m.audit('customer_updated',cid)
  else:
   parent=integer(data,'parent_id',True)
   if g.user['role'] not in ('admin','tech','customer_tech') or (g.user['role']=='customer_tech' and parent is None):abort(403)
   if parent:
    book(parent);depth=0;p=parent
    while p:
     depth+=1;row=m.db().execute('SELECT parent_id FROM customers WHERE id=?',(p,)).fetchone()
     if not row or depth>=24:abort(400)
     p=row[0]
   cid=m.run('INSERT INTO customers(name,parent_id) VALUES(?,?)',(name,parent)).lastrowid;m.audit('customer_created',cid)
  return dict(saved=True,id=cid)

 @app.post('/client-addressbook/books/delete')
 def native_ab_book_delete():
  data=mutation();cid=integer(data,'id')
  if g.user['role'] not in ('admin','tech','customer_tech'):abort(403)
  connection=m.db()
  try:
   connection.execute('BEGIN IMMEDIATE');row=book(cid)
   if row['central_tenant'] or connection.execute('SELECT 1 FROM devices WHERE customer_id=? UNION ALL SELECT 1 FROM customers WHERE parent_id=? LIMIT 1',(cid,cid)).fetchone():abort(409)
   connection.execute('DELETE FROM grants WHERE customer_id=?',(cid,));connection.execute('DELETE FROM customers WHERE id=?',(cid,));connection.commit()
  except Exception:
   connection.rollback();raise
  m.audit('customer_deleted',cid)
  return dict(deleted=True)
