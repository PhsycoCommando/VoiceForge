import 'dart:io';

/// Singleton service managing the Python backend lifecycle (desktop only).
///
/// Cross-platform: handles Windows (.exe venv) and Linux (.venv) layouts.
/// Port: 8765 (VoiceForge Linux standard)
class BackendService {
  BackendService._();
  static final instance = BackendService._();

  static const int backendPort = 8765;

  /// Tracked backend process — null if we didn't spawn it.
  Process? _process;

  /// Kill the backend process we spawned (if any).
  void kill() {
    try {
      _process?.kill(ProcessSignal.sigterm);
    } catch (_) {}
    _process = null;
  }

  /// Launch the Python backend if not already running.
  ///
  /// Checks port 8765 first — if the backend is reachable, skips launch.
  /// On Windows: uses venv/Scripts/pythonw.exe
  /// On Linux:   uses .venv/bin/python3 + uvicorn
  Future<void> launch() async {
    final logPath = Platform.isWindows
        ? '${Directory.systemTemp.path}\\vf_backend_debug.txt'
        : '/tmp/vf_backend_debug.txt';
    final log = File(logPath);
    void dbg(String msg) {
      log.writeAsStringSync('[${DateTime.now()}] $msg\n', mode: FileMode.append);
    }

    dbg('=== BackendService.launch START ===');
    dbg('Platform: ${Platform.operatingSystem}');
    dbg('Platform.resolvedExecutable: ${Platform.resolvedExecutable}');

    // Check if backend is already running.
    try {
      final statusCode = await Future(() async {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
        try {
          final request = await client.getUrl(Uri.parse('http://localhost:$backendPort/'));
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
      dbg('Backend responded with status $statusCode — will respawn.');
    } catch (e) {
      dbg('Backend not running: $e');
    }

    // Kill orphaned processes
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/F', '/IM', 'pythonw.exe']);
      } catch (_) {}
    } else {
      try {
        await Process.run('pkill', ['-f', 'uvicorn server:app']);
      } catch (_) {}
    }
    await Future.delayed(const Duration(milliseconds: 500));

    await _spawnProcess(dbg);
  }

  /// Kill current + orphaned backend processes, then relaunch.
  Future<void> restart() async {
    kill();
    if (Platform.isWindows) {
      try { await Process.run('taskkill', ['/F', '/IM', 'pythonw.exe']); } catch (_) {}
    } else {
      try { await Process.run('pkill', ['-f', 'uvicorn server:app']); } catch (_) {}
    }
    await Future.delayed(const Duration(milliseconds: 500));
    await launch();
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  Future<void> _spawnProcess(void Function(String) dbg) async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;

    // Search paths for the backend directory
    final possiblePaths = [
      '$exeDir${sep}backend',
      '$exeDir$sep..${sep}backend',
      '${Directory.current.path}${sep}backend',
      '${Directory.current.path}$sep..${sep}backend',
      // Linux: ~/VoiceForge/backend
      '${Platform.environment['HOME'] ?? ''}${sep}VoiceForge${sep}backend',
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

    String? interpreter;
    List<String> args;

    if (Platform.isWindows) {
      // Windows: venv/Scripts/pythonw.exe server.py
      final pythonwPath = '$backendDir${sep}venv${sep}Scripts${sep}pythonw.exe';
      final pythonPath  = '$backendDir${sep}venv${sep}Scripts${sep}python.exe';
      final pythonw = File(pythonwPath);
      final python  = File(pythonPath);
      dbg('pythonw: ${await pythonw.exists()} | python: ${await python.exists()}');
      interpreter = await pythonw.exists()
          ? pythonw.path
          : (await python.exists() ? python.path : null);
      args = ['server.py'];
    } else {
      // Linux/macOS: .venv/bin/uvicorn server:app
      final uvicornPath  = '$backendDir${sep}.venv${sep}bin${sep}uvicorn';
      final uvicorn = File(uvicornPath);
      dbg('uvicorn: ${await uvicorn.exists()} at $uvicornPath');
      if (await uvicorn.exists()) {
        interpreter = uvicorn.path;
        args = ['server:app', '--host', '127.0.0.1', '--port', '$backendPort', '--log-level', 'warning'];
      } else {
        // Fallback: python3 from venv
        final python3 = '$backendDir${sep}.venv${sep}bin${sep}python3';
        dbg('python3: ${File(python3).existsSync()} at $python3');
        interpreter = File(python3).existsSync() ? python3 : null;
        args = ['-m', 'uvicorn', 'server:app', '--host', '127.0.0.1', '--port', '$backendPort'];
      }
    }

    if (interpreter == null) {
      dbg('FATAL: No Python interpreter found in $backendDir');
      return;
    }

    dbg('Interpreter: $interpreter args: $args');

    final env = Map<String, String>.from(Platform.environment);
    env['PYTHONIOENCODING'] = 'utf-8';

    try {
      _process = await Process.start(
        interpreter,
        args,
        mode: ProcessStartMode.detachedWithStdio,
        workingDirectory: backendDir,
        environment: env,
      );
      dbg('Backend spawned — PID: ${_process!.pid}');

      // Log backend output to /tmp for diagnosis
      final backendLog = Platform.isWindows
          ? File('${Directory.systemTemp.path}\\vf_backend_process.txt')
          : File('/tmp/vf_backend_process.txt');
      _process!.stdout.listen((data) => backendLog.writeAsBytesSync(data, mode: FileMode.append));
      _process!.stderr.listen((data) => backendLog.writeAsBytesSync(data, mode: FileMode.append));
    } catch (e, st) {
      dbg('FATAL: Process.start threw: $e\n$st');
      return;
    }

    await Future.delayed(const Duration(seconds: 2));
    dbg('BackendService.launch DONE');
  }
}
