import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'common.dart';

class ReleaseInfoCard extends StatefulWidget {
  const ReleaseInfoCard({super.key});

  @override
  State<ReleaseInfoCard> createState() => _ReleaseInfoCardState();
}

class _ReleaseInfoCardState extends State<ReleaseInfoCard> {
  late final _release = rootBundle
      .loadString('assets/release-info.json')
      .then((text) => jsonDecode(text) as Map<String, dynamic>);

  @override
  Widget build(BuildContext context) => AppCard(
    child: FutureBuilder<Map<String, dynamic>>(
      future: _release,
      builder: (context, snapshot) {
        final info = snapshot.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              info == null ? '版本信息' : '版本信息 · ${info['version']}',
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13.5,
              ),
            ),
            const SizedBox(height: 8),
            if (info == null)
              Text(snapshot.hasError ? '暂时无法读取版本信息' : '正在加载版本信息…')
            else ...[
              Text(
                '${info['date']}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (final change in info['changes'] as List)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('• $change'),
                ),
              if ((info['knownIssues'] as List).isNotEmpty) ...[
                const SizedBox(height: 6),
                const Text(
                  '待解决',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                for (final issue in info['knownIssues'] as List)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '$issue',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ],
          ],
        );
      },
    ),
  );
}
