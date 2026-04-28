import 'dart:io';

/// Singleton service managing the Python backend lifecycle (desktop only).
///
/// On startup, [launch] is called from main.dart to start the backend.
/// If the backend crashes or freezes, the UI can call [restart] to kill
/// the old process and spin up a fresh one.
class BackendService {
  BackendService._();
  static final instance = BackendService._();

  /// Tracked backend process — null if we didn't spawn it.
  Process? _process;

  /// Kill the backend process we spawned (if any).
  void kill() {
    try {
      _process?.kill(ProcessSignal.sigterm);
    } catch (_) {}
    _process = null;
  }

  /// Launch the Python backend if not already running on port 8000.
  ///
  /// Checks port 8000 first — if the backend is reachable, skips launch.
  /// Otherwise, launches `backend/venv/Scripts/pythonw.exe server.py`
  /// (falls back to python.exe if pythonw.exe is missing).
  Future<void> launch() async {
    final log = File('${Directory.systemTemp.path}\\vf_backend_debug.txt');
    void dbg(String msg) {
      log.writeAsStringSync('[${DateTime.now()}] $msg\n', mode: FileMode.append);
    }

    dbg('=== BackendService.launch START ===');
    dbg('Platform.resolvedExecutable: ${Platform.resolvedExecutable}');
    dbg('Directory.current: ${Directory.current.path}');

    // Check if backend is already running on port 8000.
    try {
      final statusCode = await Future(() async {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
        try {
          final request = await client.getUrl(Uri.parse('http://localhost:8000/'));
          final response = await request.close();
          await response.drain<void>();
          client.close();
          return response.statusCode;
        } finally {
          client.close();
        }
      }).timeout(const Duration(seconds: 3), onTimeout: () => -1);

      if (statusCode == 200) {
        dbg('Backend already running — reusing.');
        return;
      }
      dbg('Backend responded with status $statusCode — will try to respawn.');
    } catch (e) {
      dbg('Backend not running: $e');
    }

    await _spawnProcess(dbg);
  }

  /// Kill current + orphaned backend processes, then relaunch.
  Future<void> restart() async {
    kill();

    // Kill orphaned pythonw.exe processes that may hold port 8000.
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/F', '/IM', 'pythonw.exe']);
      } catch (_) {}
    }

    await Future.delayed(const Duration(milliseconds: 500));
    await launch();
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  Future<void> _spawnProcess(void Function(String) dbg) async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    final possiblePaths = [
      '$exeDir${sep}backend',
      '$exeDir$sep..$sep${sep}backend',
      '${Directory.current.path}${sep}backend',
      // flutter run from ui/ — backend is at ../backend (repo root)
      '${Directory.current.path}$sep..${sep}backend',
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

    try {
      _process = await Process.start(
        interpreter,
        ['server.py'],
        mode: ProcessStartMode.detachedWithStdio,
        workingDirectory: backendDir,
        environment: env,
      );
      dbg('Backend spawned — PID: ${_process!.pid}');

      // Capture backend stdout/stderr to a log file for diagnosis
      final backendLog = File('${Directory.systemTemp.path}\\vf_backend_process.txt');
      _process!.stdout.listen((data) {
        backendLog.writeAsBytesSync(data, mode: FileMode.append);
      });
      _process!.stderr.listen((data) {
        backendLog.writeAsBytesSync(data, mode: FileMode.append);
      });
    } catch (e, st) {
      dbg('FATAL: Process.start threw: $e\n$st');
      return;
    }

    await Future.delayed(const Duration(seconds: 1));
    dbg('BackendService.launch DONE — WS will retry until backend ready.');
  }
}
