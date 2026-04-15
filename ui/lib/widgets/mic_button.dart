import 'package:flutter/material.dart';

/// Large floating mic toggle button with animated recording state.
///
/// Designed to float above the UI via a Stack, always visible and accessible.
class MicButton extends StatelessWidget {
  final bool isRecording;
  final bool isConnected;
  final VoidCallback onPressed;

  const MicButton({
    super.key,
    required this.isRecording,
    required this.isConnected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final color = isRecording
        ? const Color(0xFFFF6B6B)
        : const Color(0xFF00B894);

    return GestureDetector(
      onTap: isConnected ? onPressed : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        width: isRecording ? 72 : 64,
        height: isRecording ? 72 : 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isConnected
              ? color.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.05),
          border: Border.all(
            color: isConnected ? color : Colors.white24,
            width: 2.5,
          ),
          boxShadow: [
            // Always show a subtle shadow for floating effect
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 12,
              spreadRadius: 1,
            ),
            if (isRecording)
              BoxShadow(
                color: color.withValues(alpha: 0.35),
                blurRadius: 24,
                spreadRadius: 4,
              ),
          ],
        ),
        child: Icon(
          isRecording ? Icons.stop_rounded : Icons.mic_rounded,
          color: isConnected ? color : Colors.white24,
          size: isRecording ? 34 : 30,
        ),
      ),
    );
  }
}
