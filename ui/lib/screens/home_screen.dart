import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../widgets/transcription_panel.dart';
import '../widgets/mic_button.dart';
import '../widgets/mic_selector.dart';
import '../widgets/mode_selector.dart';
import '../widgets/connection_indicator.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = ApiService();
  final _ws = WebSocketService();

  // Modes shown in the UI (filtered from backend)
  static const _visibleModes = ['raw', 'clean', 'bullet', 'summary', 'prompt'];

  // State
  bool _isRecording = false;
  bool _isProcessing = false;
  String _currentMode = 'clean';
  List<String> _availableModes = _visibleModes;
  WsConnectionState _connectionState = WsConnectionState.disconnected;

  // Paragraph-based transcription
  String _liveText = '';
  final TextEditingController _rawController = TextEditingController();
  String _formattedOutput = '';         // right panel content

  // Subscriptions
  StreamSubscription? _eventSub;
  StreamSubscription? _connSub;
  final ScrollController _rawScroll = ScrollController();
  final ScrollController _fmtScroll = ScrollController();
  bool _shouldAutoScrollRaw = true;

  @override
  void initState() {
    super.initState();
    _rawScroll.addListener(() {
      if (_rawScroll.hasClients) {
        _shouldAutoScrollRaw = _rawScroll.position.pixels >= _rawScroll.position.maxScrollExtent - 50;
      }
    });
    _setupWebSocket();
  }

  void _setupWebSocket() {
    _connSub = _ws.connectionState.listen((state) {
      setState(() => _connectionState = state);
      if (state == WsConnectionState.connected) _fetchStatus();
    });

    _eventSub = _ws.events.listen(_handleEvent);
    _ws.connect();
  }

  Future<void> _fetchStatus() async {
    try {
      final status = await _api.getStatus();
      setState(() {
        _isRecording = status['pipeline_running'] as bool? ?? false;
        _currentMode = status['current_mode'] as String? ?? 'clean';
        final modes = status['available_modes'] as List?;
        if (modes != null) {
          // Filter to only show user-facing modes
          _availableModes = modes
              .cast<String>()
              .where((m) => _visibleModes.contains(m))
              .toList();
        }
      });
    } catch (_) {}
  }

  void _handleEvent(TranscriptionEvent event) {
    setState(() {
      switch (event.type) {
        case 'partial':
          _liveText = event.raw;
          break;

        case 'final':
          _liveText = '';
          // Append to controller text (preserves user edits)
          final existing = _rawController.text;
          if (existing.isEmpty) {
            _rawController.text = event.raw;
          } else {
            _rawController.text = '$existing ${event.raw}';
          }
          // Move cursor to end
          _rawController.selection = TextSelection.collapsed(
            offset: _rawController.text.length,
          );
          if (_shouldAutoScrollRaw) _scrollToBottom(_rawScroll);
          break;

        case 'paragraph_break':
          // Long pause → new paragraph (double newline)
          final text = _rawController.text;
          if (text.isNotEmpty && !text.endsWith('\n\n')) {
            _rawController.text = '$text\n\n';
            _rawController.selection = TextSelection.collapsed(
              offset: _rawController.text.length,
            );
          }
          break;

        case 'status':
          if (event.status == 'started') _isRecording = true;
          if (event.status == 'stopped') _isRecording = false;
          if (event.status == 'mode_changed') {
            _currentMode = event.mode.isNotEmpty ? event.mode : _currentMode;
          }
          if (_ws.availableModes.isNotEmpty) {
            _availableModes = _ws.availableModes
                .where((m) => _visibleModes.contains(m))
                .toList();
          }
          break;

        case 'error':
          _showSnackbar('⚠️ ${event.message}', isError: true);
          break;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Actions — buttons trigger transforms
  // ---------------------------------------------------------------------------

  /// Process with the selected mode → populate right panel.
  Future<void> _processWithMode(String mode) async {
    setState(() {
      _currentMode = mode;
    });
    await _processFullSession();
  }

  /// Process Full Session: uses current raw text from controller.
  Future<void> _processFullSession() async {
    final rawText = _rawController.text.trim();

    if (rawText.isEmpty) {
      _showSnackbar('Nothing to process yet');
      return;
    }

    setState(() => _isProcessing = true);

    try {
      await _api.setMode(_currentMode);

      // Transform using selected mode
      if (_currentMode == 'raw') {
        setState(() => _formattedOutput = rawText);
      } else {
        final result = await _api.transform(rawText, _currentMode);
        setState(() {
          _formattedOutput = result['formatted'] as String? ?? rawText;
        });
      }
      _scrollToBottom(_fmtScroll);
    } catch (e) {
      _showSnackbar('Transform failed: $e', isError: true);
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  /// Reprocess: re-runs current formatted output through the selected mode.
  Future<void> _reprocessOutput() async {
    if (_formattedOutput.trim().isEmpty) {
      _showSnackbar('Nothing to reprocess');
      return;
    }

    setState(() => _isProcessing = true);

    try {
      await _api.setMode(_currentMode);

      if (_currentMode == 'raw') {
        // Raw mode on formatted output is a no-op
        return;
      }

      final result = await _api.transform(_formattedOutput, _currentMode);
      setState(() {
        _formattedOutput = result['formatted'] as String? ?? _formattedOutput;
      });
      _scrollToBottom(_fmtScroll);
    } catch (e) {
      _showSnackbar('Reprocess failed: $e', isError: true);
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _toggleRecording() async {
    try {
      if (_isRecording) {
        await _api.stopStream();
      } else {
        await _api.startStream();
      }
    } catch (e) {
      _showSnackbar('Connection error: $e', isError: true);
    }
  }

  void _clearTranscript() {
    setState(() {
      _rawController.clear();
      _formattedOutput = '';
      _liveText = '';
    });
    _api.clearSession().catchError((_) => <String, dynamic>{});
  }

  Future<void> _confirmClear() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Clear current session?', style: TextStyle(color: Colors.white)),
        content: const Text('This will delete all raw and formatted transcription text.', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm', style: TextStyle(color: Color(0xFFFF6B6B))),
          ),
        ],
      ),
    );
    if (result == true) {
      _clearTranscript();
    }
  }

  void _scrollToBottom(ScrollController ctrl) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ctrl.hasClients) {
        ctrl.animateTo(
          ctrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showSnackbar(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red.shade800 : null,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Main content
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                _buildTopBar(),
                const SizedBox(height: 20),
                Expanded(child: _buildPanels()),
                const SizedBox(height: 20),
                _buildBottomBar(),
              ],
            ),
          ),

          // Floating mic button — always accessible, bottom-center
          Positioned(
            bottom: 52,
            left: 0,
            right: 0,
            child: Center(
              child: MicButton(
                isRecording: _isRecording,
                isConnected: _connectionState == WsConnectionState.connected,
                onPressed: _toggleRecording,
              ),
            ),
          ),
        ],
      ),
    );
  }

  AppStatus get _appStatus {
    if (_connectionState != WsConnectionState.connected) return AppStatus.disconnected;
    if (_isProcessing) return AppStatus.processing;
    if (_isRecording) return AppStatus.listening;
    return AppStatus.ready;
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        const Icon(Icons.graphic_eq_rounded,
            color: Color(0xFF6C5CE7), size: 28),
        const SizedBox(width: 12),
        const Text(
          'VoiceForge',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(width: 16),
        StatusIndicator(state: _appStatus),
        const SizedBox(width: 16),
        Container(
          width: 1,
          height: 24,
          color: Colors.white.withValues(alpha: 0.1),
        ),
        const SizedBox(width: 12),
        MicSelector(api: _api),
        const Spacer(),
        TextButton.icon(
          onPressed: _confirmClear,
          icon: const Icon(Icons.delete_sweep_rounded, size: 18),
          label: const Text('Clear'),
          style: TextButton.styleFrom(foregroundColor: Colors.white54),
        ),
      ],
    );
  }

  Widget _buildPanels() {
    // RIGHT: formatted output (single block)
    final fmtEntries = _formattedOutput.isNotEmpty
        ? [_formattedOutput]
        : <String>[];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // LEFT PANEL: Raw transcription — editable source of truth
        Expanded(
          child: TranscriptionPanel(
            title: 'Raw Transcription',
            icon: Icons.mic_rounded,
            accentColor: const Color(0xFF00B894),
            entries: const [],
            textController: _rawController,
            liveText: _liveText,
            scrollController: _rawScroll,
            isLive: _isRecording,
            showCopyButton: true,
          ),
        ),
        const SizedBox(width: 16),

        // RIGHT PANEL: Formatted output — on-demand
        Expanded(
          child: TranscriptionPanel(
            title: 'Formatted Output',
            icon: Icons.auto_fix_high_rounded,
            accentColor: const Color(0xFF6C5CE7),
            entries: fmtEntries,
            scrollController: _fmtScroll,
            showMode: true,
            mode: _currentMode,
            showCopyButton: true,
          ),
        ),
      ],
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          // Mode chips
          Flexible(
            child: ModeSelector(
              currentMode: _currentMode,
              availableModes: _availableModes,
              onModeChanged: _processWithMode,
              isProcessing: _isProcessing,
            ),
          ),
          const SizedBox(width: 12),

          // Process button
          ElevatedButton.icon(
             onPressed: _isProcessing ? null : _processFullSession,
             icon: _isProcessing 
                 ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                 : const Icon(Icons.bolt_rounded, size: 16),
             label: Text(_isProcessing ? 'Processing...' : 'Process'),
             style: ElevatedButton.styleFrom(
               backgroundColor: const Color(0xFF6C5CE7),
               foregroundColor: Colors.white,
               padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
               shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
               elevation: 0,
             ),
          ),
          const SizedBox(width: 8),

          // Reprocess button
          OutlinedButton.icon(
             onPressed: (_isProcessing || _formattedOutput.isEmpty) ? null : _reprocessOutput,
             icon: const Icon(Icons.refresh_rounded, size: 16),
             label: const Text('Reprocess'),
             style: OutlinedButton.styleFrom(
               foregroundColor: const Color(0xFFA29BFE),
               side: BorderSide(color: const Color(0xFFA29BFE).withValues(alpha: 0.4)),
               padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
               shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
             ),
          ),

          // Spacer to push content left, mic floats above via Stack
          const Spacer(),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _connSub?.cancel();
    _ws.dispose();
    _api.dispose();
    _rawController.dispose();
    _rawScroll.dispose();
    _fmtScroll.dispose();
    super.dispose();
  }
}
