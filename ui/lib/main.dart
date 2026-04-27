import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'screens/mobile_home_screen.dart';
import 'services/host_config.dart';

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

/// Tracked backend process — null if we didn't spawn it (was already running).
Process? _backendProcess;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await HostConfig.load();

  // Mobile: skip single-instance lock and local backend launch.
  // The app connects to a remote backend via Tailscale.
  if (Platform.isAndroid || Platform.isIOS) {
    runApp(const VoiceForgeApp());
    return;
  }

  // Desktop: enforce single instance then launch backend.
  if (!await _acquireInstanceLock()) {
    exit(0);
  }

  await _launchBackend();
  runApp(const VoiceForgeApp());
}

/// Launches the Python backend via the bundled venv if not already running.
///
/// Checks port 8000 first — if the backend is reachable, skips launch.
/// Otherwise, launches `backend/venv/Scripts/pythonw.exe server.py`
/// (falls back to python.exe if pythonw.exe is missing).
///
/// Uses [ProcessStartMode.detachedWithStdio] so we retain a handle to
/// kill the process on clean app exit, while still letting it survive
/// an app crash. pythonw.exe ensures no console window is shown.
Future<void> _launchBackend() async {
  final log = File('${Directory.systemTemp.path}\\vf_backend_debug.txt');
  void dbg(String msg) {
    log.writeAsStringSync('[${DateTime.now()}] $msg\n', mode: FileMode.append);
  }

  dbg('=== _launchBackend START ===');
  dbg('Platform.resolvedExecutable: ${Platform.resolvedExecutable}');
  dbg('Directory.current: ${Directory.current.path}');

  // Check if backend is already running on port 8000
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    final request = await client.getUrl(Uri.parse('http://localhost:8000/'));
    final response = await request.close();
    client.close();
    if (response.statusCode == 200) {
      dbg('Backend already running — reusing.');
      return;
    }
  } catch (e) {
    dbg('Backend not running: $e');
  }

  // Resolve backend directory — try multiple possible locations
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final sep = Platform.pathSeparator;
  final possiblePaths = [
    '$exeDir${sep}backend',
    '$exeDir$sep..$sep${sep}backend',
    '${Directory.current.path}${sep}backend',
  ];

  dbg('exeDir: $exeDir');
  for (final p in possiblePaths) {
    dbg('Checking path: $p → exists=${Directory(p).existsSync()}');
  }

  String? backendDir;
  for (final path in possiblePaths) {
    if (Directory(path).existsSync()) {
      backendDir = path;
      break;
    }
  }

  if (backendDir == null) {
    dbg('FATAL: Backend folder NOT found. Giving up.');
    return;
  }

  dbg('Using backendDir: $backendDir');

  // Prefer pythonw.exe (no console window), fall back to python.exe
  final pythonwPath = '$backendDir${sep}venv${sep}Scripts${sep}pythonw.exe';
  final pythonPath  = '$backendDir${sep}venv${sep}Scripts${sep}python.exe';
  final pythonw = File(pythonwPath);
  final python  = File(pythonPath);

  dbg('pythonw exists: ${await pythonw.exists()} at $pythonwPath');
  dbg('python  exists: ${await python.exists()}  at $pythonPath');

  final interpreter = await pythonw.exists()
      ? pythonw.path
      : (await python.exists() ? python.path : null);

  if (interpreter == null) {
    dbg('FATAL: No Python interpreter found.');
    return;
  }

  dbg('Interpreter: $interpreter');

  final env = Map<String, String>.from(Platform.environment);
  env['PYTHONIOENCODING'] = 'utf-8';
  // VOICEFORGE_MOCK_WAV intentionally not set -- mic uses real microphone.

  try {
    _backendProcess = await Process.start(
      interpreter,
      ['server.py'],
      mode: ProcessStartMode.detachedWithStdio,
      workingDirectory: backendDir,
      environment: env,
    );
    dbg('Backend spawned — PID: ${_backendProcess!.pid}');

    // Capture backend stdout/stderr to a log file for diagnosis
    final backendLog = File('${Directory.systemTemp.path}\\vf_backend_process.txt');
    _backendProcess!.stdout.listen((data) {
      backendLog.writeAsBytesSync(data, mode: FileMode.append);
    });
    _backendProcess!.stderr.listen((data) {
      backendLog.writeAsBytesSync(data, mode: FileMode.append);
    });
  } catch (e, st) {
    dbg('FATAL: Process.start threw: $e\n$st');
    return;
  }

  // Wait for backend to initialize before UI tries to connect
  await Future.delayed(const Duration(seconds: 3));
  dbg('_launchBackend DONE — waiting complete.');
}

/// Kills the backend process if we spawned it.
void _killBackend() {
  try {
    _backendProcess?.kill(ProcessSignal.sigterm);
  } catch (_) {}
  _backendProcess = null;
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
        _killBackend();
        _releaseInstanceLock();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    _killBackend();
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
      home: Platform.isAndroid || Platform.isIOS
          ? const MobileHomeScreen()
          : const HomeScreen(),
    );
  }
}
