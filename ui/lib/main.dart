import 'dart:io';

import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _launchBackend();
  runApp(const VoiceForgeApp());
}

/// Launches the Python backend executable if it is not already running.
///
/// Checks port 8000 first — if the backend is reachable, skips launch.
/// Otherwise, starts backend/backend.exe in detached mode and waits
/// 2 seconds to let FastAPI/Uvicorn initialize before the UI connects.
Future<void> _launchBackend() async {
  // Check if backend is already running on port 8000
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    final request = await client.getUrl(Uri.parse('http://localhost:8000/'));
    final response = await request.close();
    client.close();
    if (response.statusCode == 200) {
      return; // Backend already running
    }
  } catch (_) {
    // Not reachable — proceed to launch
  }

  // Resolve backend path relative to this executable
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final backendExe = File('$exeDir${Platform.pathSeparator}backend${Platform.pathSeparator}backend.exe');

  if (await backendExe.exists()) {
    await Process.start(
      backendExe.path,
      [],
      mode: ProcessStartMode.detached,
      workingDirectory: backendExe.parent.path,
    );

    // Wait for backend to initialize before UI tries to connect
    await Future.delayed(const Duration(seconds: 2));
  }
}

class VoiceForgeApp extends StatelessWidget {
  const VoiceForgeApp({super.key});

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
