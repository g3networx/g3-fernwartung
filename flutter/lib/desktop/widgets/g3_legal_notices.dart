import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

class G3LegalNotices extends StatelessWidget {
  const G3LegalNotices({super.key, required this.license, required this.year});

  final String license;
  final int year;

  @override
  Widget build(BuildContext context) {
    const linkStyle = TextStyle(decoration: TextDecoration.underline);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('Rechtliche Hinweise / Legal notices'),
      children: [
        SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Copyright © $year Purslane Tech Pte. Ltd.\n$license',
              ),
              const Text(
                'RustDesk · GNU Affero General Public License v3. '
                'Weitergabe und Änderungen sind nach dieser Lizenz erlaubt. '
                'Keine Gewährleistung, soweit gesetzlich zulässig.\n'
                'Redistribution and modification are permitted under this license. '
                'No warranty, to the extent permitted by law.',
              ),
              InkWell(
                onTap: () => launchUrlString(
                    'https://www.gnu.org/licenses/agpl-3.0.html'),
                child: const Text('Lizenztext / License', style: linkStyle),
              ),
              InkWell(
                onTap: () => launchUrlString(
                    'https://github.com/g3networx/g3-fernwartung'),
                child: const Text('Quellcode / Source code', style: linkStyle),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
