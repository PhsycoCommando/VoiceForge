import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A scrollable panel that displays transcription entries.
///
/// Used for both the raw (left) and formatted (right) panels.
class TranscriptionPanel extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color accentColor;
  final List<String> entries;
  final String? liveText;
  final ScrollController? scrollController;
  final bool isLive;
  final bool showMode;
  final String? mode;
  final bool showCopyButton;

  const TranscriptionPanel({
    super.key,
    required this.title,
    required this.icon,
    required this.accentColor,
    required this.entries,
    this.liveText,
    this.scrollController,
    this.isLive = false,
    this.showMode = false,
    this.mode,
    this.showCopyButton = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          _buildHeader(),
          const Divider(height: 1, color: Color(0xFF2A2A3E)),

          // Content
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: accentColor, size: 18),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: accentColor,
              letterSpacing: 0.5,
            ),
          ),
          if (showMode && mode != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                mode!,
                style: TextStyle(
                  fontSize: 11,
                  color: accentColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (showCopyButton && entries.isNotEmpty)
            _CopyButton(textToCopy: entries.join('\n\n')),
          if (isLive)
            _PulsingDot(color: accentColor),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final hasContent = entries.isNotEmpty || (liveText?.isNotEmpty ?? false);

    if (!hasContent) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic_off_rounded, size: 48, color: Colors.white.withValues(alpha: 0.1)),
            const SizedBox(height: 12),
            Text(
              'Waiting for transcription...',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.25),
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: entries.length + (liveText?.isNotEmpty == true ? 1 : 0),
      itemBuilder: (context, index) {
        // Live text at the bottom
        if (index == entries.length) {
          return _LiveEntry(text: liveText!, color: accentColor);
        }

        return _FinalEntry(text: entries[index], index: index);
      },
    );
  }
}

/// A finalized transcript entry with subtle separator.
class _FinalEntry extends StatelessWidget {
  final String text;
  final int index;

  const _FinalEntry({required this.text, required this.index});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (index > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Divider(
                height: 1,
                color: Colors.white.withValues(alpha: 0.05),
              ),
            ),
          SelectableText(
            text,
            style: const TextStyle(
              fontSize: 14,
              height: 1.6,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}

/// The live (partial) text entry with a pulsing indicator.
class _LiveEntry extends StatelessWidget {
  final String text;
  final Color color;

  const _LiveEntry({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _PulsingDot(color: color, size: 8),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: color.withValues(alpha: 0.9),
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small pulsing dot indicator.
class _PulsingDot extends StatefulWidget {
  final Color color;
  final double size;

  const _PulsingDot({required this.color, this.size = 6});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _animation = Tween(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (_, __) => Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withValues(alpha: _animation.value),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }
}

/// Button to copy formatted text to clipboard.
class _CopyButton extends StatefulWidget {
  final String textToCopy;
  const _CopyButton({required this.textToCopy});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  void _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.textToCopy));
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: _copied
          ? const Row(
              key: ValueKey('copied'),
              children: [
                Icon(Icons.check_rounded, color: Color(0xFF00B894), size: 16),
                SizedBox(width: 4),
                Text('Copied ✓',
                    style: TextStyle(color: Color(0xFF00B894), fontSize: 13, fontWeight: FontWeight.w600)),
                SizedBox(width: 8),
              ],
            )
          : IconButton(
              key: const ValueKey('copy'),
              icon: const Icon(Icons.copy_rounded, size: 18, color: Colors.white54),
              splashRadius: 20,
              onPressed: _copy,
              tooltip: 'Copy to clipboard',
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
    );
  }
}
