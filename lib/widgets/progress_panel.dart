import 'package:flutter/material.dart';

/// Shown while Claude is analysing the image.
class ProgressPanel extends StatelessWidget {
  const ProgressPanel({super.key, required this.chars});

  final int chars;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = chars == 0
        ? 'Đang đọc và phân tích ảnh…'
        : 'Đang vẽ lại… (${(chars / 1000).toStringAsFixed(1)}k ký tự)';
    return Card(
      color: scheme.primaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    status,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const LinearProgressIndicator(),
            const SizedBox(height: 10),
            Text(
              'Ảnh phức tạp có thể mất từ 30 giây đến vài phút.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
