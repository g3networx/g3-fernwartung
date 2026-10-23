import 'package:flutter_test/flutter_test.dart';
import '../lib/g3_update_metadata.dart';

void main() {
  final digest = List.filled(64, 'a').join();

  test('accepts the published 82,432-byte Windows bootstrapper', () {
    expect(
      g3UpdateArtifactMetadataIsValid(
        sha256: digest,
        size: 82432,
        filename: 'g3-OpsLinX-1.5.0-g3.25-install.exe',
      ),
      isTrue,
    );
  });

  test('rejects undersized, oversized, malformed, or path-like metadata', () {
    expect(g3UpdateArtifactMetadataIsValid(
      sha256: digest, size: 16383, filename: 'setup.exe'), isFalse);
    expect(g3UpdateArtifactMetadataIsValid(
      sha256: digest, size: 150000001, filename: 'setup.exe'), isFalse);
    expect(g3UpdateArtifactMetadataIsValid(
      sha256: 'bad', size: 82432, filename: 'setup.exe'), isFalse);
    expect(g3UpdateArtifactMetadataIsValid(
      sha256: digest, size: 82432, filename: '../setup.exe'), isFalse);
  });
}
