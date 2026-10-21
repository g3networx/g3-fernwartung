import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/g3_update_paths.dart';

void main() {
  test('concurrent downloads use separate folders under the fixed Windows root', () async {
    if (!Platform.isWindows) return;
    final directories = await Future.wait([
      g3UpdateDownloadDirectory(), g3UpdateDownloadDirectory(),
    ]);
    try {
      final root = '${Platform.environment['LOCALAPPDATA']}\\g3NetworX\\Fernwartung\\Downloads';
      expect(directories[0].path, isNot(directories[1].path));
      for (final directory in directories) {
        expect(directory.parent.absolute.path.toLowerCase(), root.toLowerCase());
        final file = File('${directory.path}\\candidate.exe');
        await file.writeAsBytes([1, 2, 3], flush: true);
        expect(await file.readAsBytes(), [1, 2, 3]);
      }
    } finally {
      for (final directory in directories) {
        await directory.delete(recursive: true);
      }
    }
  });
}
