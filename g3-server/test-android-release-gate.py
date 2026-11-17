"""Regression tests for the Android feed's three-node release gate."""
from hashlib import sha256
from importlib import import_module
from io import BytesIO, StringIO
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from urllib.error import HTTPError


gate = import_module('install-android-update-feed')


class Response(BytesIO):
    status = 200


class AndroidReleaseGate(unittest.TestCase):
    def setUp(self):
        root = Path(self.enterContext(TemporaryDirectory()))
        self.feed = root / 'android-update.conf'
        self.feed.write_bytes(b'previous feed')
        self.immutable = root / 'immutable.conf'
        self.immutable.write_text('# Existing immutable routes\n')
        site = root / 'nginx-site'
        include = f'include {self.immutable};'
        site.write_text(f'{include}\ninclude {self.feed};\n')
        self.apk = root / 'g3-OpsLinX-Android-1.5.3-g3.62.20089-arm64.apk'
        self.apk.write_bytes(b'new APK fixture')
        self.proof = self.apk.with_name(self.apk.name + '.certum.p7s')
        self.proof.write_bytes(b'new signature fixture')
        self.metadata = dict(version='1.5.3-g3.62.20089', file=self.apk.name,
                             size=self.apk.stat().st_size, sha256=sha256(self.apk.read_bytes()).hexdigest(),
                             certum_sha256=sha256(self.proof.read_bytes()).hexdigest())
        self.enterContext(patch.multiple(gate, ROOT=root, SNIPPET=self.feed, IMMUTABLE=self.immutable,
                                         ARTIFACTS_INCLUDE=include))
        self.enterContext(patch.object(gate, 'site_path', return_value=site))
        self.nginx = self.enterContext(patch.object(gate.subprocess, 'run'))
        self.certum = self.enterContext(patch.object(gate, 'verify_certum'))
        self.responses = {}
        for host in gate.NODES.values():
            self.responses[f'https://{host}/client/platform/android_arm64/20089.apk'] = self.apk.read_bytes()
            self.responses[f'https://{host}/client/platform/android_arm64/20089.certum.p7s'] = self.proof.read_bytes()
        self.opener = self.enterContext(patch.object(gate, 'build_opener')).return_value
        self.opener.open.side_effect = self.open

    def open(self, url, timeout):
        if url not in self.responses:
            raise HTTPError(url, 404, 'Missing fixture', {}, None)
        return Response(self.responses[url])

    def invoke(self, mode):
        with patch.object(sys, 'argv', ['install-android-update-feed.py', 'rustdesk', mode]), \
                patch.object(sys, 'stdin', StringIO(json.dumps(self.metadata))):
            gate.main()

    def test_staging_sets_versioned_routes_and_keeps_feed(self):
        self.invoke('--stage-apk')
        staged = self.immutable.read_bytes()
        self.invoke('--stage-apk')
        self.assertEqual(staged, self.immutable.read_bytes())
        self.assertIn(b'/android_arm64/20089.apk', staged)
        self.assertIn(b'/android_arm64/20089.certum.p7s', staged)
        self.assertEqual(self.feed.read_bytes(), b'previous feed')
        self.assertEqual(self.opener.open.call_count, 0)

    def test_missing_or_invalid_peer_artifact_keeps_feed(self):
        for suffix in ('apk', 'certum.p7s'):
            url = f'https://opslinx03.g3nx.net/client/platform/android_arm64/20089.{suffix}'
            correct = self.responses[url]
            for replacement in (None, b'wrong file'):
                with self.subTest(suffix=suffix, replacement=replacement):
                    if replacement is None:
                        del self.responses[url]
                    else:
                        self.responses[url] = replacement
                    with self.assertRaisesRegex(RuntimeError, 'opslinx03.g3nx.net'):
                        self.invoke('--activate-apk')
                    self.responses[url] = correct
                    self.assertEqual(self.feed.read_bytes(), b'previous feed')
                    self.assertFalse(self.apk.with_suffix('.json').exists())
                    self.nginx.assert_not_called()

    def test_invalid_local_certum_signature_keeps_feed(self):
        self.certum.side_effect = ValueError('wrong signer')
        with self.assertRaisesRegex(SystemExit, 'Invalid Android Certum signature'):
            self.invoke('--activate-apk')
        self.assertEqual(self.feed.read_bytes(), b'previous feed')
        self.opener.open.assert_not_called()
        self.nginx.assert_not_called()

    def test_all_three_matching_releases_activate_feed(self):
        self.invoke('--activate-apk')
        urls = {call.args[0] for call in self.opener.open.call_args_list}
        self.assertEqual(urls, set(self.responses))
        self.assertIn(self.apk.name.encode(), self.feed.read_bytes())
        metadata = json.loads(self.apk.with_suffix('.json').read_bytes())
        self.assertEqual(metadata, {key: self.metadata[key] for key in ('version', 'sha256', 'size')})


if __name__ == '__main__':
    unittest.main()
