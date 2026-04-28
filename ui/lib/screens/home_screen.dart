import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../widgets/transcription_panel.dart';
import '../widgets/mic_button.dart';
import '../widgets/mic_selector.dart';
import '../widgets/mode_selector.dart';
import '../widgets/connection_indicator.dart';
import '../widgets/file_transcribe_button.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = ApiService();
  final _ws = WebSocketService();

  // Modes shown in the UI (filtered from backend)
  static const _visibleModes = ['raw', 'clean', 'bullet', 'summary', 'prompt', 'markdown', 'speech'];

  // State
  bool _isRecording = false;
  bool _isTranscribing = false;
  bool _isProcessing = false;
  String _currentMode = 'clean';
  List<String> _availableModes = _visibleModes;
  WsConnectionState _connectionState = WsConnectionState.disconnected;

  // Paragraph-based transcription
  String _liveText = '';
  int _sessionStartOffset = 0; // where the current recording session begins in _rawController
  final TextEditingController _rawController = TextEditingController();
  String _formattedOutput = '';         // right panel content

  // Subscriptions
  StreamSubscription? _eventSub;
  StreamSubscription? _connSub;
  final ScrollController _rawScroll = ScrollController();
  final ScrollController _fmtScroll = ScrollController();
  bool _shouldAutoScrollRaw = true;

  // Text sync — suppress the debounce echo when we receive a remote text_update
  bool _suppressTextUpdate = false;
  Timer? _textUpdateDebounce;

  // Set to true when THIS client sends the start command.
  // Only the initiating device adds the visual separator to avoid doubles.
  bool _isInitiatingRecording = false;

  // True when this client started the current session.
  // Non-initiating device blocks its post-session debounce to avoid
  // overwriting the initiating device's text (which includes the separator).
  bool _sessionIsLocal = true;

  @override
  void initState() {
    super.initState();
    _rawScroll.addListener(() {
      if (_rawScroll.hasClients) {
        _shouldAutoScrollRaw = _rawScroll.position.pixels >= _rawScroll.position.maxScrollExtent - 50;
      }
    });
    // Send debounced text_update when the user types in the raw panel
    _rawController.addListener(_onRawTextChanged);
    _setupWebSocket();
  }

  void _setupWebSocket() {
    _connSub = _ws.connectionState.listen((state) {
      setState(() => _connectionState = state);
      if (state == WsConnectionState.connected) {
        _fetchStatus();
        // Restore session text if backend has prior content (e.g. phone recorded)
        if (_ws.sessionText.isNotEmpty && _rawController.text.isEmpty) {
          setState(() {
            _suppressTextUpdate = true;
            _rawController.text = _ws.sessionText;
            _suppressTextUpdate = false;
          });
        }
      }
    });

    _eventSub = _ws.events.listen(_handleEvent);
    _ws.connect();
  }

  /// Debounced raw-text listener — sends text_update 500ms after the user
  /// stops typing. Suppressed during recording/transcribing (backend is the
  /// source of truth) and when we're applying a remote text_update ourselves.
  void _onRawTextChanged() {
    if (_suppressTextUpdate) return;
    if (_isRecording || _isTranscribing) return;
    // Non-initiating device: don't debounce — our text lacks the separator.
    // We'll get the authoritative text via text_update from the other device.
    if (!_sessionIsLocal) return;
    _textUpdateDebounce?.cancel();
    _textUpdateDebounce = Timer(const Duration(milliseconds: 500), () {
      _ws.sendTextUpdate(_rawController.text);
    });
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
          // Write partial text directly into the raw panel from the session
          // start offset, replacing as Whisper updates its running transcript.
          {
            final before = _rawController.text.substring(0, _sessionStartOffset);
            _rawController.text = before + event.raw;
            _rawController.selection = TextSelection.collapsed(
              offset: _rawController.text.length,
            );
            if (_shouldAutoScrollRaw) _scrollToBottom(_rawScroll);
          }
          break;

        case 'final':
          _isTranscribing = false;
          _liveText = '';
          // Replace from _sessionStartOffset with the definitive transcription.
          {
            final before = _rawController.text.substring(0, _sessionStartOffset);
            _rawController.text = before + event.raw;
            _rawController.selection = TextSelection.collapsed(
              offset: _rawController.text.length,
            );
            if (_shouldAutoScrollRaw) _scrollToBottom(_rawScroll);
          }
          break;

        case 'paragraph_break':
          break; // handled by pause detection now

        case 'status':
          if (event.status == 'started') {
            _isRecording = true;
            _sessionIsLocal = _isInitiatingRecording;
            if (_isInitiatingRecording && _rawController.text.isNotEmpty) {
              _rawController.text = '${_rawController.text}\n\n─────────────────────\n\n';
              _rawController.selection = TextSelection.collapsed(
                offset: _rawController.text.length,
              );
              if (_shouldAutoScrollRaw) _scrollToBottom(_rawScroll);
            }
            _isInitiatingRecording = false;
            _sessionStartOffset = _rawController.text.length;
          }
          if (event.status == 'stopped') {
            _isRecording = false;
            _isTranscribing = false;
            // Safety: restore edit rights on non-initiating device after 2s
            // in case the authoritative text_update never arrives.
            if (!_sessionIsLocal) {
              Future.delayed(const Duration(seconds: 2), () {
                if (mounted) setState(() => _sessionIsLocal = true);
              });
            }
          }
          if (event.status == 'cleared') {
            _textUpdateDebounce?.cancel();
            _suppressTextUpdate = true;
            _rawController.clear();
            _suppressTextUpdate = false;
            _formattedOutput = '';
            _liveText = '';
            _sessionStartOffset = 0;
            _sessionIsLocal = true;
          }
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

        case 'text_update':
          // Cancel any pending stale debounce before applying authoritative text.
          _textUpdateDebounce?.cancel();
          _suppressTextUpdate = true;
          _rawController.text = event.raw;
          _rawController.selection = TextSelection.collapsed(
            offset: _rawController.text.length,
          );
          _suppressTextUpdate = false;
          _sessionIsLocal = true; // received authoritative text — edits can sync again
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
    // Strip session separators — visual only, never sent to formatter.
    var rawText = _rawController.text
        .split('\n')
        .where((line) => !line.trim().startsWith('─'))
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();

    // Pause dots (3+ consecutive periods) are stripped for clean/raw modes
    // but kept for bullet/summary/markdown/prompt where they hint at thought breaks.
    const modesWithoutDots = {'clean', 'raw'};
    if (modesWithoutDots.contains(_currentMode)) {
      rawText = rawText
          .replaceAll(RegExp(r'\.{3,}'), '')
          .replaceAll(RegExp(r'  +'), ' ')
          .trim();
    }



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
    // Optimistically flip state immediately so the UI feels responsive.
    // The WS status event will confirm or correct this.
    final wasRecording = _isRecording;
    setState(() {
      _isRecording = !wasRecording;
      if (wasRecording) {
        _liveText = '';       // clear partial bubble on stop
        _isTranscribing = true; // Whisper is now processing
      }
    });

    try {
      if (wasRecording) {
        await _api.stopStream();
      } else {
        _isInitiatingRecording = true; // this client is starting — add separator
        await _api.startStream();
      }
    } catch (e) {
      // Revert optimistic state on failure
      setState(() => _isRecording = wasRecording);
      _showSnackbar('Connection error: $e', isError: true);
    }
  }

  void _clearTranscript() {
    _textUpdateDebounce?.cancel(); // prevent stale debounce from restoring text
    setState(() {
      _suppressTextUpdate = true;
      _rawController.clear();
      _suppressTextUpdate = false;
      _formattedOutput = '';
      _liveText = '';
      _sessionStartOffset = 0;
      _sessionIsLocal = true;
    });
    _ws.sendClear();
  }

  /// Called when a file is successfully transcribed — appends to raw panel.
  void _onFileTranscribed(String rawText, String filename) {
    setState(() {
      final existing = _rawController.text;
      final prefix = existing.isEmpty ? '' : '\n\n';
      _rawController.text = '$existing${prefix}$rawText';
      _rawController.selection = TextSelection.collapsed(
        offset: _rawController.text.length,
      );
    });
    _scrollToBottom(_rawScroll);
    _showSnackbar('✅ Transcribed: $filename');
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
      body: Padding(
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
    );
  }

  AppStatus get _appStatus {
    if (_connectionState != WsConnectionState.connected) return AppStatus.disconnected;
    if (_isProcessing)    return AppStatus.processing;
    if (_isTranscribing) return AppStatus.transcribing;
    if (_isRecording)    return AppStatus.listening;
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
        Container(width: 1, height: 24, color: Colors.white.withValues(alpha: 0.1)),
        const SizedBox(width: 12),
        // Mic selector + file button wrapped so they can shrink at narrow widths
        Flexible(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              MicSelector(api: _api),
              const SizedBox(width: 12),
              Container(width: 1, height: 24, color: Colors.white.withValues(alpha: 0.1)),
              const SizedBox(width: 12),
              FileTranscribeButton(
                api: _api,
                onTranscribed: _onFileTranscribed,
              ),
            ],
          ),
        ),
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          // Mode chips — clicking a chip selects AND processes immediately
          Flexible(
            child: ModeSelector(
              currentMode: _currentMode,
              availableModes: _availableModes,
              onModeChanged: _processWithMode,
              isProcessing: _isProcessing,
            ),
          ),

          // ↺ Reprocess icon — re-runs current mode
          const SizedBox(width: 8),
          Tooltip(
            message: 'Reprocess with current mode',
            child: IconButton(
              onPressed: (_isProcessing || _formattedOutput.isEmpty) ? null : _reprocessOutput,
              icon: _isProcessing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFA29BFE)))
                  : const Icon(Icons.refresh_rounded, size: 18, color: Color(0xFFA29BFE)),
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFFA29BFE).withValues(alpha: 0.08),
                disabledBackgroundColor: Colors.transparent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.all(10),
              ),
            ),
          ),

          // ── Mic button — right end of bar ────────────────────────────────
          const SizedBox(width: 12),
          MicButton(
            isRecording: _isRecording,
            isConnected: _connectionState == WsConnectionState.connected,
            onPressed: _toggleRecording,
          ),
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
