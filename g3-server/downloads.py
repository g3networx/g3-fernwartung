"""Public, manifest-pinned client downloads."""
import base64,json,re
from pathlib import Path
from flask import abort,render_template,send_file
ROOT=Path('/opt/rustdesk-client')
def install(app,m):
 def platform_release():
  try:data=json.loads((ROOT/'platforms.json').read_text(encoding='utf-8'))
  except (OSError,ValueError):return {}
  if not isinstance(data,dict):return {}
  allowed={'macos_intel':'.dmg','macos_arm64':'.dmg','linux_x86_64':'.deb','linux_arm64':'.deb'}
  result={}
  for kind,suffix in allowed.items():
   item=data.get(kind)
   if not isinstance(item,dict) or item.get('published') is not True:continue
   name=item.get('file','')
   if not isinstance(name,str) or Path(name).name!=name or not name.endswith(suffix):continue
   digest=item.get('sha256','')
   if not isinstance(digest,str) or not re.fullmatch('[a-f0-9]{64}',digest) or not (ROOT/name).is_file():continue
   item=dict(item)
   if not str(item.get('source_url','')).startswith('https://github.com/g3networx/g3-fernwartung/'):item.pop('source_url',None)
   result[kind]=item
  return result
 app.jinja_env.globals['platform_downloads']=platform_release
 @app.get('/client/platform/<kind>')
 def platform_file(kind):
  item=platform_release().get(kind)
  if not item:abort(404)
  response=send_file(ROOT/item['file'],as_attachment=True,download_name=item['file'],conditional=True)
  response.headers['X-Content-Type-Options']='nosniff'
  return response
 def package_response(name,kind):
  response=send_file(ROOT/name,as_attachment=True,download_name=name,conditional=True)
  if kind in ('windows','host','adhoc','windows_msi','host_msi'):
   try:
    with (ROOT/(name+'.p7s')).open('rb') as sidecar: signature=sidecar.read(4097)
   except FileNotFoundError: signature=b''
   if 0<len(signature)<=4096:
    response.headers['X-OpsLinX-Signature']=base64.b64encode(signature).decode('ascii')
  response.headers['X-Content-Type-Options']='nosniff'
  return response
 def release():
  try:return json.loads((ROOT/'current.json').read_text(encoding='utf-8'))
  except (OSError,ValueError):return None
 # Public downloads advance independently of legacy update feeds.
 def public_release():
  try:data=json.loads((ROOT/'downloads.json').read_text(encoding='utf-8'))
  except FileNotFoundError:return release()
  except (OSError,ValueError):return None
  return data if isinstance(data,dict) else None
 app.jinja_env.globals['client_available']=lambda:public_release() is not None
 @app.get('/licenses')
 def licenses():
  return render_template('licenses.html')
 @app.get('/client/releases')
 def client_releases():
  versions=[]
  for file in (ROOT/'releases').glob('*.json'):
   if re.fullmatch(r'\d+\.\d+\.\d+-g3\.\d+(?:\.\d+)?',file.stem):versions.append(file.stem)
  return render_template('releases.html',versions=sorted(versions,reverse=True))
 @app.get('/client/releases/<version>/<kind>')
 def client_release_file(version,kind):
  if not re.fullmatch(r'\d+\.\d+\.\d+-g3\.\d+(?:\.\d+)?',version) or kind not in ('source','dependencies','license','windows_msi','host_msi','windows','host'):abort(404)
  try:item=json.loads((ROOT/'releases'/(version+'.json')).read_text(encoding='utf-8'))[kind]
  except (OSError,ValueError,KeyError):abort(404)
  name=item['file']
  if Path(name).name!=name or not (ROOT/name).is_file():abort(404)
  return package_response(name,kind)
 def update_metadata(data):
  result={k:data[k] for k in ('version','windows','adhoc','host') if k in data}
  # Pre-g3.40 clients accept only integer g3 release identifiers.
  match=re.fullmatch(r'(\d+\.\d+\.\d+-g3\.\d+)\.\d+',data.get('version',''))
  if match:result.update(version=match[1],release_version=data['version'])
  return result
 @app.get('/client/update.json')
 def client_update():
  if (ROOT/'update-hold').exists():abort(503)
  data=release()
  if not data:abort(404)
  return update_metadata(data)
 @app.get('/client/update-v2.json')
 def client_update_v2():
  if (ROOT/'update-v2-hold').exists():abort(503)
  data=release()
  if not data or data.get('session_guard')!=1:abort(503)
  return update_metadata(data)
 @app.get('/client')
 def client_download():
  data=public_release()
  if not data:abort(404)
  return render_template('client.html',release=data)
 @app.get('/client/download/<kind>')
 def client_file(kind):
  data=public_release()
  if not data or kind not in ('windows','source','license','dependencies','adhoc','host','certificate','windows_msi','host_msi') or kind not in data:abort(404)
  item=data[kind];name=item['file']
  if Path(name).name!=name or not (ROOT/name).is_file():abort(404)
  return package_response(name,kind)

