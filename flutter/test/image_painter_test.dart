import 'dart:ui' as ui;

import 'package:flutter_hbb/utils/image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('repaints only when the drawn image or placement changes',
      (tester) async {
    ui.Image frame(int color) {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(ui.Color(color), ui.BlendMode.src);
      final picture = recorder.endRecording();
      try {
        return picture.toImageSync(1, 1);
      } finally {
        picture.dispose();
      }
    }

    final image = frame(0xff000000);
    final nextImage = frame(0xffffffff);
    addTearDown(image.dispose);
    addTearDown(nextImage.dispose);

    ImagePainter painter(ui.Image? frame, double x, {double scale = 1}) =>
        ImagePainter(image: frame, x: x, y: 0, scale: scale);

    final current = painter(image, 1.2);
    expect(painter(image, 1.8).shouldRepaint(current), isFalse);
    expect(painter(image, 2).shouldRepaint(current), isTrue);
    expect(painter(image, 1.2, scale: 2).shouldRepaint(current), isTrue);
    expect(painter(nextImage, 1.2).shouldRepaint(current), isTrue);
    expect(painter(null, 1.2).shouldRepaint(current), isTrue);
    expect(painter(image, double.nan).shouldRepaint(current), isTrue);
  });
}
