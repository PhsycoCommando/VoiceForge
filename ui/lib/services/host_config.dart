/// HostConfig — persisted backend host for multi-device support.
///
/// Desktop: always uses localhost (backend runs locally).
/// Mobile:  reads/writes a Tailscale IP via SharedPreferences.
///
/// Call [HostConfig.load()] once at app startup before constructing services.
library;

import 'package:shared_preferences/shared_preferences.dart';

class HostConfig {
  HostConfig._(); // static-only class

  static const _prefKey   = 'backend_host';
  static const _portKey   = 'backend_port';
  static const defaultHost = 'localhost';
  static const defaultPort = 8000;

  static String _host = defaultHost;
  static int    _port = defaultPort;

  static String get host => _host;
  static int    get port => _port;

  static String get baseUrl => 'http://$_host:$_port';
  static String get wsUrl   => 'ws://$_host:$_port/stream';

  static bool get isLocalhost =>
      _host == 'localhost' || _host == '127.0.0.1';

  /// Load saved host from SharedPreferences.
  /// Falls back to localhost:8000 if nothing is saved.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _host = prefs.getString(_prefKey) ?? defaultHost;
    _port = prefs.getInt(_portKey)    ?? defaultPort;
  }

  /// Persist a new host. Does not reconnect — caller is responsible.
  static Future<void> save(String host, {int port = defaultPort}) async {
    _host = host.trim().isEmpty ? defaultHost : host.trim();
    _port = port;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, _host);
    await prefs.setInt(_portKey, _port);
  }

  /// Reset to localhost defaults.
  static Future<void> reset() async {
    await save(defaultHost, port: defaultPort);
  }
}
