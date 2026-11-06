"""Read embedded cabinets without executing Windows Installer actions."""
from pathlib import Path
import ctypes as c, hashlib, json, subprocess

folder=Path.cwd();stage=folder/'outputs';out=folder/'work/msi-readonly-verification';out.mkdir(parents=True,exist_ok=True)
metadata=json.loads((folder/'g3-build/local-addressbook-release.json').read_text());version=metadata['version'];expected_version=metadata['windowsVersion']
msi=c.WinDLL('msi');handle=c.c_uint
msi.MsiOpenDatabaseW.argtypes=[c.c_wchar_p,c.c_wchar_p,c.POINTER(handle)]
msi.MsiDatabaseOpenViewW.argtypes=[handle,c.c_wchar_p,c.POINTER(handle)]
msi.MsiViewExecute.argtypes=[handle,handle]
msi.MsiViewFetch.argtypes=[handle,c.POINTER(handle)]
msi.MsiRecordGetStringW.argtypes=[handle,c.c_uint,c.c_wchar_p,c.POINTER(c.c_uint)]
msi.MsiRecordReadStream.argtypes=[handle,c.c_uint,c.c_void_p,c.POINTER(c.c_uint)]
def ok(r):
 if r:raise RuntimeError('MSI readonly API error '+str(r))
def string(r,n):
 size=c.c_uint(4096);b=c.create_unicode_buffer(4096);ok(msi.MsiRecordGetStringW(r,n,b,c.byref(size)));return b.value
def exports(data):
 import struct
 def u16(n):return struct.unpack_from('<H',data,n)[0]
 def u32(n):return struct.unpack_from('<I',data,n)[0]
 pe=u32(0x3c);assert data[pe:pe+4]==b'PE\0\0'
 count=u16(pe+6);optional=pe+24;magic=u16(optional);assert magic in (0x20b,0x10b)
 sections=optional+u16(pe+20)
 def offset(rva):
  for i in range(count):
   sec=sections+40*i;va=u32(sec+12);size=max(u32(sec+8),u32(sec+16))
   if va<=rva<va+size:
    result=u32(sec+20)+rva-va;assert result<len(data);return result
  raise RuntimeError('Unmapped PE export address')
 directory=offset(u32(optional+(112 if magic==0x20b else 96)))
 names=u32(directory+24);assert names<=65536;table=offset(u32(directory+32));result=set()
 for i in range(names):
  begin=offset(u32(table+4*i));end=data.find(b'\0',begin,begin+256);assert end>begin
  result.add(data[begin:end].decode('ascii'))
 return result
proof={};required_exports={'g3_otp_probe_begin','g3_otp_probe_open','g3_otp_probe_free','g3_otp_probe_cancel'}
for kind,file in [('windows','g3-OpsLinX-'+version+'-install.msi'),('host','g3-OpsLinX-Host-'+version+'-host-install.msi')]:
 db=handle();ok(msi.MsiOpenDatabaseW(str(stage/file),None,c.byref(db)))
 def rows(sql):
  v=handle();ok(msi.MsiDatabaseOpenViewW(db,sql,c.byref(v)));ok(msi.MsiViewExecute(v,0))
  try:
   while True:
    r=handle();code=msi.MsiViewFetch(v,c.byref(r))
    if code==259:break
    ok(code)
    try:yield r
    finally:msi.MsiCloseHandle(r)
  finally:msi.MsiCloseHandle(v)
 upgrade_code=[string(r,1) for r in rows("SELECT `Value` FROM `Property` WHERE `Property`='UpgradeCode'")]
 assert len(upgrade_code)==1
 expected_app='g3Host' if kind=='host' else 'g3Fernwartung'
 services=[(string(r,1),string(r,2),string(r,3)) for r in rows('SELECT `Name`,`Arguments`,`StartType` FROM `ServiceInstall`')]
 assert services==[(expected_app,'--service','2')],'MSI variant or service configuration differs'
 tables={string(r,1) for r in rows('SELECT `Name` FROM `_Tables`')}
 for table in ('Registry','RemoveRegistry'):
  if table in tables:
   assert not any('credentialanchor' in string(r,1).lower() for r in rows('SELECT `Key` FROM `'+table+'`')),'Credential anchor is owned or removed by MSI'
 files={string(r,1):string(r,2).split('|')[-1] for r in rows('SELECT `File`,`FileName` FROM `File`')}
 assert not any('local-addressbook' in name.lower() for name in files.values()),'MSI must not own local user address books'
 product_version=[string(r,1) for r in rows("SELECT `Value` FROM `Property` WHERE `Property`='ProductVersion'")];assert product_version==[expected_version]
 target=out/kind;target.mkdir(exist_ok=True)
 for r in rows('SELECT `Name`,`Data` FROM `_Streams`'):
  data=bytearray()
  while True:
   size=c.c_uint(65536);b=c.create_string_buffer(65536);ok(msi.MsiRecordReadStream(r,2,b,c.byref(size)));data.extend(b.raw[:size.value])
   if not size.value:break
  if not data.startswith(b'MSCF'):continue
  cab=target/'payload.cab';cab.write_bytes(data)
  subprocess.run([str(Path(__import__('os').environ['SystemRoot'])/'System32/expand.exe'),'-F:*',str(cab),str(target)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
 hashes={}
 for fileid,name in files.items():
  p=target/fileid
  if p.exists() and name in ('g3Fernwartung.exe','g3Host-ui.exe','g3Host.exe','librustdesk.dll','dylib_virtual_display.dll'):
   hashes[name]=hashlib.sha256(p.read_bytes()).hexdigest()
   if name=='librustdesk.dll':assert required_exports<=exports(p.read_bytes()),'OTP receiver exports missing from embedded native runtime'
 proof[kind]=dict(productVersion=product_version[0],sha256=hashes,upgradeCode=upgrade_code[0],services=services,localAddressBooksNotOwned=True,credentialAnchorNotOwnedOrRemoved=True)
 msi.MsiCloseHandle(db)
assert proof['windows']['sha256']['g3Fernwartung.exe']==proof['host']['sha256']['g3Host-ui.exe']
assert proof['windows']['upgradeCode']!=proof['host']['upgradeCode']
provenance=json.loads((stage/'g361-release-provenance.json').read_text(encoding='utf-8-sig'));assert provenance['native_rebuilt'] and provenance['source_commit']==__import__('os').environ['GITHUB_SHA'];expected=provenance['native_sha256']
assert proof['windows']['sha256']['librustdesk.dll']==proof['host']['sha256']['librustdesk.dll']==expected
assert proof['host']['sha256']['g3Host.exe']=='32b98ed09a141e92ac2f2d602401c5e417a1511c7f494824424fe90ff78c03d0'
assert proof['windows']['sha256']['dylib_virtual_display.dll']==proof['host']['sha256']['dylib_virtual_display.dll']
proof['otpNativeExportsVerified']=True
proof['sourceCommit']=__import__('os').environ['GITHUB_SHA']
proof['readOnly']=True
proof['installationExecuted']=False
assert proof['windows']['sha256']['g3Fernwartung.exe']==hashlib.sha256((folder/'flutter/build/windows/x64/runner/Release/rustdesk.exe').read_bytes()).hexdigest()
(stage/'g361-msi-readonly-verification.json').write_text(json.dumps(proof,indent=2))
print(json.dumps(proof,indent=2))
