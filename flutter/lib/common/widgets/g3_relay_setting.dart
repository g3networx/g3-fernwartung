import 'package:flutter/material.dart';

import '../../common.dart';
import '../../models/platform_model.dart';

const _relaySetting = 'g3-always-relay';

bool get showG3RelaySetting =>
    !isWeb &&
    const {'g3Fernwartung', 'g3Host', 'g3Soforthilfe'}
        .contains(bind.mainGetAppNameSync());

class G3RelaySetting extends StatefulWidget {
  const G3RelaySetting({super.key});

  @override
  State<G3RelaySetting> createState() => _G3RelaySettingState();
}

class _G3RelaySettingState extends State<G3RelaySetting> {
  late bool _enabled = bind.mainGetLocalOption(key: _relaySetting) == 'Y';
  bool _saving = false;

  Future<void> _setEnabled(bool enabled) async {
    setState(() => _saving = true);
    try {
      await bind.mainSetLocalOption(
          key: _relaySetting, value: enabled ? 'Y' : '');
    } finally {
      if (mounted) {
        setState(() {
          _enabled = bind.mainGetLocalOption(key: _relaySetting) == 'Y';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
        title: const Text('Immer über Relais verbinden'),
        subtitle: const Text(
            'Ausgeschaltet: direkt im eigenen Netz, sonst über Relais.'),
        value: _enabled,
        onChanged: _saving || isOptionFixed(_relaySetting) ? null : _setEnabled,
      );
}
