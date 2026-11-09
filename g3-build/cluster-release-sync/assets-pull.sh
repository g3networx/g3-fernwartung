#!/bin/bash
set -euo pipefail
test "$(cat /opt/opslinx-ha/role)" != primary || exit 0
exec 9>/opt/opslinx-ha/assets.lock
flock -n 9 || exit 0
peer=$(python3 -c 'import json;print(json.load(open("/opt/opslinx-ha/node.json"))["peerIp"])')
transport='ssh -i /root/.ssh/opslinx-replication -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/opt/opslinx-ha/known_hosts -o ConnectTimeout=5'
rsync -a --ignore-existing --timeout=180 --exclude=current.json --exclude=downloads.json --exclude=platforms.json -e "$transport" "root@$peer:client/" /opt/rustdesk-client/
install -d -m 700 /opt/opslinx-ha/asset-selectors
for file in current.json downloads.json platforms.json; do
 rsync -a --timeout=30 -e "$transport" "root@$peer:client/$file" /opt/opslinx-ha/asset-selectors/
done
test "$(cat /opt/opslinx-ha/role)" != primary || exit 0
python3 - <<'PY'
import hashlib,json,os,pathlib,time
b=pathlib.Path('/opt/opslinx-ha');root=pathlib.Path('/opt/rustdesk-client').resolve();stage=b/'asset-selectors'
cachefile=b/'asset-hash-cache.json';cache=json.loads(cachefile.read_text()) if cachefile.exists() else {}
verified=0
def walk(value):
 global verified
 if isinstance(value,dict):
  if isinstance(value.get('file'),str) and isinstance(value.get('sha256'),str) and len(value['sha256'])==64 and isinstance(value.get('size'),int):
   target=(root/value['file']).resolve();assert target.is_relative_to(root),'Invalid asset path'
   info=target.stat();assert info.st_size==value['size']
   signature=str(info.st_size)+':'+str(info.st_mtime_ns)
   old=cache.get(str(target),{})
   if old.get('signature')!=signature:
    digest=hashlib.sha256()
    with target.open('rb') as f:
     for chunk in iter(lambda:f.read(1048576),b''):digest.update(chunk)
    old={'signature':signature,'sha256':digest.hexdigest()};cache[str(target)]=old
   assert old['sha256']==value['sha256'],'Asset hash mismatch'
   verified+=1
  for item in value.values():walk(item)
 elif isinstance(value,list):
  for item in value:walk(item)
documents={name:json.loads((stage/name).read_text()) for name in ['current.json','downloads.json','platforms.json']}

# A healthy older peer must not undo an already published release.
import re
def version(value):
 match=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)-g3\.(\d+)(?:\.(\d+))?',value or '')
 assert match,'Invalid release version'
 return tuple(int(n or 0) for n in match.groups())
assert documents['current.json']['version']==documents['downloads.json']['version'],'Torn peer release selectors'
for name in ['current.json','downloads.json']:
 local=root/name
 if not local.exists():continue
 existing=json.loads(local.read_text());incoming=documents[name]
 assert version(incoming['version'])>=version(existing['version']),'Refusing release downgrade: '+name
 if version(incoming['version'])==version(existing['version']):
  for key in ['windows','windows_msi','host','host_msi','source']:
   assert incoming.get(key)==existing.get(key),'Conflicting immutable release: '+key
local_platforms=root/'platforms.json'
if local_platforms.exists():
 for key,existing in json.loads(local_platforms.read_text()).items():
  incoming=documents['platforms.json'].get(key)
  if not isinstance(existing,dict) or 'version' not in existing:continue
  assert isinstance(incoming,dict),'Missing existing platform: '+key
  assert version(incoming['version'])>=version(existing['version']),'Refusing platform downgrade: '+key
  if version(incoming['version'])==version(existing['version']):
   assert all(incoming.get(k)==existing.get(k) for k in ['file','size','sha256']),'Conflicting platform package: '+key

for document in documents.values():walk(document)
assert verified>0,'No pinned asset metadata verified'
if (b/'WRITER-ACTIVE').exists() or (b/'role').read_text().strip()=='primary':
 print('Writer role active; peer selectors not applied');raise SystemExit(0)
for name in ['current.json','downloads.json','platforms.json']:
 temp=root/(name+'.ha-pending');temp.write_bytes((stage/name).read_bytes());temp.chmod(0o644);os.replace(temp,root/name)
cachefile.write_text(json.dumps(cache))
(b/'assets-status.json').write_text(json.dumps({'verifiedAt':time.time(),'pinnedReferencesVerified':verified,'existingImmutableFilesOverwritten':False}))
print('Asset selectors advanced after payload verification:',verified)
PY
