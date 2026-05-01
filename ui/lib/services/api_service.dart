/// REST API service for VoiceForge backend.
///
/// Handles all HTTP communication with the FastAPI server.
library;

import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  final String baseUrl;
  final http.Client _client;

  ApiService({this.baseUrl = 'http://localhost:8000'})
      : _client = http.Client();

  // ---------------------------------------------------------------------------
  // Pipeline control
  // ---------------------------------------------------------------------------

  /// Start the live mic → transcription pipeline.
  Future<Map<String, dynamic>> startStream() async {
    final resp = await _client.post(Uri.parse('$baseUrl/stream/start'));
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Stop the live pipeline.
  Future<Map<String, dynamic>> stopStream() async {
    final resp = await _client.post(Uri.parse('$baseUrl/stream/stop'));
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------------------
  // Mode
  // ---------------------------------------------------------------------------

  /// Switch the formatting mode.
  Future<Map<String, dynamic>> setMode(String mode) async {
    final resp = await _client.post(
      Uri.parse('$baseUrl/mode'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'mode': mode}),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------------------
  // Status
  // ---------------------------------------------------------------------------

  /// Get the current server status.
  Future<Map<String, dynamic>> getStatus() async {
    final resp = await _client.get(Uri.parse('$baseUrl/'));
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Get the current config.
  Future<Map<String, dynamic>> getConfig() async {
    final resp = await _client.get(Uri.parse('$baseUrl/config'));
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------------------
  // Transform (on-demand formatting)
  // ---------------------------------------------------------------------------

  /// Transform raw text using the specified mode.
  /// This is the "Transform Later" endpoint.
  Future<Map<String, dynamic>> transform(String text, String mode) async {
    final resp = await _client.post(
      Uri.parse('$baseUrl/transform'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'text': text, 'mode': mode}),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------------

  /// Get accumulated raw session text from the pipeline.
  Future<Map<String, dynamic>> getSession() async {
    final resp = await _client.get(Uri.parse('$baseUrl/session'));
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Clear the accumulated session text.
  Future<Map<String, dynamic>> clearSession() async {
    final resp = await _client.post(Uri.parse('$baseUrl/session/clear'));
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Open the sessions folder in the OS file explorer (desktop only).
  Future<Map<String, dynamic>> openSessionsFolder() async {
    final resp = await _client.get(Uri.parse('$baseUrl/sessions/open-folder'));
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Transcribe a local audio file via the backend /transcribe endpoint.
  /// Supported formats: WAV, MP3, MP4, M4A, OGG, FLAC, WEBM, OPUS
  /// Returns {'raw': '...', 'clean': '...', 'mode': '...'}.
  Future<Map<String, dynamic>> transcribeFile(String filePath, {String mode = 'raw'}) async {
    final uri = Uri.parse('$baseUrl/transcribe');
    final request = http.MultipartRequest('POST', uri)
      ..fields['mode'] = mode
      ..files.add(await http.MultipartFile.fromPath('file', filePath));
    final streamed = await _client.send(request);
    final body = await http.Response.fromStream(streamed);
    if (body.statusCode != 200) {
      throw Exception('Transcribe failed (${body.statusCode}): ${body.body}');
    }
    return jsonDecode(body.body) as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------------------
  // Device selection
  // ---------------------------------------------------------------------------

  /// Get all available microphones.
  Future<List<Map<String, dynamic>>> getMicrophones() async {
    final resp = await _client.get(Uri.parse('$baseUrl/devices/microphones'));
    final list = jsonDecode(resp.body) as List;
    return list.cast<Map<String, dynamic>>();
  }

  /// Select a microphone by its index.
  Future<Map<String, dynamic>> selectMicrophone(int deviceId) async {
    final resp = await _client.post(
      Uri.parse('$baseUrl/devices/microphone'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'device_id': deviceId}),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Get the currently selected microphone.
  Future<Map<String, dynamic>> getCurrentMicrophone() async {
    final resp = await _client.get(Uri.parse('$baseUrl/devices/microphone'));
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  void dispose() {
    _client.close();
  }
}
