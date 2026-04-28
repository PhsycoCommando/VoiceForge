import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'services/backend_service.dart';

// ─── Single-instance lock via ServerSocket port bind ─────────────────────────
// Bind port 47832 exclusively. A second instance cannot bind the same port
// — the OS throws SocketException immediately. Zero race window.

ServerSocket? _lockSocket;

/// Acquire the single-instance lock. Returns true if we are the only instance.
Future<bool> _acquireInstanceLock() async {
  final log = File('${Directory.systemTemp.path}${Platform.pathSeparator}vf_lock_debug.txt');
  try {
    log.writeAsStringSync('[${DateTime.now()}] Attempting bind port 47832...\n', mode: FileMode.append);
    _lockSocket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      47832,
      shared: false,
    );
    log.writeAsStringSync('[${DateTime.now()}] SUCCESS — bound port 47832\n', mode: FileMode.append);
    return true;
  } on SocketException catch (e) {
    log.writeAsStringSync('[${DateTime.now()}] SocketException: $e\n', mode: FileMode.append);
    return false;
  } catch (e, st) {
    log.writeAsStringSync('[${DateTime.now()}] OTHER ERROR: $e\n$st\n', mode: FileMode.append);
    return false; // treat any error as "already running" — fail safe
  }
}

void _releaseInstanceLock() {
  _lockSocket?.close();
  _lockSocket = null;
}
// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Enforce single instance then launch backend.
  if (!await _acquireInstanceLock()) {
    // A stale/zombie process may be holding the lock.
    // Kill any lingering VoiceForge/voice_forge_ui processes and retry once.
    try {
      await Process.run('taskkill', ['/F', '/IM', 'VoiceForge.exe']);
    } catch (_) {}
    try {
      await Process.run('taskkill', ['/F', '/IM', 'voice_forge_ui.exe']);
    } catch (_) {}
    await Future.delayed(const Duration(seconds: 1));

    if (!await _acquireInstanceLock()) {
      // Still can't get the lock — truly another instance running.
      exit(0);
    }
  }

  await BackendService.instance.launch();
  runApp(const VoiceForgeApp());
}


class VoiceForgeApp extends StatefulWidget {
  const VoiceForgeApp({super.key});

  @override
  State<VoiceForgeApp> createState() => _VoiceForgeAppState();
}

class _VoiceForgeAppState extends State<VoiceForgeApp> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        BackendService.instance.kill();
        _releaseInstanceLock();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    BackendService.instance.kill();
    _releaseInstanceLock();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoiceForge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF6C5CE7),
        useMaterial3: true,
        fontFamily: 'Inter',
        scaffoldBackgroundColor: const Color(0xFF0D0D1A),
        cardTheme: CardThemeData(
          color: const Color(0xFF1A1A2E),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
