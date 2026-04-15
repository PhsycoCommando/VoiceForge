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

  void dispose() {
    _client.close();
  }
}
