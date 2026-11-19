"""Add the VAS module to an explicitly staged OpsLinX portal tree."""
from pathlib import Path
from shutil import copy2
import sys

stage = Path(sys.argv[1]).resolve(strict=True)
bundle = Path(__file__).resolve().parent / 'portal'
guard = stage / 'app.py'
addressbook = stage / 'native_addressbook.py'

target = {
    guard: ("'native_ab_connect','native_ab_logout'",
            "'native_ab_connect','native_ab_vas_start','native_ab_logout'"),
    addressbook: (
        ' install_edit(app,m,identity,native_json)',
        ' install_edit(app,m,identity,native_json)\n'
        ' from opstalx_vas import configure, install as install_vas\n'
        ' configure(app)\n'
        ' install_vas(app,m,identity,native_json)',
    )
}
edits = {}
for path, (before, after) in target.items():
    source = path.read_text(encoding='utf-8')
    if after in source:
        continue
    if source.count(before) != 1:
        raise SystemExit(f'Unsupported portal revision in {path.name}')
    edits[path] = source.replace(before, after)
for path, result in edits.items():
    compile(result, str(path), 'exec')
for name in ('opstalx_vas.py','templates/opstalx_vas.html'):
    copy2(bundle / name, stage / name)
for path, result in edits.items():
    path.write_text(result, encoding='utf-8')
