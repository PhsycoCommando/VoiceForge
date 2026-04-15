/// WebSocket service for real-time transcription streaming.
///
/// Connects to the FastAPI WebSocket endpoint and emits
/// transcription events (partial, final, status, error).
library;

import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A single transcription event from the backend.
class TranscriptionEvent {
  final String type; // "partial", "final", "status", "error"
  final String raw;
  final String formatted;
  final String mode;
  final double? timestamp;
  final String? status;
  final String? message;

  TranscriptionEvent({
    required this.type,
    this.raw = '',
    this.formatted = '',
    this.mode = '',
    this.timestamp,
    this.status,
    this.message,
  });

  factory TranscriptionEvent.fromJson(Map<String, dynamic> json) {
    return TranscriptionEvent(
      type: json['type'] as String? ?? 'unknown',
      raw: json['raw'] as String? ?? '',
      formatted: json['formatted'] as String? ?? '',
      mode: json['mode'] as String? ?? '',
      timestamp: (json['timestamp'] as num?)?.toDouble(),
      status: json['status'] as String?,
      message: json['message'] as String?,
    );
  }
}

/// Connection state of the WebSocket.
enum WsConnectionState { disconnected, connecting, connected, error }

class WebSocketService {
  final String wsUrl;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;

  // Event streams
  final _eventController = StreamController<TranscriptionEvent>.broadcast();
  final _connectionController =
      StreamController<WsConnectionState>.broadcast();

  Stream<TranscriptionEvent> get events => _eventController.stream;
  Stream<WsConnectionState> get connectionState =>
      _connectionController.stream;

  WsConnectionState _state = WsConnectionState.disconnected;
  WsConnectionState get currentState => _state;

  // Available modes (populated from initial status message)
  List<String> availableModes = [];

  WebSocketService({this.wsUrl = 'ws://localhost:8000/stream'});

  // ---------------------------------------------------------------------------
  // Connect / Disconnect
  // ---------------------------------------------------------------------------

  /// Connect to the WebSocket endpoint.
  void connect() {
    if (_state == WsConnectionState.connecting ||
        _state == WsConnectionState.connected) {
      return;
    }

    _setState(WsConnectionState.connecting);

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );

      _setState(WsConnectionState.connected);
    } catch (e) {
      _setState(WsConnectionState.error);
      _scheduleReconnect();
    }
  }

  /// Disconnect from the WebSocket.
  void disconnect() {
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
    _setState(WsConnectionState.disconnected);
  }

  // ---------------------------------------------------------------------------
  // Send commands
  // ---------------------------------------------------------------------------

  /// Send a command to the server via WebSocket.
  void sendCommand(String command, {Map<String, dynamic>? params}) {
    if (_channel == null) return;
    final msg = {'command': command, ...?params};
    _channel!.sink.add(jsonEncode(msg));
  }

  /// Set mode via WebSocket command.
  void setMode(String mode) => sendCommand('set_mode', params: {'mode': mode});

  /// Start pipeline via WebSocket command.
  void start() => sendCommand('start');

  /// Stop pipeline via WebSocket command.
  void stop() => sendCommand('stop');

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _onMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;
      final event = TranscriptionEvent.fromJson(data);

      // Capture available modes from initial status
      if (event.type == 'status' && data.containsKey('available_modes')) {
        availableModes =
            (data['available_modes'] as List).cast<String>().toList();
      }

      _eventController.add(event);
    } catch (e) {
      // Ignore malformed messages
    }
  }

  void _onError(dynamic error) {
    _setState(WsConnectionState.error);
    _scheduleReconnect();
  }

  void _onDone() {
    _setState(WsConnectionState.disconnected);
    _scheduleReconnect();
  }

  void _setState(WsConnectionState state) {
    _state = state;
    _connectionController.add(state);
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (_state != WsConnectionState.connected) {
        connect();
      }
    });
  }

  void dispose() {
    disconnect();
    _eventController.close();
    _connectionController.close();
  }
}
