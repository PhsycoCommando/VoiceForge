/// File transcription widget — lets the user pick any audio file and
/// transcribe it via the backend /transcribe endpoint.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/api_service.dart';

/// Supported audio file extensions (mirrors what ffmpeg+Whisper can handle)
const _kAudioExtensions = ['wav', 'mp3', 'mp4', 'm4a', 'ogg', 'flac', 'webm', 'opus', 'aac'];

class FileTranscribeButton extends StatefulWidget {
  final ApiService api;
  /// Called with the raw transcription text when a file is processed.
  final void Function(String rawText, String filename) onTranscribed;

  const FileTranscribeButton({
    super.key,
    required this.api,
    required this.onTranscribed,
  });

  @override
  State<FileTranscribeButton> createState() => _FileTranscribeButtonState();
}

class _FileTranscribeButtonState extends State<FileTranscribeButton> {
  bool _isBusy = false;
  String? _lastFilename;
  String? _errorMessage;

  Future<void> _pickAndTranscribe() async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: _kAudioExtensions,
        dialogTitle: 'Select Audio File to Transcribe',
      );

      if (result == null || result.files.single.path == null) {
        setState(() => _isBusy = false);
        return; // user cancelled
      }

      final path = result.files.single.path!;
      final filename = result.files.single.name;
      setState(() => _lastFilename = filename);

      final response = await widget.api.transcribeFile(path);
      final raw = response['raw'] as String? ?? '';

      if (!mounted) return;

      if (raw.isEmpty) {
        setState(() => _errorMessage = 'No speech detected in file');
      } else {
        widget.onTranscribed(raw, filename);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: 'Transcribe an audio file (WAV, MP3, MP4, M4A, OGG, FLAC…)',
          child: OutlinedButton.icon(
            onPressed: _isBusy ? null : _pickAndTranscribe,
            icon: _isBusy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFFA29BFE),
                    ),
                  )
                : const Icon(Icons.audio_file_rounded, size: 16),
            label: Text(_isBusy
                ? 'Transcribing…'
                : _lastFilename != null
                    ? 'Transcribe File'
                    : 'Transcribe File'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFA29BFE),
              side: BorderSide(
                color: const Color(0xFFA29BFE).withValues(alpha: _isBusy ? 0.2 : 0.4),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        if (_lastFilename != null && !_isBusy && _errorMessage == null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle_outline_rounded, size: 12, color: Color(0xFF00B894)),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    _lastFilename!,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF00B894)),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded, size: 12, color: Color(0xFFFF6B6B)),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(fontSize: 11, color: Color(0xFFFF6B6B)),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
