from pathlib import Path
import os,sys,json,hashlib,subprocess
platform,arch=sys.argv[1:];files=list(Path('.').glob('g3-Fernwartung-*.'+('dmg' if platform=='macos' else 'deb')))
assert files,'No platform package generated'
out={'version':os.environ.get('VERSION','1.5.0-g3.18'),'source_commit':os.environ['GITHUB_SHA'],'run_id':os.environ['GITHUB_RUN_ID'],'platform':platform,'arch':arch,'publicly_trusted_signature':False,'runtime_acceptance':'not yet performed','files':[{'file':p.name,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'size':p.stat().st_size}for p in files]}
if Path('g3-native-source.json').exists():out['native_origin']=json.loads(Path('g3-native-source.json').read_text())
Path(f'platform-provenance-{platform}-{arch}.json').write_text(json.dumps(out,indent=2))
