import 'package:flutter/material.dart';

import '../background_sync_file_log.dart';

/// Reads the on-disk background-sync transcript
/// ([BackgroundSyncFileLog]) back into the UI so the headless path is
/// observable in-app, without a `logcat` capture.
///
/// The headless isolate that writes this file is a separate process the
/// foreground telemetry stack never sees, so this panel is the in-app
/// window onto it. It loads on mount and on demand (there is no live
/// stream across the isolate boundary — a background fire happens while
/// this widget may not even be alive — so an explicit refresh is the
/// honest model). The resolved file path is shown so the same transcript
/// can be pulled off-device with `adb pull <path>`.
class BackgroundSyncLogPanel extends StatefulWidget {
  /// Creates the in-app view onto the background-sync transcript.
  const BackgroundSyncLogPanel({super.key});

  @override
  State<BackgroundSyncLogPanel> createState() => _BackgroundSyncLogPanelState();
}

class _BackgroundSyncLogPanelState extends State<BackgroundSyncLogPanel> {
  List<String> _lines = const [];
  String? _path;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final path = await BackgroundSyncFileLog.resolvePath();
    final lines = await BackgroundSyncFileLog.readLatest();
    if (!mounted) return;
    setState(() {
      _path = path;
      _lines = lines;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    await BackgroundSyncFileLog.clear();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _loading
                  ? 'Loading…'
                  : '${_lines.length} entr${_lines.length == 1 ? 'y' : 'ies'} '
                        '(newest first)',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Row(
              children: [
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: _loading ? null : _reload,
                ),
                IconButton(
                  tooltip: 'Clear log',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _loading || _lines.isEmpty ? null : _clear,
                ),
              ],
            ),
          ],
        ),
        if (_path != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SelectableText(
              'adb pull $_path',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ),
        Container(
          width: double.infinity,
          height: 180,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(8),
          ),
          child: _lines.isEmpty
              ? Center(
                  child: Text(
                    // Distinguish "logging is compiled out" from "no fires
                    // yet" — otherwise a release build without the
                    // BG_SYNC_LOG define looks identical to a build whose
                    // background path never ran.
                    BackgroundSyncFileLog.enabled
                        ? 'No background fires recorded yet.\n'
                              'Trigger one, then Refresh.'
                        : 'Transcript logging is disabled in this build.\n'
                              'Rebuild with --dart-define=BG_SYNC_LOG=true '
                              'to enable it.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  itemCount: _lines.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: SelectableText(
                      _lines[i],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Colors.greenAccent,
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
