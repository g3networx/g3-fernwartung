import hashlib,json,subprocess,sys,tempfile,unittest
from pathlib import Path
code=Path(__file__).with_name('assets-pull.sh').read_text().split("python3 - <<'PY'\n",1)[1].rsplit('\nPY',1)[0]
class AssetSyncTests(unittest.TestCase):
 def apply(self,current,incoming,corrupt=False,writer=False,adhoc=None):
  with tempfile.TemporaryDirectory() as tmp:
   b=Path(tmp)/'ha';root=Path(tmp)/'client';stage=b/'asset-selectors';stage.mkdir(parents=True);root.mkdir()
   (b/'role').write_text('standby')
   if writer:(b/'WRITER-ACTIVE').write_text('test')
   payload=b'accepted package';(root/'package.exe').write_bytes(payload)
   item=dict(file='package.exe',size=len(payload),sha256=hashlib.sha256(payload).hexdigest())
   for name in ['current.json','downloads.json']:
    previous=dict(version=current,windows=item)
    value=dict(version=incoming,windows=dict(item))
    if adhoc:
     for manifest,v in [(previous,adhoc[0]),(value,adhoc[1])]:
      file='g3-Soforthilfe-'+v+'-adhoc.exe';(root/file).write_bytes(payload)
      manifest['adhoc']=dict(item,file=file)
    (root/name).write_text(json.dumps(previous))
    if corrupt:value['windows']['sha256']='0'*64
    (stage/name).write_text(json.dumps(value))
   for parent in [root,stage]:(parent/'platforms.json').write_text('{}')
   modified=code.replace("b=pathlib.Path('/opt/opslinx-ha');root=pathlib.Path('/opt/rustdesk-client').resolve();stage=b/'asset-selectors'",f"b=pathlib.Path({str(b)!r});root=pathlib.Path({str(root)!r}).resolve();stage=b/'asset-selectors'")
   result=subprocess.run([sys.executable,'-c',modified],capture_output=True,text=True)
   return result.returncode,json.loads((root/'current.json').read_text())['version'],result.stderr
 def test_new_release_advances_only_with_verified_packages(self):
  self.assertEqual(self.apply('1.5.0-g3.40.2','1.5.0-g3.61.20032')[:2],(0,'1.5.0-g3.61.20032'))
  code,version,error=self.apply('1.5.0-g3.40.2','1.5.0-g3.61.20032',corrupt=True)
  self.assertNotEqual(code,0);self.assertEqual(version,'1.5.0-g3.40.2');self.assertIn('hash mismatch',error)
 def test_stale_peer_cannot_revert_latest_release(self):
  code,version,error=self.apply('1.5.0-g3.61.20032','1.5.0-g3.40.2')
  self.assertNotEqual(code,0);self.assertEqual(version,'1.5.0-g3.61.20032');self.assertIn('Refusing release downgrade',error)
 def test_new_writer_does_not_apply_peer_selectors(self):
  self.assertEqual(self.apply('1.5.0-g3.40.2','1.5.0-g3.61.20032',writer=True)[:2],(0,'1.5.0-g3.40.2'))
 def test_soforthilfe_cannot_regress_with_same_or_newer_fullclient(self):
  for main in ['1.5.0-g3.61.20032','1.5.0-g3.61.20040']:
   result=self.apply('1.5.0-g3.61.20032',main,adhoc=('1.5.0-g3.61.20032','1.5.0-g3.22'))
   self.assertNotEqual(result[0],0);self.assertIn('Refusing Soforthilfe downgrade',result[2])
 def test_soforthilfe_can_advance_independently(self):
  self.assertEqual(self.apply('1.5.0-g3.61.20032','1.5.0-g3.61.20032',adhoc=('1.5.0-g3.22','1.5.0-g3.61.20032'))[0],0)
if __name__=='__main__':unittest.main()
