"""Compare identity material in memory. Never emit credential or private-key values."""
import hashlib,json,sys,tomllib
payload=json.load(sys.stdin);before=tomllib.loads(payload['before']);after=tomllib.loads(payload['after'])
protected=('id','enc_id','password','salt','key_pair')
def digest(value):return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()
def material(data):return {k:data.get(k,'' if k!='key_pair' else [[],[]]) for k in protected}
a=material(before);b=material(after)
def valid_pair(data):
 pair=data.get('key_pair',[])
 return isinstance(pair,list) and len(pair)==2 and all(isinstance(p,list) for p in pair) and len(pair[0])==64 and len(pair[1])==32
old_hosts=before.get('keys_confirmed',{});new_hosts=after.get('keys_confirmed',{})
added=set(new_hosts)-set(old_hosts)
allowed_added={'linx.g3nx.net','linx.g3nx.net:21116'}
host_migration=(all(new_hosts.get(k)==v for k,v in old_hosts.items()) and added<=allowed_added and all(new_hosts[k] is True for k in added))
changed=[k for k in sorted(set(before)|set(after)) if before.get(k)!=after.get(k)]
other_unchanged=all(before.get(k)==after.get(k) for k in set(before)|set(after) if k not in ('keys_confirmed',))
result=dict(protectedFieldsPreserved=a==b,validBeforeKeyPair=valid_pair(before),validAfterKeyPair=valid_pair(after),beforeProtectedSha256=digest(a),afterProtectedSha256=digest(b),changedFields=changed,addedServerConfirmations=sorted(added),onlyKnownHaServerConfirmationAdded=host_migration and other_unchanged,rawMainFileUnchanged=payload['before']==payload['after'])
print(json.dumps(result))
