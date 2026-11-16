import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../common.dart' show versionCmp;
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';

Offset guideMarkerInCanvas(Offset marker, Rect remote, CanvasModel canvas) {
  final scaled = (marker - remote.topLeft) * canvas.scale;
  if (canvas.scrollStyle == ScrollStyle.scrollauto) {
    return scaled + Offset(canvas.x, canvas.y);
  }
  final width = remote.width * canvas.scale;
  final height = remote.height * canvas.scale;
  return scaled +
      Offset(
        math.max(0.0, (canvas.size.width - width) / 2) - width * canvas.scrollX,
        math.max(0.0, (canvas.size.height - height) / 2) -
            height * canvas.scrollY,
      );
}

class G3GuideMarker extends StatelessWidget {
  const G3GuideMarker({super.key, required this.ffi});

  final FFI ffi;

  @override
  Widget build(BuildContext context) => Obx(() {
        final marker = ffi.inputModel.guideMarker.value;
        if (marker == null) return const SizedBox.shrink();
        return Consumer<CanvasModel>(builder: (context, canvas, _) {
          final remote = ffi.ffiModel.rect;
          if (remote == null || !remote.contains(marker)) {
            return const SizedBox.shrink();
          }
          final position = guideMarkerInCanvas(marker, remote, canvas);
          return IgnorePointer(
            child: Stack(
              children: [
                Positioned(
                  left: position.dx,
                  top: position.dy,
                  child: Semantics(
                    label: 'Gesetzter Zeigepfeil',
                    image: true,
                    child: const CustomPaint(
                      size: Size(24, 24),
                      painter: _GuideArrowPainter(),
                    ),
                  ),
                ),
              ],
            ),
          );
        });
      });
}

class _GuideArrowPainter extends CustomPainter {
  const _GuideArrowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final arrow = Path()
      ..moveTo(0, 0)
      ..lineTo(18, 13)
      ..lineTo(11, 14)
      ..lineTo(14, 21)
      ..lineTo(10, 23)
      ..lineTo(7, 16)
      ..lineTo(2, 21)
      ..close();
    canvas.drawPath(arrow, Paint()..color = const Color(0xffe53935));
    canvas.drawPath(
      arrow,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_GuideArrowPainter oldDelegate) => false;
}

class G3GuideTools extends StatefulWidget {
  final String id;
  final FFI ffi;
  final Widget Function(VoidCallback open) toolbar;

  const G3GuideTools(
      {super.key, required this.id, required this.ffi, required this.toolbar});

  @override
  State<G3GuideTools> createState() => _G3GuideToolsState();
}

class _G3GuideToolsState extends State<G3GuideTools> {
  final _overlay = OverlayPortalController();
  Offset _position = const Offset(16, 60);
  bool _changing = false;
  String? _error;

  Future<bool> _setOption(String option, bool enabled) async {
    final sessionId = widget.ffi.sessionId;
    var value =
        bind.sessionGetToggleOptionSync(sessionId: sessionId, arg: option);
    if (value != enabled) {
      await bind.sessionToggleOption(sessionId: sessionId, value: option);
      value =
          bind.sessionGetToggleOptionSync(sessionId: sessionId, arg: option);
    }
    return value;
  }

  Future<void> _setGuiding(bool enabled) async {
    final model = widget.ffi.ffiModel;
    if (_changing || !model.keyboard) return;
    final peer = model.pi;
    final remoteUser = peer.username.trim().toLowerCase();
    if (enabled &&
        peer.platform == kPeerPlatformWindows &&
        versionCmp(peer.version, '1.5.3') < 0 &&
        (remoteUser.isEmpty || remoteUser == 'system')) {
      setState(() => _error =
          'Für den Zeigemodus nach der Windows-Anmeldung neu verbinden.');
      return;
    }
    setState(() {
      _changing = true;
      _error = null;
    });
    try {
      if (enabled) {
        if (model.inputBlocked) {
          _error = 'Entfernte Eingaben zuerst freigeben.';
          return;
        }
        widget.ffi.inputModel.setRelativeMouseMode(false);
        final viewOnly = await _setOption(kOptionToggleViewOnly, true);
        model.setViewOnly(widget.id, viewOnly);
        if (!viewOnly) throw StateError('View mode unavailable');
        final showCursor = await _setOption(kOptionToggleShowMyCursor, true);
        model.setShowMyCursor(showCursor);
        if (!showCursor) throw StateError('Support cursor unavailable');
      } else {
        widget.ffi.inputModel.guideClickOnly = false;
        final showCursor = await _setOption(kOptionToggleShowMyCursor, false);
        model.setShowMyCursor(showCursor);
        if (showCursor) throw StateError('Could not hide support cursor');
        final viewOnly = await _setOption(kOptionToggleViewOnly, false);
        model.setViewOnly(widget.id, viewOnly);
        if (viewOnly) throw StateError('Could not restore control');
      }
    } catch (_) {
      if (mounted) _error = 'Sitzungsmodus konnte nicht gewechselt werden.';
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
        controller: _overlay,
        child: widget.toolbar(_overlay.toggle),
        overlayChildBuilder: (_) =>
            LayoutBuilder(builder: (context, constraints) {
          final width = math.min(272.0, constraints.maxWidth);
          final maxX = math.max(0.0, constraints.maxWidth - width);
          final maxY = math.max(0.0, constraints.maxHeight - 210);
          final left = _position.dx.clamp(0.0, maxX).toDouble();
          final top = _position.dy.clamp(0.0, maxY).toDouble();
          return Stack(children: [
            Positioned(
              left: left,
              top: top,
              width: width,
              child: Material(
                borderRadius: BorderRadius.circular(8),
                color: Theme.of(context).colorScheme.surface,
                elevation: 8,
                child: AnimatedBuilder(
                  animation: widget.ffi.ffiModel,
                  builder: (context, _) {
                    final model = widget.ffi.ffiModel;
                    final guiding = model.viewOnly && model.showMyCursor;
                    return Column(mainAxisSize: MainAxisSize.min, children: [
                      Row(children: [
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanUpdate: (details) => setState(() {
                              _position = Offset(left, top) + details.delta;
                            }),
                            child: const Padding(
                              padding: EdgeInsets.all(12),
                              child: Text('Zeige-Modus'),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Werkzeugpalette schließen',
                          onPressed: _overlay.hide,
                          icon: const Icon(Icons.close),
                        ),
                      ]),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        child: FilledButton(
                          onPressed: !_changing && model.keyboard
                              ? () => _setGuiding(!guiding)
                              : null,
                          child:
                              Text(guiding ? 'Steuerung übernehmen' : 'Zeigen'),
                        ),
                      ),
                      if (guiding)
                        SwitchListTile(
                          dense: true,
                          title: const Text('Zeiger per Klick anheften'),
                          value: widget.ffi.inputModel.guideClickOnly,
                          onChanged: _changing
                              ? null
                              : (value) => setState(() {
                                    widget.ffi.inputModel.guideClickOnly =
                                        value;
                                  }),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          child: Text(_error!),
                        ),
                    ]);
                  },
                ),
              ),
            ),
          ]);
        }),
      );
}
