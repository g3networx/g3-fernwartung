import 'package:flutter_test/flutter_test.dart';
import '../lib/g3_update_metadata.dart';

void main() {
  final digest = List.filled(64, 'a').join();

  test('accepts the published FullClient bootstrapper', () {
    expect(
      g3UpdateArtifactMetadataIsValid(
        sha256: digest,
        size: 82432,
        filename: 'g3-OpsLinX-1.5.0-g3.25-install.exe',
      ),
      isTrue,
    );
  });

  test('accepts small host bootstrapper metadata without a size floor', () {
    expect(
      g3UpdateArtifactMetadataIsValid(
        sha256: digest,
        size: 1024,
        filename: 'g3-OpsLinX-Host-install.exe',
      ),
      isTrue,
    );
  });

  test('rejects empty, oversized, malformed, or path-like metadata', () {
    expect(g3UpdateArtifactMetadataIsValid(
      sha256: digest, size: 0, filename: 'setup.exe'), isFalse);
    expect(g3UpdateArtifactMetadataIsValid(
      sha256: digest, size: 150000001, filename: 'setup.exe'), isFalse);
    expect(g3UpdateArtifactMetadataIsValid(
      sha256: 'bad', size: 82432, filename: 'setup.exe'), isFalse);
    expect(g3UpdateArtifactMetadataIsValid(
      sha256: digest, size: 82432, filename: '../setup.exe'), isFalse);
  });
}
