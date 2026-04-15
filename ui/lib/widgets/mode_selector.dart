import 'package:flutter/material.dart';

/// Action button bar — each button triggers a transform.
///
/// NOT a passive mode selector. Clicking = "process with this mode".
class ModeSelector extends StatelessWidget {
  final String currentMode;
  final List<String> availableModes;
  final ValueChanged<String> onModeChanged;
  final bool isProcessing;

  const ModeSelector({
    super.key,
    required this.currentMode,
    required this.availableModes,
    required this.onModeChanged,
    this.isProcessing = false,
  });

  static const _modeIcons = <String, IconData>{
    'clean': Icons.auto_fix_high_rounded,
    'bullet': Icons.format_list_bulleted_rounded,
    'dev': Icons.code_rounded,
    'raw': Icons.text_snippet_rounded,
    'ai_dev': Icons.psychology_rounded,
    'ai_summary': Icons.smart_toy_rounded,
  };

  static const _modeLabels = <String, String>{
    'clean': 'Clean',
    'bullet': 'Bullet',
    'dev': 'Dev',
    'raw': 'Raw',
    'ai_dev': 'AI Dev',
    'ai_summary': 'AI Summary',
  };

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Processing indicator
        if (isProcessing) ...[
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFFA29BFE),
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'Processing...',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFFA29BFE),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 12),
        ],
        Wrap(
          spacing: 6,
          children: availableModes.map((mode) {
            final isSelected = mode == currentMode;
            final isAi = mode.startsWith('ai_');
            final accent =
                isAi ? const Color(0xFFA29BFE) : const Color(0xFF6C5CE7);

            return FilterChip(
              selected: isSelected,
              label: Text(
                _modeLabels[mode] ?? mode,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected ? Colors.white : Colors.white54,
                ),
              ),
              avatar: Icon(
                _modeIcons[mode] ?? Icons.circle,
                size: 14,
                color: isSelected ? accent : Colors.white38,
              ),
              backgroundColor: Colors.white.withValues(alpha: 0.05),
              selectedColor: accent.withValues(alpha: 0.2),
              side: BorderSide(
                color: isSelected
                    ? accent.withValues(alpha: 0.4)
                    : Colors.white.withValues(alpha: 0.08),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              showCheckmark: false,
              onSelected: isProcessing ? null : (_) => onModeChanged(mode),
            );
          }).toList(),
        ),
      ],
    );
  }
}
