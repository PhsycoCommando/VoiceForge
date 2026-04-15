import 'package:flutter/material.dart';

/// Large mic toggle button with animated recording state.
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
        width: isRecording ? 64 : 56,
        height: isRecording ? 64 : 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isConnected
              ? color.withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.05),
          border: Border.all(
            color: isConnected ? color : Colors.white24,
            width: 2,
          ),
          boxShadow: isRecording
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.3),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ]
              : [],
        ),
        child: Icon(
          isRecording ? Icons.stop_rounded : Icons.mic_rounded,
          color: isConnected ? color : Colors.white24,
          size: isRecording ? 30 : 26,
        ),
      ),
    );
  }
}
