import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

/// Compact mic selector dropdown for the top bar.
///
/// Fetches available mics from the backend, persists the selection
/// via SharedPreferences, and sends the choice to the backend.
class MicSelector extends StatefulWidget {
  final ApiService api;
  final VoidCallback? onChanged;

  const MicSelector({super.key, required this.api, this.onChanged});

  @override
  State<MicSelector> createState() => _MicSelectorState();
}

class _MicSelectorState extends State<MicSelector> {
  static const _prefKey = 'selected_mic_id';

  List<Map<String, dynamic>> _mics = [];
  int? _selectedId;
  bool _loading = true;
  String? _selectedName;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getInt(_prefKey);

      final mics = await widget.api.getMicrophones();
      if (!mounted) return;

      setState(() {
        _mics = mics;
        _loading = false;
      });

      // Restore saved selection if still valid
      if (savedId != null && mics.any((m) => m['id'] == savedId)) {
        await _selectMic(savedId, persist: false);
      } else {
        // Fetch whatever the backend auto-selected
        _fetchCurrent();
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _fetchCurrent() async {
    try {
      final info = await widget.api.getCurrentMicrophone();
      if (!mounted) return;
      setState(() {
        _selectedName = info['name'] as String?;
      });
    } catch (_) {}
  }

  Future<void> _selectMic(int id, {bool persist = true}) async {
    try {
      final result = await widget.api.selectMicrophone(id);
      if (!mounted) return;
      setState(() {
        _selectedId = id;
        _selectedName = result['name'] as String?;
      });

      if (persist) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_prefKey, id);
      }

      widget.onChanged?.call();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Current mic indicator
        Icon(Icons.mic_rounded,
            size: 16,
            color: _selectedName != null
                ? const Color(0xFF00B894)
                : Colors.white38),
        const SizedBox(width: 6),

        // Dropdown
        DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: _selectedId,
            hint: Text(
              _selectedName ?? 'Auto',
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
              ),
            ),
            dropdownColor: const Color(0xFF1A1A2E),
            borderRadius: BorderRadius.circular(12),
            icon: const Icon(Icons.expand_more_rounded,
                size: 18, color: Colors.white38),
            style: const TextStyle(color: Colors.white, fontSize: 12),
            items: _mics.map((m) {
              final id = m['id'] as int;
              final name = m['name'] as String;
              return DropdownMenuItem<int>(
                value: id,
                child: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: id == _selectedId
                        ? const Color(0xFF00B894)
                        : Colors.white70,
                    fontSize: 12,
                  ),
                ),
              );
            }).toList(),
            onChanged: (id) {
              if (id != null) _selectMic(id);
            },
          ),
        ),
      ],
    );
  }
}
