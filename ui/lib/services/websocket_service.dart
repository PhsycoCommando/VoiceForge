/// WebSocket service for real-time transcription streaming.
///
/// Connects to the FastAPI WebSocket endpoint and emits
/// transcription events (partial, final, status, error).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
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
  int _reconnectAttempts = 0;

  // Set to true when the user explicitly calls disconnect() —
  // prevents the reconnect loop from firing after an intentional close.
  bool _intentionalDisconnect = false;

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

  /// Current session text from the last handshake (or text_update events).
  /// Clients use this to restore the raw panel on connect.
  String sessionText = '';

  // Watchdog: track last server message time to detect silent socket drops.
  DateTime _lastActivity = DateTime.now();
  Timer? _watchdogTimer;

  // Watchdog interval and dead-socket threshold
  static const _watchdogInterval = Duration(seconds: 30);
  static const _deadSocketThreshold = Duration(seconds: 40);

  WebSocketService({this.wsUrl = 'ws://localhost:8000/stream'});

  // ---------------------------------------------------------------------------
  // Connect / Disconnect
  // ---------------------------------------------------------------------------

  /// Connect to the WebSocket endpoint.
  /// State stays [connecting] until the backend's status handshake arrives.
  void connect() {
    if (_state == WsConnectionState.connecting ||
        _state == WsConnectionState.connected) {
      return;
    }

    _intentionalDisconnect = false;
    _setState(WsConnectionState.connecting);
    _lastActivity = DateTime.now();

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );

      // Start watchdog — detects silent drops (Android Doze, etc.)
      _startWatchdog();

      // NOTE: Do NOT call _setState(connected) here.
      // We stay in [connecting] until the backend sends its status handshake.
      // See _onMessage where status=="connected" triggers the state change.
    } catch (e) {
      _setState(WsConnectionState.error);
      _scheduleReconnect();
    }
  }

  /// Disconnect from the WebSocket. Will not auto-reconnect.
  void disconnect() {
    _intentionalDisconnect = true;
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _watchdogTimer?.cancel();
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

  /// Send raw binary data (PCM audio frames from phone mic).
  void sendBinary(Uint8List bytes) {
    _channel?.sink.add(bytes);
  }

  /// Send a raw text edit to sync with other clients.
  void sendTextUpdate(String text) =>
      sendCommand('text_update', params: {'text': text});

  /// Send a formatted-panel edit to sync with other clients.
  void sendFormattedUpdate(String mode, String text) =>
      sendCommand('formatted_update', params: {'mode': mode, 'text': text});

  /// Broadcast a clear to all clients.
  void sendClear() => sendCommand('clear');

  /// Set mode via WebSocket command.
  void setMode(String mode) => sendCommand('set_mode', params: {'mode': mode});

  /// Start pipeline via WebSocket command (source: "wasapi" or "phone").
  void start({String source = 'wasapi'}) =>
      sendCommand('start', params: {'source': source});

  /// Stop pipeline via WebSocket command.
  void stop() => sendCommand('stop');

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _onMessage(dynamic message) {
    _lastActivity = DateTime.now(); // reset watchdog on every received frame
    try {
      // Binary message = not a JSON event (shouldn't happen server→client, but guard)
      if (message is List<int>) return;

      final data = jsonDecode(message as String) as Map<String, dynamic>;
      final event = TranscriptionEvent.fromJson(data);

      // Absorb keepalive pings — don't route to UI
      if (event.type == 'ping') return;

      // Backend sends {"type":"status","status":"connected"} immediately on WS accept.
      // This is the handshake — only NOW do we declare ourselves truly connected.
      if (event.type == 'status' && data['status'] == 'connected') {
        _reconnectAttempts = 0;
        // Restore session text if backend provides it (reconnect scenario)
        if (data.containsKey('session_text')) {
          sessionText = data['session_text'] as String? ?? '';
        }
        _setState(WsConnectionState.connected);
      }

      // Capture available modes from initial status
      if (event.type == 'status' && data.containsKey('available_modes')) {
        availableModes =
            (data['available_modes'] as List).cast<String>().toList();
      }

      // Track latest session text from text_update events
      if (event.type == 'text_update') {
        sessionText = event.raw;
      }

      _eventController.add(event);
    } catch (e) {
      // Ignore malformed messages
    }
  }

  void _onError(dynamic error) {
    _setState(WsConnectionState.error);
    if (!_intentionalDisconnect) _scheduleReconnect();
  }

  void _onDone() {
    // The WS closed — only reconnect if this wasn't intentional.
    if (!_intentionalDisconnect) {
      _setState(WsConnectionState.disconnected);
      _scheduleReconnect();
    }
  }

  void _setState(WsConnectionState state) {
    _state = state;
    _connectionController.add(state);
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    // Exponential backoff: 2s, 4s, 8s, 16s, max 30s
    final backoffSeconds = (2 * (1 << _reconnectAttempts.clamp(0, 4)));
    _reconnectAttempts++;

    _reconnectTimer = Timer(Duration(seconds: backoffSeconds), () {
      if (_state != WsConnectionState.connected && !_intentionalDisconnect) {
        connect();
      }
    });
  }

  /// Watchdog: periodically checks that the server is still sending pings.
  /// Android Doze Mode silently kills sockets without firing onDone/onError.
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(_watchdogInterval, (_) {
      if (_intentionalDisconnect) return;
      final gap = DateTime.now().difference(_lastActivity);
      if (gap > _deadSocketThreshold) {
        // Socket is silently dead — force-reconnect
        _watchdogTimer?.cancel();
        _subscription?.cancel();
        _channel?.sink.close();
        _channel = null;
        _setState(WsConnectionState.disconnected);
        _scheduleReconnect();
      }
    });
  }

  void dispose() {
    disconnect();
    _watchdogTimer?.cancel();
    _eventController.close();
    _connectionController.close();
  }
}
