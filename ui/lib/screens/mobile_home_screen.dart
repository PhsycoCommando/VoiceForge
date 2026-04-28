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

class _MobileHomeScreenState extends State<MobileHomeScreen>
    with WidgetsBindingObserver {
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
  final  TextEditingController _fmtController = TextEditingController();
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

  // Formatted sync
  bool _suppressFmtUpdate = false;
  Timer? _fmtUpdateDebounce;

  // Set to true when THIS client sends the start command.
  // Only the initiating device adds the visual separator to avoid doubles.
  bool _isInitiatingRecording = false;

  // True when this client started the current session.
  bool _sessionIsLocal = true;

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
    _fmtController.addListener(_onFmtTextChanged);
    _initServices();
    WidgetsBinding.instance.addObserver(this);

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
    if (!_sessionIsLocal) return;
    _textUpdateDebounce?.cancel();
    _textUpdateDebounce = Timer(const Duration(milliseconds: 500), () {
      _ws.sendTextUpdate(_rawController.text);
    });
  }

  void _onFmtTextChanged() {
    if (_suppressFmtUpdate) return;
    _fmtUpdateDebounce?.cancel();
    _fmtUpdateDebounce = Timer(const Duration(milliseconds: 600), () {
      _ws.sendFormattedUpdate(_currentMode, _fmtController.text);
    });
  }

  // Reconnect WebSocket when app returns to foreground
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_connectionState != WsConnectionState.connected) {
        // Force fresh reconnect — the old socket is likely dead
        _ws.disconnect();
        Future.delayed(const Duration(milliseconds: 300), _ws.connect);
      }
    }
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
        // Restore formatted panel from backend handshake
        if (_ws.formattedOutput.isNotEmpty && _fmtController.text.isEmpty) {
          setState(() {
            _suppressFmtUpdate = true;
            _fmtController.text = _ws.formattedOutput;
            _suppressFmtUpdate = false;
            if (_ws.formattedMode.isNotEmpty) _currentMode = _ws.formattedMode;
          });
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
    WidgetsBinding.instance.removeObserver(this);
    _textUpdateDebounce?.cancel();
    _fmtUpdateDebounce?.cancel();
    _eventSub?.cancel();
    _connSub?.cancel();
    _mic.dispose();
    _ws.dispose();
    _api.dispose();
    _rawController.dispose();
    _fmtController.dispose();
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
          // Only the initiating device writes the final transcription to the raw
          // panel. Non-initiating device waits for the authoritative text_update
          // from the initiating device, which includes the session separator.
          if (_sessionIsLocal) {
            final before = _rawController.text.substring(0, _sessionStartOffset);
            _rawController.text = before + event.raw;
            _rawController.selection = TextSelection.collapsed(offset: _rawController.text.length);
            if (_shouldAutoScrollRaw) _scrollToBottom(_rawScroll);
            // Explicitly broadcast the complete text (with separator) to other
            // clients. The debounce listener is blocked while _isTranscribing
            // was true, so it never fires — we send directly here instead.
            _ws.sendTextUpdate(_rawController.text);
          }

        case 'paragraph_break':
          break;

        case 'status':
          if (event.status == 'started') {
            _isRecording = true;
            _sessionIsLocal = _isInitiatingRecording;
            if (_isInitiatingRecording && _rawController.text.isNotEmpty) {
              _rawController.text = '${_rawController.text}\n\n─────────────────────\n\n';
              _rawController.selection = TextSelection.collapsed(offset: _rawController.text.length);
              if (_shouldAutoScrollRaw) _scrollToBottom(_rawScroll);
            }
            _isInitiatingRecording = false;
            _sessionStartOffset = _rawController.text.length;
          }
          if (event.status == 'stopped') {
            _isRecording    = false;
            _isTranscribing = false;
            if (!_sessionIsLocal) {
              Future.delayed(const Duration(seconds: 2), () {
                if (mounted) setState(() => _sessionIsLocal = true);
              });
            }
          }
          if (event.status == 'cleared') {
            _textUpdateDebounce?.cancel();
            _fmtUpdateDebounce?.cancel();
            _suppressTextUpdate = true;
            _rawController.clear();
            _suppressTextUpdate = false;
            _suppressFmtUpdate = true;
            _fmtController.clear();
            _suppressFmtUpdate = false;
            _formattedOutput    = '';
            _sessionStartOffset = 0;
            _sessionIsLocal = true;
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
          _textUpdateDebounce?.cancel();
          _suppressTextUpdate = true;
          _rawController.text = event.raw;
          _rawController.selection = TextSelection.collapsed(offset: _rawController.text.length);
          _suppressTextUpdate = false;
          _sessionIsLocal = true;
          if (_shouldAutoScrollRaw) _scrollToBottom(_rawScroll);

        case 'formatted':
          // Another device ran a transform OR edited the formatted panel — mirror it.
          _suppressFmtUpdate = true;
          _fmtController.text = event.formatted;
          _formattedOutput = event.formatted;
          _suppressFmtUpdate = false;
          if (event.mode.isNotEmpty) _currentMode = event.mode;
          // Auto-navigate to formatted page
          if (_fmtController.text.isNotEmpty && _currentPage == 0) {
            _pageCtrl.animateToPage(1,
                duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
          }
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
      if (_currentMode == 'raw') {
        _suppressFmtUpdate = true;
        _fmtController.text = rawText;
        _formattedOutput = rawText;
        _suppressFmtUpdate = false;
      } else {
        final result = await _api.transform(rawText, _currentMode);
        _suppressFmtUpdate = true;
        _fmtController.text = result['formatted'] as String? ?? rawText;
        _formattedOutput = _fmtController.text;
        _suppressFmtUpdate = false;
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

  /// Pull-to-refresh handler: reconnect WS if down, else just ping status.
  Future<void> _onRefresh() async {
    if (_connectionState != WsConnectionState.connected) {
      _ws.disconnect();
      await Future.delayed(const Duration(milliseconds: 300));
      _ws.connect();
      await Future.delayed(const Duration(seconds: 2));
    } else {
      await _fetchStatus();
    }
    if (!mounted) return;
    final connected = _connectionState == WsConnectionState.connected;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(connected ? '✓ Connected — ready' : '⚡ Reconnecting…'),
      duration: const Duration(seconds: 2),
      backgroundColor: connected ? const Color(0xFF00B894) : const Color(0xFF6C5CE7),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  // ── AppStatus ──────────────────────────────────────────────────────────────

  AppStatus get _appStatus {
    if (_connectionState == WsConnectionState.connecting) return AppStatus.reconnecting;
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
              _textUpdateDebounce?.cancel();
              setState(() {
              _suppressTextUpdate = true;
              _rawController.text = '';
              _suppressTextUpdate = false;
              _suppressFmtUpdate = true;
              _fmtController.clear();
              _suppressFmtUpdate = false;
              _formattedOutput    = '';
              _sessionStartOffset = 0;
              _sessionIsLocal = true;
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
    const refreshColor     = Color(0xFF6C5CE7);
    const refreshBgColor   = Color(0xFF1A1A2E);
    return PageView(
      controller: _pageCtrl,
      onPageChanged: (i) => setState(() => _currentPage = i),
      children: [
        RefreshIndicator(
          onRefresh: _onRefresh,
          color: refreshColor,
          backgroundColor: refreshBgColor,
          displacement: 60,
          child: _buildRawPage(),
        ),
        RefreshIndicator(
          onRefresh: _onRefresh,
          color: refreshColor,
          backgroundColor: refreshBgColor,
          displacement: 60,
          child: _buildFormattedPage(),
        ),
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
            // Content — always a TextField so overscroll triggers RefreshIndicator.
            Expanded(
              child: Scrollbar(
                controller: _rawScroll,
                child: TextField(
                  controller: _rawController,
                  scrollController: _rawScroll,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  scrollPhysics: const AlwaysScrollableScrollPhysics(),
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
            // Content — empty state scrollable so swipe-down refresh still works.
            Expanded(
              child: _fmtController.text.isEmpty
                  ? LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: SizedBox(
                          height: constraints.maxHeight,
                          child: const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.auto_fix_high_rounded, size: 40, color: Colors.white12),
                                SizedBox(height: 12),
                                Text('Select a mode and tap ↺ to process',
                                    style: TextStyle(color: Colors.white24, fontSize: 13)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                  : Scrollbar(
                      controller: _fmtScroll,
                      child: TextField(
                        controller: _fmtController,
                        scrollController: _fmtScroll,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        scrollPhysics: const AlwaysScrollableScrollPhysics(),
                        style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.6),
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.all(16),
                          border: InputBorder.none,
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
