import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/g3_guide_tools.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

class _Canvas extends Fake with ChangeNotifier implements CanvasModel {
  @override
  final double x = 10;
  @override
  final double y = -20;
  @override
  final double scale = 0.5;
  @override
  final double scrollX = 0.25;
  @override
  final double scrollY = 0;
  @override
  final Size size = const Size(400, 600);
  @override
  ScrollStyle scrollStyle = ScrollStyle.scrollauto;
}

class _Session extends Fake implements FFI {
  @override
  final inputModel = _Input();
  @override
  final ffiModel = _Peer();
}

class _Input extends Fake implements InputModel {
  @override
  final guideMarker = Rxn<Offset>();
  @override
  final guideMarkerText = ''.obs;
}

class _Peer extends Fake implements FfiModel {
  @override
  final pi = PeerInfo();

  @override
  Rect? get rect => const Rect.fromLTWH(-1000, 0, 1000, 800);
}

void main() {
  test('marker remains at the remote point after scaling and scrolling', () {
    const remote = Rect.fromLTWH(-1000, 0, 1000, 800);
    const marker = Offset(-700, 200);
    final canvas = _Canvas();
    expect(guideMarkerInCanvas(marker, remote, canvas), const Offset(160, 80));
    canvas.scrollStyle = ScrollStyle.scrollbar;
    expect(guideMarkerInCanvas(marker, remote, canvas), const Offset(25, 200));
  });

  testWidgets('placed guide arrow is visible at the transmitted point',
      (tester) async {
    final ffi = _Session();
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(MaterialApp(
        home: ChangeNotifierProvider<CanvasModel>.value(
          value: _Canvas(),
          child: G3GuideMarker(ffi: ffi),
        ),
      ));
      final arrow = find.bySemanticsLabel('Gesetzter Zeigepfeil');
      expect(arrow, findsNothing);

      ffi.inputModel.guideMarker.value = const Offset(-700, 200);
      ffi.inputModel.guideMarkerText.value = 'Hier die Nummer eingeben';
      await tester.pump();
      expect(tester.getTopLeft(arrow), const Offset(160, 80));
      final hint = find.text('Hier die Nummer eingeben');
      expect(hint, findsOneWidget);
      expect(tester.getTopLeft(hint).dx, greaterThan(160));

      ffi.inputModel.guideMarker.value = null;
      await tester.pump();
      expect(arrow, findsNothing);
      expect(hint, findsNothing);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('Windows uses the hint in the captured desktop frame',
      (tester) async {
    final ffi = _Session();
    ffi.ffiModel.pi.platform = kPeerPlatformWindows;
    ffi.inputModel.guideMarker.value = const Offset(-700, 200);
    ffi.inputModel.guideMarkerText.value = 'Hier die Nummer eingeben';
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(MaterialApp(
        home: ChangeNotifierProvider<CanvasModel>.value(
          value: _Canvas(),
          child: G3GuideMarker(ffi: ffi),
        ),
      ));
      expect(find.bySemanticsLabel('Gesetzter Zeigepfeil'), findsOneWidget);
      expect(find.text('Hier die Nummer eingeben'), findsNothing);
    } finally {
      semantics.dispose();
    }
  });
}
