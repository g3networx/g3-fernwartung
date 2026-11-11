import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';

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
