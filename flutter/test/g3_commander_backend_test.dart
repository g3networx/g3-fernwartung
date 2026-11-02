import 'dart:io';
import 'package:flutter_hbb/desktop/pages/g3_commander_backend.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class FileSession implements FFI {
  @override
  String id = 'fixture-file-session';
  @override
  UuidValue get sessionId => UuidValue('00000000-0000-4000-8000-000000000001');
  @override
  late final FfiModel ffiModel = FfiModel(WeakReference(this));
  @override
  late final FileModel fileModel = FileModel(WeakReference(this));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('Only the file session controls readiness and file-pane updates', () {
    final session = FileSession();
    final backend = NativeCommanderBackend(session);
    var changes = 0;
    backend.addListener(() => changes++);
    expect(backend.ready, isFalse);
    session.ffiModel.pi.version = '1.4.4';
    session.fileModel.remoteController.homePath = r'C:\Users\test';
    session.fileModel.remoteController.directory.value = FileDirectory()
      ..path = r'D:\Files';
    expect(backend.ready, isTrue);
    expect(backend.path(false), r'D:\Files');
    expect(changes, greaterThan(0));
    backend.dispose();
    final previous = changes;
    session.fileModel.remoteController.directory.value = FileDirectory()
      ..path = r'D:\Other';
    expect(changes, previous);
  });

  test('Preview is bounded plain text and never launches files', () async {
    final backend = NativeCommanderBackend(FileSession());
    final dir = await Directory.systemTemp.createTemp('commander-fixture-');
    try {
      final text = File('${dir.path}/text.txt');
      await text.writeAsString('Hallo Datei');
      expect(await backend.readPreview(text), 'Hallo Datei');
      await text.writeAsBytes([0, 1, 2]);
      expect(await backend.readPreview(text), contains('Binärdatei'));
      await text.writeAsBytes(
          List.filled(NativeCommanderBackend.previewLimit + 1, 65));
      expect(await backend.readPreview(text), contains('1 MiB'));
    } finally {
      backend.dispose();
      await dir.delete(recursive: true);
    }
  });

  test(
      'Drive-root copies and invalid new folder names are rejected before dispatch',
      () async {
    final session = FileSession();
    final backend = NativeCommanderBackend(session);
    session.fileModel.remoteController.options.value.isWindows = true;
    session.fileModel.remoteController.directory.value = FileDirectory()
      ..path = '/';
    try {
      await expectLater(backend.copy(true, ['missing']), throwsStateError);
      await expectLater(backend.mkdir(false, '..'), throwsStateError);
      await expectLater(backend.mkdir(false, 'New'), throwsStateError);
    } finally {
      backend.dispose();
    }
  });
}
