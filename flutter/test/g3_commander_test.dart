import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/pages/g3_commander.dart';

class MemoryCommander extends CommanderBackend {
  bool connected = true;
  final calls = <String>[];
  @override
  String get remoteName => 'TEST-SERVER';
  @override
  bool get ready => connected;
  @override
  String path(bool local) => local ? r'C:\Local' : r'D:\Remote';
  @override
  List<CommanderEntry> entries(bool local) => [
        CommanderEntry('${path(local)}\\docs', 'docs', directory: true),
        CommanderEntry('${path(local)}\\notes.txt', 'notes.txt',
            size: 42, modified: DateTime(2026, 11, 2)),
      ];
  @override
  List<CommanderJob> get jobs =>
      const [CommanderJob(7, 'notes.txt', '42 / 100 B', .42, true)];
  @override
  Future<void> navigate(bool local, String path) async {
    calls.add('navigate:$local:$path');
  }

  @override
  Future<void> parent(bool local) async {
    calls.add('parent:$local');
  }

  @override
  Future<void> roots(bool local) async {
    calls.add('roots:$local');
  }

  @override
  Future<void> refresh() async {
    calls.add('refresh');
  }

  @override
  Future<void> copy(bool local, List<String> paths) async {
    calls.add('copy:$local:${paths.single}');
  }

  @override
  Future<void> rename(bool local, String path) async {
    calls.add('rename:$local:$path');
  }

  @override
  Future<void> mkdir(bool local, String name) async {
    calls.add('mkdir:$local:$name');
  }

  @override
  Future<void> delete(bool local, List<String> paths) async {
    calls.add('delete:$local:${paths.single}');
  }

  @override
  Future<String> preview(bool local, String path) async {
    calls.add('preview:$local:$path');
    return 'Read-only fixture';
  }

  @override
  Future<void> cancel(int job) async {
    calls.add('cancel:$job');
  }
}

Future<void> mount(WidgetTester tester, MemoryCommander backend,
    {double width = 1100}) async {
  tester.view.physicalSize = Size(width, 760);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: RepaintBoundary(
              key: const ValueKey('commander-preview'),
              child: G3Commander(backend: backend)))));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (const String.fromEnvironment('COMMANDER_PREVIEW_PATH').isNotEmpty) {
      for (final font in {
        'Consolas': const String.fromEnvironment('COMMANDER_MONO_FONT'),
        'Roboto':
            '${const String.fromEnvironment('COMMANDER_FONT_DIR')}/roboto-regular.ttf',
        'MaterialIcons':
            '${const String.fromEnvironment('COMMANDER_FONT_DIR')}/materialicons-regular.otf',
      }.entries) {
        final loader = FontLoader(font.key)
          ..addFont(File(font.value).readAsBytes().then(ByteData.sublistView));
        await loader.load();
      }
    }
  });
  testWidgets('Two panes, keyboard selection and copy follow the active side',
      (tester) async {
    final backend = MemoryCommander();
    await mount(tester, backend);
    const previewPath = String.fromEnvironment('COMMANDER_PREVIEW_PATH');
    if (previewPath.isNotEmpty) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('commander-preview')));
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(previewPath).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    expect(find.text('Lokal'), findsOneWidget);
    expect(find.text('Eigene Dateiverbindung'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey(r'true_C:\Local\notes.txt')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pumpAndSettle();
    expect(backend.calls, [r'copy:true:C:\Local\notes.txt']);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.insert);
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pumpAndSettle();
    expect(backend.calls.last, r'copy:false:D:\Remote\notes.txt');
    expect(find.textContaining('1 markiert'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Preview stays read-only; navigation, folder and cancellation work',
      (tester) async {
    final backend = MemoryCommander();
    await mount(tester, backend, width: 800);
    await tester.tap(find.byKey(const ValueKey(r'false_D:\Remote\notes.txt')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.pumpAndSettle();
    expect(find.text('Read-only fixture'), findsOneWidget);
    expect(backend.calls, [r'preview:false:D:\Remote\notes.txt']);
    await tester.tap(find.text('Schließen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('F7 Ordner'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Neu');
    await tester.tap(find.text('Erstellen'));
    await tester.pumpAndSettle();
    expect(backend.calls.last, 'mkdir:false:Neu');
    await tester.tap(find.byTooltip('Übertragung abbrechen'));
    await tester.pumpAndSettle();
    expect(backend.calls.last, 'cancel:7');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Disconnected sessions disable file operations', (tester) async {
    final backend = MemoryCommander();
    await mount(tester, backend);
    await tester.tap(find.byKey(const ValueKey(r'true_C:\Local\notes.txt')));
    await tester.pump(const Duration(milliseconds: 350));
    backend.connected = false;
    backend.notifyListeners();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.tap(find.text('F5 Kopieren'));
    await tester.pump();
    expect(backend.calls, isEmpty);
    expect(find.text('Verbindung wird aufgebaut …'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
