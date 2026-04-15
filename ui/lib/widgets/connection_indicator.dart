import 'package:flutter/material.dart';

enum AppStatus {
  listening,
  processing,
  ready,
  disconnected,
}

/// Small connection/app status indicator in the top bar.
class StatusIndicator extends StatelessWidget {
  final AppStatus state;

  const StatusIndicator({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state) {
      AppStatus.listening => (const Color(0xFF00B894), 'Listening'),
      AppStatus.processing => (const Color(0xFFFDCB6E), 'Processing...'),
      AppStatus.ready => (const Color(0xFF74B9FF), 'Ready'),
      AppStatus.disconnected => (const Color(0xFFFF6B6B), 'Disconnected'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
