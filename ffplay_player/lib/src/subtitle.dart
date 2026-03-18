/// Subtitle entry representing a single subtitle segment
class SubtitleEntry {
  /// Start time in milliseconds
  final int startMs;
  
  /// End time in milliseconds
  final int endMs;
  
  /// The subtitle text
  final String text;
  
  /// Word-level timestamps (optional)
  final List<SubtitleWord>? words;

  const SubtitleEntry({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.words,
  });

  /// Get start time as Duration
  Duration get start => Duration(milliseconds: startMs);
  
  /// Get end time as Duration
  Duration get end => Duration(milliseconds: endMs);
  
  /// Get duration of this subtitle
  Duration get duration => end - start;

  factory SubtitleEntry.fromJson(Map<String, dynamic> json) {
    return SubtitleEntry(
      startMs: json['start_ms'] as int? ?? 0,
      endMs: json['end_ms'] as int? ?? 0,
      text: json['text'] as String? ?? '',
      words: json['words'] != null
          ? (json['words'] as List)
              .map((w) => SubtitleWord.fromJson(w as Map<String, dynamic>))
              .toList()
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'start_ms': startMs,
        'end_ms': endMs,
        'text': text,
        if (words != null) 'words': words!.map((w) => w.toJson()).toList(),
      };

  /// Check if this subtitle is active at the given time
  bool isActiveAt(Duration time) {
    final ms = time.inMilliseconds;
    return ms >= startMs && ms <= endMs;
  }

  @override
  String toString() {
    return 'SubtitleEntry(start: ${start.inSeconds}s, end: ${end.inSeconds}s, text: "$text")';
  }
}

/// Word-level subtitle information
class SubtitleWord {
  final String word;
  final int startMs;
  final int endMs;
  final double? confidence;

  const SubtitleWord({
    required this.word,
    required this.startMs,
    required this.endMs,
    this.confidence,
  });

  factory SubtitleWord.fromJson(Map<String, dynamic> json) {
    return SubtitleWord(
      word: json['word'] as String? ?? '',
      startMs: json['start_ms'] as int? ?? 0,
      endMs: json['end_ms'] as int? ?? 0,
      confidence: json['confidence'] as double?,
    );
  }

  Map<String, dynamic> toJson() => {
        'word': word,
        'start_ms': startMs,
        'end_ms': endMs,
        if (confidence != null) 'confidence': confidence,
      };
}

/// Subtitle track containing all subtitle entries for a video
class SubtitleTrack {
  final List<SubtitleEntry> entries;
  final int durationMs;
  final String? language;

  const SubtitleTrack({
    required this.entries,
    required this.durationMs,
    this.language,
  });

  /// Get the subtitle entry active at the given time, if any
  SubtitleEntry? getEntryAt(Duration time) {
    // Binary search for efficiency
    int left = 0;
    int right = entries.length - 1;

    while (left <= right) {
      final mid = (left + right) ~/ 2;
      final entry = entries[mid];

      if (entry.isActiveAt(time)) {
        return entry;
      } else if (time.inMilliseconds < entry.startMs) {
        right = mid - 1;
      } else {
        left = mid + 1;
      }
    }

    return null;
  }

  /// Find the next subtitle entry after the given time
  SubtitleEntry? getNextEntry(Duration time) {
    for (final entry in entries) {
      if (entry.startMs > time.inMilliseconds) {
        return entry;
      }
    }
    return null;
  }

  /// Find the previous subtitle entry before the given time
  SubtitleEntry? getPreviousEntry(Duration time) {
    for (int i = entries.length - 1; i >= 0; i--) {
      if (entries[i].endMs < time.inMilliseconds) {
        return entries[i];
      }
    }
    return null;
  }

  factory SubtitleTrack.fromJson(Map<String, dynamic> json) {
    return SubtitleTrack(
      entries: (json['sentences'] as List?)
              ?.map((e) => SubtitleEntry.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      durationMs: json['duration_ms'] as int? ?? 0,
      language: json['language'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'sentences': entries.map((e) => e.toJson()).toList(),
        'duration_ms': durationMs,
        if (language != null) 'language': language,
      };

  /// Export to SRT format
  String toSrt() {
    final buffer = StringBuffer();
    for (int i = 0; i < entries.length; i++) {
      final entry = entries[i];
      buffer.writeln(i + 1);
      buffer.writeln('${_formatSrtTime(entry.start)} --> ${_formatSrtTime(entry.end)}');
      buffer.writeln(entry.text);
      buffer.writeln();
    }
    return buffer.toString();
  }

  static String _formatSrtTime(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$hours:$minutes:$seconds,$ms';
  }
}
