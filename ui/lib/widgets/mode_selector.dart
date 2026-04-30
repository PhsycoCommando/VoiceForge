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
    'summary': Icons.summarize_rounded,
    'prompt': Icons.smart_toy_rounded,
    'markdown': Icons.code_rounded,
    'speech': Icons.record_voice_over_rounded,
    // Legacy modes (still registered in backend, hidden from UI)
    'dev': Icons.code_rounded,
    'ai_dev': Icons.psychology_rounded,
    'ai_summary': Icons.smart_toy_rounded,
  };

  static const _modeLabels = <String, String>{
    'clean': 'Clean',
    'bullet': 'Bullet',
    'summary': 'Summary',
    'prompt': 'Prompt',
    'markdown': 'Markdown',
    'speech': 'Speech',
    // Legacy
    'dev': 'Dev',
    'ai_dev': 'AI Dev',
    'ai_summary': 'AI Summary',
  };

  // AI-powered modes get a purple accent; rule-based get indigo
  static const _aiModes = {'summary', 'prompt', 'markdown', 'speech'};

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: availableModes.map((mode) {
        final isSelected = mode == currentMode;
        final isAi = _aiModes.contains(mode);
        final accent =
            isAi ? const Color(0xFFA29BFE) : const Color(0xFF6C5CE7);

        return FilterChip(
          selected: isSelected,
          label: Text(
            _modeLabels[mode] ?? mode,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              color: isSelected ? Colors.white : Colors.white54,
            ),
          ),
          labelPadding: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
          avatar: Icon(
            _modeIcons[mode] ?? Icons.circle,
            size: 13,
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
    );
  }
}
