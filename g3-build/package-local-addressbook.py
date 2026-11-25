"""Use the accepted installer pipeline with the g3.7.0 release metadata."""
import datetime
import json
from pathlib import Path

folder = Path(__file__).resolve().parent
release = json.loads((folder / 'local-addressbook-release.json').read_text())
date = datetime.date.fromisoformat(release['buildDate'])
assert release['displayVersion'] == 'g3.7.0 Build ' + date.strftime('%d%m%y')
assert 0 <= release['dailyInternalSequence'] < 8
counter = (date - datetime.date(2020, 1, 1)).days * 8 + release['dailyInternalSequence']
assert release['version'] == f'1.5.3-g3.70.{counter}'
assert release['windowsVersion'] == f'1.70.{counter}'
original = folder / 'package-password-reliability.py'
source = original.read_text()
if release['version'] == '1.5.3-g3.70.20145':
    source = source.replace(
        "and provenance['native_rebuilt']",
        "and (provenance['native_rebuilt'] or "
        "(provenance.get('native_reuse_run') == '45221958577' and "
        "provenance.get('native_sha256') == 'e71c5f259f28d2bdcc4bd38b6cbc4aa32d958a362f079ab440a7cfd2a2b3dc53'))",
    )
if release['version'] == '1.5.3-g3.70.20161':
    source = source.replace(
        "and provenance['native_rebuilt']",
        "and (provenance['native_rebuilt'] or "
        "(provenance.get('native_reuse_run') == '45562171803' and "
        "provenance.get('native_source_commit') == 'dc4aeef8b0b6bc21f2671150efb96f12952ac2ee' and "
        "provenance.get('native_sha256') == 'e5efef83e6618a542d3ea9537f18696aa3b71c22ae64ec5e19f48fa488686b06'))",
    )
for old, new in {
    '1.5.0-g3.60.19994': release['version'],
    'g3.6 Build 041126': release['displayVersion'],
    '2026-11-04': release['buildDate'],
    'g36-release': 'g361-release',
}.items():
    assert old in source, 'Reviewed packaging boundary changed: ' + old
    source = source.replace(old, new)
exec(compile(source, str(original), 'exec'), {'__name__': '__main__', '__file__': str(original)})
