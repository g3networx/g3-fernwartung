"""Use the accepted installer pipeline with the g3.6.2 release metadata."""
import datetime
import json
from pathlib import Path

folder = Path(__file__).resolve().parent
release = json.loads((folder / 'local-addressbook-release.json').read_text())
date = datetime.date.fromisoformat(release['buildDate'])
assert release['displayVersion'] == 'g3.6.2 Build ' + date.strftime('%d%m%y')
assert 0 <= release['dailyInternalSequence'] < 8
counter = (date - datetime.date(2020, 1, 1)).days * 8 + release['dailyInternalSequence']
assert release['version'] == f'1.5.3-g3.62.{counter}'
assert release['windowsVersion'] == f'1.62.{counter}'
original = folder / 'package-password-reliability.py'
source = original.read_text()
for old, new in {
    '1.5.0-g3.60.19994': release['version'],
    'g3.6 Build 041126': release['displayVersion'],
    '2026-11-04': release['buildDate'],
    'g36-release': 'g361-release',
}.items():
    assert old in source, 'Reviewed packaging boundary changed: ' + old
    source = source.replace(old, new)
exec(compile(source, str(original), 'exec'), {'__name__': '__main__', '__file__': str(original)})
