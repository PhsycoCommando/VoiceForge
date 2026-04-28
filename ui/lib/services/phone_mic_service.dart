/// PhoneMicService — captures audio from the phone microphone and streams
/// raw int16 PCM chunks to the VoiceForge backend via WebSocket binary frames.
///
/// The backend's PhoneAudioPipeline receives the frames and runs Whisper
/// on them, emitting partial/final events back to all connected clients
/// (phone AND desktop both see the transcription in real time).
///
/// PCM format: 16kHz, mono, int16 — the same target Whisper expects.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'websocket_service.dart';

class PhoneMicService {
  static const _sampleRate = 16000;
  static const _numChannels = 1;

  final WebSocketService _ws;
  final AudioRecorder _recorder = AudioRecorder();

  StreamSubscription<Uint8List>? _audioSub;
  bool _recording = false;

  PhoneMicService(this._ws);

  bool get isRecording => _recording;

  /// Check whether the app has mic permission.
  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Start capturing from the phone mic and streaming PCM to the backend.
  ///
  /// Sends `{"command":"start","source":"phone"}` to the backend WS, then
  /// opens a PCM stream and pipes each chunk as a binary WebSocket frame.
  Future<bool> start() async {
    if (_recording) return true;

    final hasPerms = await _recorder.hasPermission();
    if (!hasPerms) return false;

    // Tell backend to open the phone pipeline (skips WASAPI)
    _ws.start(source: 'phone');

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: _numChannels,
        // iosDuckOthers prevents loud ducking alert on iOS
      ),
    );

    _recording = true;

    _audioSub = stream.listen(
      (chunk) => _ws.sendBinary(chunk),
      onError: (_) => stop(),
      onDone: () => _recording = false,
      cancelOnError: true,
    );

    return true;
  }

  /// Stop the mic and tell the backend to finalise.
  ///
  /// The backend will run a final Whisper pass over all accumulated audio
  /// and publish a `final` event to all clients.
  Future<void> stop() async {
    if (!_recording) return;
    _recording = false;

    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();

    // Tell backend to stop and trigger final transcription
    _ws.stop();
  }

  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
  }
}
