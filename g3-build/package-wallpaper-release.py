"""Package the exact accepted g3.33 binaries without recompiling the product."""
from pathlib import Path
import hashlib, io, json, os, shutil, subprocess, zipfile

root = Path.cwd()
out = root / 'outputs'
out.mkdir(exist_ok=True)
archive = Path(os.environ['G3_WALLPAPER_ACCEPTED_ARCHIVE'])
assert hashlib.sha256(archive.read_bytes()).hexdigest() == 'a329b203fa8735110068172981a49bb293ec8e57077dce2a67c2ee5bbcd35df3'
assert not subprocess.check_output(['git', 'diff', '8d39c46438df0d06cbc186897767f713769dbd6a', 'HEAD', '--', 'src', 'Cargo.toml', 'flutter', 'g3-build/SetupBootstrap.cs', 'g3-build/package-msi.py', 'g3-build/build-setup-launchers.py']).strip()
payload = root / 'flutter/build/windows/x64/runner/Release'
payload.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(archive) as outer:
    provenance = json.loads(outer.read('corrected-core-provenance.json'))
    assert provenance['native_sha256'] == 'ce2b6fef64620cb3ee2918d7245259edd758059dadf8f6437a2d47b72426fbec'
    with zipfile.ZipFile(io.BytesIO(outer.read('g3-wallpaper-corrected-native-test-payload.zip'))) as binaries:
        assert binaries.read('rustdesk.exe') == binaries.read('g3Fernwartung.exe')
        for member in binaries.infolist():
            if member.is_dir() or member.filename in ('g3Host.exe', 'g3Fernwartung.exe'):
                continue
            assert '..' not in Path(member.filename).parts and not Path(member.filename).is_absolute()
            binaries.extract(member, payload)
        (out / 'g3Host.exe').write_bytes(binaries.read('g3Host.exe'))
assert hashlib.sha256((payload / 'librustdesk.dll').read_bytes()).hexdigest() == provenance['native_sha256']
shutil.copy2(root / 'LICENCE', payload / 'LICENCE')
(payload / 'SOURCE.txt').write_text('https://github.com/g3networx/g3-fernwartung/tree/' + os.environ['GITHUB_SHA'] + '\n', encoding='utf8')
for kind in ('windows', 'host'):
    (root / 'g3-build/msi' / kind).mkdir(parents=True, exist_ok=True)
subprocess.run(['python', 'g3-build/package-msi.py', '--version', '1.5.0-g3.33'], check=True)
subprocess.run(['python', 'g3-build/build-setup-launchers.py', '--version', '1.5.0-g3.33'], check=True)
provenance.update(packaging_source_commit=os.environ['GITHUB_SHA'], packaging_run=os.environ['GITHUB_RUN_ID'], native_build_run=41065143187, native_rebuilt=False, frontends_rebuilt=False, practical_tests_waived_by_user=True, practical_tests_verified=False)
(out / 'g333-release-provenance.json').write_text(json.dumps(provenance, indent=2), encoding='utf8')
items = {p.name: {'file': p.name, 'size': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in out.glob('g3-OpsLinX-*') if p.suffix in ('.exe', '.msi')}
assert len(items) == 4
(out / 'g333-package-hashes.json').write_text(json.dumps(items, indent=2), encoding='utf8')
