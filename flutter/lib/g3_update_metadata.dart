const int g3MinimumUpdateArtifactSize = 16 * 1024;
const int g3MaximumUpdateArtifactSize = 150000000;

bool g3UpdateArtifactMetadataIsValid({
  required String sha256,
  required int size,
  required String filename,
}) {
  return RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) &&
      size >= g3MinimumUpdateArtifactSize &&
      size <= g3MaximumUpdateArtifactSize &&
      RegExp(r'^[A-Za-z0-9._-]+\.(exe|msi)$').hasMatch(filename);
}
