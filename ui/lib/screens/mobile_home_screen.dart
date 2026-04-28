import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/host_config.dart';
import '../services/phone_mic_service.dart';
import '../services/websocket_service.dart';
import '../widgets/connection_indicator.dart';
import '../widgets/mic_button.dart';
import 'settings_screen.dart';

/// Mobile layout for VoiceForge.
///
/// Same state logic as HomeScreen but with:
///  - PageView (swipe between Raw ↔ Formatted panels)
///  - Horizontal-scrollable mode chip row
///  - Large centered mic FAB
///  - Settings gear → SettingsScreen (Tailscale IP config)
///
/// No backend auto-launch — assumes remote backend via Tailscale.
class MobileHomeScreen extends StatefulWidget {
  const MobileHomeScreen({super.key});

  @override
  State<MobileHomeScreen> createState() => _MobileHomeScreenState();
}

class _MobileHomeScreenState extends State<MobileHomeScreen> {
  // ── Services (built from HostConfig) ──────────────────────────────────────
  late ApiService       _api;
  late WebSocketService _ws;
  late PhoneMicService  _mic;

  // ── Modes ──────────────────────────────────────────────────────────────────
  static const _visibleModes = ['raw', 'clean', 'bullet', 'summary', 'prompt', 'markdown', 'speech'];

  // ── State ──────────────────────────────────────────────────────────────────
  bool _isRecording    = false;
  bool _isTranscribing = false;
  bool _isProcessing   = false;
  String _currentMode  = 'clean';
  List<String> _availableModes = _visibleModes;
  WsConnectionState _connectionState = WsConnectionState.disconnected;

  // Transcript
  int    _sessionStartOffset = 0;
  final  TextEditingController _rawController = TextEditingController();
  String _formattedOutput = '';

  // Subscriptions
  StreamSubscription? _eventSub;
  StreamSubscription? _connSub;
  final ScrollController _rawScroll = ScrollController();
  final ScrollController _fmtScroll = ScrollController();
  bool _shouldAutoScrollRaw = true;

  // Text sync
  bool _suppressTextUpdate = false;
  Timer? _textUpdateDebounce;

  // Set to true when THIS client sends the start command.
  // Only the initiating device adds the visual separator to avoid doubles.
  bool _isInitiatingRecording = false;

  // Page controller for swipe between Raw / Formatted
  final PageController _pageCtrl = PageController();
  int _currentPage = 0;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _rawScroll.addListener(() {
      if (_rawScroll.hasClients) {
        _shouldAutoScrollRaw =
            _rawScroll.position.pixels >= _rawScroll.position.maxScrollExtent - 50;
      }
    });
    _rawController.addListener(_onRawTextChanged);
    _initServices();

    // If still on localhost, phone can't connect — redirect to Settings immediately.
    if (HostConfig.isLocalhost) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openSettingsForFirstTime());
    }
  }

  Future<void> _openSettingsForFirstTime() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('📱 Enter your PC’s Tailscale IP to connect'),
        duration: Duration(seconds: 4),
        backgroundColor: Color(0xFF6C5CE7),
      ),
    );
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(onHostSaved: _reinitServices),
      ),
    );
  }

  void _onRawTextChanged() {
    if (_suppressTextUpdate) return;
    if (_isRecording || _isTranscribing) return;
    _textUpdateDebounce?.cancel();
    _textUpdateDebounce = Timer(const Duration(milliseconds: 500), () {
      _ws.sendTextUpdate(_rawController.text);
    });
  }

  void _initServices() {
    _api = ApiService(baseUrl: HostConfig.baseUrl);
    _ws  = WebSocketService(wsUrl: HostConfig.wsUrl);
    _mic = PhoneMicService(_ws);
    _connSub = _ws.connectionState.listen((state) {
      setState(() => _connectionState = state);
      if (state == WsConnectionState.connected) {
        _fetchStatus();
        // Restore session text from backend handshake (if phone connects mid-session)
        if (_ws.sessionText.isNotEmpty && _rawController.text.isEmpty) {
          _suppressTextUpdate = true;
          _rawController.text = _ws.sessionText;
          _suppressTextUpdate = false;
          setState(() {});
        }
      }
    });
    _eventSub = _ws.events.listen(_handleEvent);
    _ws.connect();
  }

  void _reinitServices() {
    _eventSub?.cancel();
    _connSub?.cancel();
    _ws.dispose();
    _api.dispose();
    _mic.dispose();
    setState(() => _connectionState = WsConnectionState.disconnected);
    _initServices();
  }

  @override
  void dispose() {
    _textUpdateDebounce?.cancel();
    _eventSub?.cancel();
    _connSub?.cancel();
    _mic.dispose();
    _ws.dispose();
    _api.dispose();
    _rawController.dispose();
    _rawScroll.dispose();
    _fmtScroll.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  // ── Status / events ────────────────────────────────────────────────────────

  Future<void> _fetchStatus() async {
    try {
      final status = await _api.getStatus();
      setState(() {
        _isRecording = status['pipeline_running'] as bool? ?? false;
        _currentMode = status['current_mode'] as String? ?? 'clean';
        final modes  = status['available_modes'] as List?;
        if (modes != null) {
          _availableModes = modes.cast<String>().where(_visibleModes.contains).toList();
        }
      });
    } catch (_) {}
  }

  void _handleEvent(TranscriptionEvent event) {
    setState(() {
      switch (event.type) {
        case 'partial':
          final before = _rawController.text.substring(0, _sessionStartOffset);
          _rawController.text = before + event.raw;
          _rawController.selection = TextSelection.collapsed(offset: _rawController.text.length);
          if (_shouldAutoScrollRaw) _scrollToBottom(_rawScroll);

        case 'final':
          _isTranscribing = false;
          final before = _rawController.text.substring(0, _sessionStartOffset);
          _rawController.text = before + event.raw;
          _rawController.selection = TextSelection.collapsed(offset: _rawController.text.length);
          if (_shouldAutoScrollRaw) _scrollToBottom(_rawScroll);

        case 'paragraph_break':
          break;

        case 'status':
          if (event.status == 'started') {
            _isRecording = true;
            if (_isInitiatingRecording && _rawController.text.isNotEmpty) {
              _rawController.text = '${_rawController.text}\n\n─────────────────────\n\n';
              _rawController.selection = TextSelection.collapsed(offset: _rawController.text.length);
              if (_shouldAutoScrollRaw) _scrollToBottom(_rawScroll);
            }
            _isInitiatingRecording = false; // consumed
            _sessionStartOffset = _rawController.text.length;
          }
          if (event.status == 'stopped') {
            _isRecording    = false;
            _isTranscribing = false;
          }
          if (event.status == 'cleared') {
            _suppressTextUpdate = true;
            _rawController.clear();
            _suppressTextUpdate = false;
            _formattedOutput    = '';
            _sessionStartOffset = 0;
          }
          if (event.status == 'mode_changed') {
            _currentMode = event.mode.isNotEmpty ? event.mode : _currentMode;
          }
          if (_ws.availableModes.isNotEmpty) {
            _availableModes = _ws.availableModes.where(_visibleModes.contains).toList();
          }

        case 'error':
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('⚠️ ${event.message}'), backgroundColor: Colors.red.shade800),
          );

        case 'text_update':
          _suppressTextUpdate = true;
          _rawController.text = event.raw;
          _rawController.selection = TextSelection.collapsed(offset: _rawController.text.length);
          _suppressTextUpdate = false;
          if (_shouldAutoScrollRaw) _scrollToBottom(_rawScroll);
      }
    });
  }

  // ── Recording ──────────────────────────────────────────────────────────────

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      setState(() { _isRecording = false; _isTranscribing = true; });
      await _mic.stop();
    } else {
      _isInitiatingRecording = true; // this phone is starting — add separator
      final started = await _mic.start();
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Microphone permission denied'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ── Processing ─────────────────────────────────────────────────────────────

  Future<void> _processWithMode(String mode) async {
    setState(() => _currentMode = mode);
    await _processFullSession();
  }

  Future<void> _processFullSession() async {
    var rawText = _rawController.text
        .split('\n')
        .where((line) => !line.trim().startsWith('─'))
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();

    const modesWithoutDots = {'clean', 'raw'};
    if (modesWithoutDots.contains(_currentMode)) {
      rawText = rawText
          .replaceAll(RegExp(r'\.{3,}'), '')
          .replaceAll(RegExp(r'  +'), ' ')
          .trim();
    }

    if (rawText.isEmpty) return;

    setState(() => _isProcessing = true);
    try {
      await _api.setMode(_currentMode);
      if (_currentMode == 'raw') {
        setState(() => _formattedOutput = rawText);
      } else {
        final result = await _api.transform(rawText, _currentMode);
        setState(() {
          _formattedOutput = result['formatted'] as String? ?? rawText;
        });
      }
      // Auto-navigate to formatted page after processing
      if (_currentPage == 0) {
        _pageCtrl.animateToPage(1,
            duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Processing error: $e'), backgroundColor: Colors.red.shade800),
      );
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _scrollToBottom(ScrollController ctrl) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ctrl.hasClients) {
        ctrl.animateTo(ctrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  // ── AppStatus ──────────────────────────────────────────────────────────────

  AppStatus get _appStatus {
    if (_connectionState != WsConnectionState.connected) return AppStatus.disconnected;
    if (_isTranscribing) return AppStatus.transcribing;
    if (_isRecording)    return AppStatus.listening;
    return AppStatus.ready;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(child: _buildPageView()),
            _buildPageIndicator(),
            _buildModeRow(),
            _buildMicBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          // Logo
          const Icon(Icons.graphic_eq_rounded, color: Color(0xFF6C5CE7), size: 22),
          const SizedBox(width: 8),
          const Text('VoiceForge',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
          const Spacer(),
          // Status
          StatusIndicator(state: _appStatus),
          const SizedBox(width: 12),
          // Settings
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SettingsScreen(onHostSaved: _reinitServices),
              ),
            ),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.settings_rounded, size: 18, color: Colors.white54),
            ),
          ),
          // Clear
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              setState(() {
                _suppressTextUpdate = true;
                _rawController.text = '';
                _suppressTextUpdate = false;
                _formattedOutput    = '';
                _sessionStartOffset = 0;
              });
              _ws.sendClear();
            },
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.delete_outline_rounded, size: 18, color: Colors.white54),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageView() {
    return PageView(
      controller: _pageCtrl,
      onPageChanged: (i) => setState(() => _currentPage = i),
      children: [
        _buildRawPage(),
        _buildFormattedPage(),
      ],
    );
  }

  Widget _buildRawPage() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  Icon(Icons.mic_rounded, size: 16,
                      color: _isRecording ? const Color(0xFF00B894) : Colors.white38),
                  const SizedBox(width: 8),
                  const Text('Raw Transcription',
                      style: TextStyle(color: Color(0xFF00B894), fontSize: 14, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF2A2A3E)),
            // Content — always show TextField so user can tap to type.
            // When empty, hint text guides the user instead of a dead placeholder.
            Expanded(
              child: Scrollbar(
                controller: _rawScroll,
                child: TextField(
                  controller: _rawController,
                  scrollController: _rawScroll,
                  maxLines: null,
                  expands: true,   // fills the Expanded so the whole area is tappable
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.6),
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.all(16),
                    border: InputBorder.none,
                    hintText: 'Tap 🎤 to start recording, or type here…',
                    hintStyle: TextStyle(color: Colors.white24, fontSize: 13),
                    hintMaxLines: 2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormattedPage() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  const Icon(Icons.auto_fix_high_rounded, size: 16, color: Color(0xFFA29BFE)),
                  const SizedBox(width: 8),
                  const Text('Formatted Output',
                      style: TextStyle(color: Color(0xFFA29BFE), fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6C5CE7).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(_currentMode,
                        style: const TextStyle(color: Color(0xFFA29BFE), fontSize: 11)),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF2A2A3E)),
            // Content
            Expanded(
              child: _formattedOutput.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.mic_off_rounded, size: 40, color: Colors.white12),
                          SizedBox(height: 12),
                          Text('Select a mode and tap ↺ to process',
                              style: TextStyle(color: Colors.white24, fontSize: 13)),
                        ],
                      ),
                    )
                  : Scrollbar(
                      controller: _fmtScroll,
                      child: SingleChildScrollView(
                        controller: _fmtScroll,
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(
                          _formattedOutput,
                          style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.6),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(2, (i) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width:  _currentPage == i ? 20 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: _currentPage == i
                  ? const Color(0xFF6C5CE7)
                  : Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(4),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildModeRow() {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _availableModes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final mode       = _availableModes[i];
          final isSelected = mode == _currentMode;
          const aiModes    = {'summary', 'prompt', 'markdown', 'speech'};
          final accent     = aiModes.contains(mode)
              ? const Color(0xFFA29BFE)
              : const Color(0xFF6C5CE7);

          return GestureDetector(
            onTap: _isProcessing ? null : () => _processWithMode(mode),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? accent.withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected
                      ? accent.withValues(alpha: 0.5)
                      : Colors.white.withValues(alpha: 0.1),
                ),
              ),
              child: Text(
                mode[0].toUpperCase() + mode.substring(1),
                style: TextStyle(
                  color: isSelected ? accent : Colors.white54,
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMicBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Reprocess
          IconButton(
            onPressed: (_isProcessing || _formattedOutput.isEmpty)
                ? null
                : _processFullSession,
            icon: _isProcessing
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFA29BFE)))
                : const Icon(Icons.refresh_rounded, size: 20, color: Color(0xFFA29BFE)),
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFA29BFE).withValues(alpha: 0.08),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(width: 20),
          // Main mic FAB
          MicButton(
            isRecording: _isRecording,
            isConnected: _connectionState == WsConnectionState.connected,
            onPressed: _toggleRecording,
          ),
          const SizedBox(width: 20),
          // Copy current page
          IconButton(
            onPressed: () {
              final text = _currentPage == 0
                  ? _rawController.text
                  : _formattedOutput;
              if (text.isNotEmpty) {
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 2)),
                );
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 20, color: Colors.white54),
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.06),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.all(12),
            ),
          ),
        ],
      ),
    );
  }
}
