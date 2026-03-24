/// A single ASR subtitle result captured during playback.
class SubtitleHistoryEntry {
  final String text;       // Full text with punctuation (isFinal result)
  final double positionS;  // Video position when this entry was emitted
  final DateTime capturedAt;

  const SubtitleHistoryEntry({
    required this.text,
    required this.positionS,
    required this.capturedAt,
  });
}

/// Manages the subtitle history for a single player window.
class SubtitleHistory {
  static const int maxEntries = 500;

  final List<SubtitleHistoryEntry> _entries = [];

  List<SubtitleHistoryEntry> get entries => List.unmodifiable(_entries);

  void add(String text, double positionS) {
    if (text.trim().isEmpty) return;
    _entries.add(SubtitleHistoryEntry(
      text: text,
      positionS: positionS,
      capturedAt: DateTime.now(),
    ));
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
  }

  void clear() => _entries.clear();

  /// Export all entries to SRT format string.
  String toSrt() {
    final buf = StringBuffer();
    for (int i = 0; i < _entries.length; i++) {
      final e = _entries[i];
      final start = _srtTime(e.positionS);
      // Estimate end as start + 3s (or next entry's start)
      final endS = i + 1 < _entries.length
          ? _entries[i + 1].positionS
          : e.positionS + 3.0;
      final end = _srtTime(endS);
      buf.writeln(i + 1);
      buf.writeln('$start --> $end');
      buf.writeln(e.text);
      buf.writeln();
    }
    return buf.toString();
  }

  static String _srtTime(double s) {
    final ms = (s * 1000).toInt();
    final h = ms ~/ 3600000;
    final m = (ms % 3600000) ~/ 60000;
    final sec = (ms % 60000) ~/ 1000;
    final millis = ms % 1000;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${sec.toString().padLeft(2, '0')},'
        '${millis.toString().padLeft(3, '0')}';
  }
}
