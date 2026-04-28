import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/host_config.dart';

/// Settings screen — configure the VoiceForge backend host.
///
/// On desktop this is rarely needed (localhost always works).
/// On mobile, the user enters their PC's Tailscale IP here.
class SettingsScreen extends StatefulWidget {
  /// Called after a new host is saved so the caller can reconnect services.
  final VoidCallback? onHostSaved;

  const SettingsScreen({super.key, this.onHostSaved});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController();
  final _formKey  = GlobalKey<FormState>();

  bool   _testing  = false;
  bool   _saving   = false;
  String? _testResult;
  bool   _testOk   = false;

  @override
  void initState() {
    super.initState();
    _hostCtrl.text = HostConfig.host;
    _portCtrl.text = HostConfig.port.toString();
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 8000;
    setState(() { _testing = true; _testResult = null; });

    try {
      final resp = await http
          .get(Uri.parse('http://$host:$port/'))
          .timeout(const Duration(seconds: 5));
      setState(() {
        _testOk     = resp.statusCode == 200;
        _testResult = _testOk
            ? '✅ Connected to VoiceForge at $host:$port'
            : '❌ Server responded with ${resp.statusCode}';
      });
    } on SocketException {
      setState(() { _testOk = false; _testResult = '❌ Could not reach $host:$port — check host & Tailscale'; });
    } catch (e) {
      setState(() { _testOk = false; _testResult = '❌ Error: $e'; });
    } finally {
      setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 8000;
    await HostConfig.save(host, port: port);
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onHostSaved?.call();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved — connecting to $host:$port'),
        backgroundColor: const Color(0xFF00B894),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D1A),
        foregroundColor: Colors.white,
        title: const Text('Backend Settings', style: TextStyle(fontWeight: FontWeight.w600)),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Info card ────────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF6C5CE7).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF6C5CE7).withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, color: Color(0xFF6C5CE7), size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'On mobile, enter your PC\'s Tailscale IP. '
                        'The backend must be running on port ${HostConfig.defaultPort}.',
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 28),

              // ── Host field ───────────────────────────────────────────────
              const Text('Backend Host', style: TextStyle(color: Colors.white54, fontSize: 12, letterSpacing: 0.8)),
              const SizedBox(height: 8),
              TextFormField(
                controller: _hostCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  hintText: 'e.g. 100.64.1.5 or localhost',
                  hintStyle: const TextStyle(color: Colors.white24),
                  filled: true,
                  fillColor: const Color(0xFF1A1A2E),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFF6C5CE7)),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Host is required';
                  return null;
                },
              ),

              const SizedBox(height: 16),

              // ── Port field ───────────────────────────────────────────────
              const Text('Port', style: TextStyle(color: Colors.white54, fontSize: 12, letterSpacing: 0.8)),
              const SizedBox(height: 8),
              TextFormField(
                controller: _portCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: '8000',
                  hintStyle: const TextStyle(color: Colors.white24),
                  filled: true,
                  fillColor: const Color(0xFF1A1A2E),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFF6C5CE7)),
                  ),
                ),
                validator: (v) {
                  final p = int.tryParse(v ?? '');
                  if (p == null || p < 1 || p > 65535) return 'Enter a valid port (1–65535)';
                  return null;
                },
              ),

              const SizedBox(height: 24),

              // ── Test result ──────────────────────────────────────────────
              if (_testResult != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: _testOk
                        ? const Color(0xFF00B894).withValues(alpha: 0.12)
                        : Colors.red.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _testOk
                          ? const Color(0xFF00B894).withValues(alpha: 0.4)
                          : Colors.red.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(_testResult!, style: TextStyle(
                    color: _testOk ? const Color(0xFF00B894) : Colors.red.shade300,
                    fontSize: 13,
                  )),
                ),

              // ── Buttons ──────────────────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _testing ? null : _testConnection,
                      icon: _testing
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.wifi_find_rounded, size: 16),
                      label: Text(_testing ? 'Testing...' : 'Test Connection'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF6C5CE7),
                        side: const BorderSide(color: Color(0xFF6C5CE7)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.save_rounded, size: 16),
                      label: Text(_saving ? 'Saving...' : 'Save & Connect'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF6C5CE7),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // ── Quick presets ────────────────────────────────────────────
              const Text('Quick Presets', style: TextStyle(color: Colors.white54, fontSize: 12, letterSpacing: 0.8)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  _PresetChip(label: 'localhost', onTap: () => setState(() => _hostCtrl.text = 'localhost')),
                  _PresetChip(label: '100.64.x.x', onTap: () => setState(() => _hostCtrl.text = '100.64.')),
                ],
              ),

              const SizedBox(height: 28),

              // ── Sessions folder ─────────────────────────────────────────
              const Text('Sessions', style: TextStyle(color: Colors.white54, fontSize: 12, letterSpacing: 0.8)),
              const SizedBox(height: 8),
              _OpenSessionsFolderButton(
                host: _hostCtrl.text.trim(),
                port: int.tryParse(_portCtrl.text.trim()) ?? 8000,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PresetChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12)),
      ),
    );
  }
}


/// Calls /sessions/open-folder on the backend which opens Explorer on the PC.
/// Works from both desktop and mobile (the PC does the folder opening).
class _OpenSessionsFolderButton extends StatefulWidget {
  final String host;
  final int port;
  const _OpenSessionsFolderButton({required this.host, required this.port});

  @override
  State<_OpenSessionsFolderButton> createState() => _OpenSessionsFolderButtonState();
}

class _OpenSessionsFolderButtonState extends State<_OpenSessionsFolderButton> {
  bool _loading = false;
  String? _result;
  bool _ok = false;

  Future<void> _open() async {
    setState(() { _loading = true; _result = null; });
    try {
      final resp = await http
          .get(Uri.parse('http://${widget.host}:${widget.port}/sessions/open-folder'))
          .timeout(const Duration(seconds: 5));
      final ok = resp.statusCode == 200;
      setState(() {
        _ok = ok;
        _result = ok ? '✅ Opened sessions folder on PC' : '❌ Server error ${resp.statusCode}';
      });
    } catch (e) {
      setState(() { _ok = false; _result = '❌ Could not reach backend: $e'; });
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: _loading ? null : _open,
          icon: _loading
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.folder_open_rounded, size: 16),
          label: Text(_loading ? 'Opening...' : 'Open Sessions Folder'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF00B894),
            side: const BorderSide(color: Color(0xFF00B894)),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        if (_result != null) ...[
          const SizedBox(height: 8),
          Text(_result!, style: TextStyle(
            fontSize: 12,
            color: _ok ? const Color(0xFF00B894) : Colors.red.shade300,
          )),
        ],
      ],
    );
  }
}
