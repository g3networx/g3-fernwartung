import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart';
import 'package:flutter_hbb/generated_bridge.dart' show RustdeskImpl;
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _CursorBinding extends Fake implements RustdeskImpl {
  bool showCursor = false;
  int toggleCount = 0;

  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      name;

  @override
  bool sessionIsMultiUiSession({required UuidValue sessionId, dynamic hint}) =>
      false;

  @override
  bool sessionGetToggleOptionSync(
      {required UuidValue sessionId, required String arg, dynamic hint}) {
    expect(arg, 'show-remote-cursor');
    return showCursor;
  }

  @override
  Future<void> sessionToggleOption(
      {required UuidValue sessionId,
      required String value,
      dynamic hint}) async {
    expect(value, 'show-remote-cursor');
    toggleCount++;
    showCursor = !showCursor;
  }
}

class _CursorSession extends Fake implements FFI {
  _CursorSession(String platform,
      {bool embedded = false, bool wayland = false}) {
    ffiModel = FfiModel(WeakReference(this));
    canvasModel = CanvasModel(WeakReference(this));
    ffiModel.pi
      ..platform = platform
      ..version = '1.5.3-g3.62.20097'
      ..platformAdditions = {kPlatformAdditionsIsWayland: wayland};
    ffiModel.pi.displays.add(Display()..cursorEmbedded = embedded);
  }

  @override
  final SessionID sessionId = const Uuid().v4obj();
  @override
  late final FfiModel ffiModel;
  @override
  late final CanvasModel canvasModel;
}

void main() {
  const id = 'remote-cursor-lab';
  late _CursorBinding native;
  setUp(() {
    native = _CursorBinding();
    platformFFI.setBindingForTesting(native);
    ShowRemoteCursorState.init(id);
    ShowRemoteCursorLockState.init(id);
  });
  tearDown(() {
    ShowRemoteCursorState.delete(id);
    ShowRemoteCursorLockState.delete(id);
  });

  Future<void> render(WidgetTester tester, TToggleMenu menu) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CkbMenuButton(
          value: menu.value,
          onChanged: menu.onChanged,
          child: menu.child,
        ),
      ),
    ));
  }

  testWidgets('Windows session can turn the remote cursor on and off',
      (tester) async {
    final ffi = _CursorSession(kPeerPlatformWindows);
    addTearDown(ffi.canvasModel.dispose);
    await render(tester, toolbarShowRemoteCursor(id, ffi)!);
    expect(find.text('Show remote cursor'), findsOneWidget);
    await tester.tap(find.byType(CheckboxMenuButton));
    await tester.pump();
    expect(ShowRemoteCursorState.find(id).value, isTrue);
    await render(tester, toolbarShowRemoteCursor(id, ffi)!);
    expect(
        tester
            .widget<CheckboxMenuButton>(find.byType(CheckboxMenuButton))
            .value,
        isTrue);
    await tester.tap(find.byType(CheckboxMenuButton));
    await tester.pump();
    expect(ShowRemoteCursorState.find(id).value, isFalse);
    expect(native.toggleCount, 2);
  });

  testWidgets('embedded cursor stays visible and checked on Windows',
      (tester) async {
    final ffi = _CursorSession(kPeerPlatformWindows, embedded: true);
    addTearDown(ffi.canvasModel.dispose);
    await render(tester, toolbarShowRemoteCursor(id, ffi)!);
    expect(find.text('Show remote cursor'), findsOneWidget);
    expect(find.byTooltip('Remote cursor is already part of the image'),
        findsOneWidget);
    final button =
        tester.widget<CheckboxMenuButton>(find.byType(CheckboxMenuButton));
    expect(button.value, isTrue);
    expect(button.onChanged, isNull);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
        location: tester.getCenter(find.text('Show remote cursor')));
    await tester.pumpAndSettle();
    expect(find.text('Remote cursor is already part of the image'),
        findsOneWidget);
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(native.toggleCount, 0);
  }, skip: !Platform.isWindows);

  testWidgets('Android and Wayland targets show an unavailable row on Windows',
      (tester) async {
    for (final (platform, wayland) in [
      (kPeerPlatformAndroid, false),
      (kPeerPlatformLinux, true),
    ]) {
      final ffi = _CursorSession(platform, wayland: wayland);
      addTearDown(ffi.canvasModel.dispose);
      await render(tester, toolbarShowRemoteCursor(id, ffi)!);
      expect(find.text('Show remote cursor'), findsOneWidget);
      expect(find.byTooltip('Not available'), findsOneWidget);
      final button =
          tester.widget<CheckboxMenuButton>(find.byType(CheckboxMenuButton));
      expect(button.value, isFalse);
      expect(button.onChanged, isNull);
    }
    expect(native.toggleCount, 0);
  }, skip: !Platform.isWindows);
}
