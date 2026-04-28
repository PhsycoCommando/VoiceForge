import 'package:flutter/material.dart';

enum AppStatus {
  listening,
  transcribing,
  processing,
  ready,
  reconnecting,
  disconnected,
}

/// Small connection/app status indicator in the top bar.
class StatusIndicator extends StatefulWidget {
  final AppStatus state;

  const StatusIndicator({super.key, required this.state});

  @override
  State<StatusIndicator> createState() => _StatusIndicatorState();
}

class _StatusIndicatorState extends State<StatusIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant StatusIndicator old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) _syncPulse();
  }

  void _syncPulse() {
    if (widget.state == AppStatus.reconnecting) {
      _pulseCtrl.repeat(reverse: true);
    } else {
      _pulseCtrl.stop();
      _pulseCtrl.value = 1.0;
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (widget.state) {
      AppStatus.listening     => (const Color(0xFF00B894), 'Listening'),
      AppStatus.transcribing  => (const Color(0xFFFFA500), 'Transcribing...'),
      AppStatus.processing    => (const Color(0xFFFDCB6E), 'Processing...'),
      AppStatus.ready         => (const Color(0xFF74B9FF), 'Ready'),
      AppStatus.reconnecting  => (const Color(0xFFFFA500), 'Reconnecting...'),
      AppStatus.disconnected  => (const Color(0xFFFF6B6B), 'Disconnected'),
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
          FadeTransition(
            opacity: _pulseCtrl,
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
              ),
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
