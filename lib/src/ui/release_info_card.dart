import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'common.dart';

/// Shared so the sidebar version hint and the release card read one snapshot.
final Future<Map<String, dynamic>> releaseInfo = rootBundle
    .loadString('assets/release-info.json')
    .then((text) => jsonDecode(text) as Map<String, dynamic>);

class ReleaseInfoCard extends StatelessWidget {
  const ReleaseInfoCard({super.key});

  @override
  Widget build(BuildContext context) => AppCard(
    child: FutureBuilder<Map<String, dynamic>>(
      future: releaseInfo,
      builder: (context, snapshot) {
        final info = snapshot.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const BrandMark(size: 64),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            'Idreaml Clip',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(width: 8),
                          Text(
                            '理梦剪藏',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.muted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      if (info == null)
                        Text(
                          snapshot.hasError ? '暂时无法读取版本信息' : '正在加载版本信息…',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.muted,
                          ),
                        )
                      else
                        Text(
                          'Windows x64 · ${info['version']} · ${info['date']}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.muted,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (info != null) ...[
              const Divider(height: 32),
              const Text(
                '本版更新',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              const SizedBox(height: 10),
              for (final change in info['changes'] as List)
                Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: SizedBox.square(
                          dimension: 4,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          '$change',
                          style: const TextStyle(fontSize: 12.5, height: 1.6),
                        ),
                      ),
                    ],
                  ),
                ),
              if ((info['knownIssues'] as List).isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text(
                  '待解决',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
                for (final issue in info['knownIssues'] as List)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '$issue',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              const Text(
                '更新记录随安装包内置，离线也能查看。',
                style: TextStyle(fontSize: 11, color: AppColors.muted),
              ),
            ],
          ],
        );
      },
    ),
  );
}
