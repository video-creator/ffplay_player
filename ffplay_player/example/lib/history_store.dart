import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Single history record for a played media file / URL.
class HistoryItem {
  final String url;
  final String displayName;
  final DateTime playedAt;
  final double lastPosition; // seconds
  final double duration;     // seconds, 0 if unknown

  const HistoryItem({
    required this.url,
    required this.displayName,
    required this.playedAt,
    required this.lastPosition,
    required this.duration,
  });

  String get progressText {
    if (duration <= 0) return '';
    final pct = (lastPosition / duration * 100).clamp(0, 100).toStringAsFixed(0);
    return '$pct%';
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'displayName': displayName,
        'playedAt': playedAt.millisecondsSinceEpoch,
        'lastPosition': lastPosition,
        'duration': duration,
      };

  factory HistoryItem.fromJson(Map<String, dynamic> j) => HistoryItem(
        url: j['url'] as String? ?? '',
        displayName: j['displayName'] as String? ?? '',
        playedAt: DateTime.fromMillisecondsSinceEpoch(j['playedAt'] as int? ?? 0),
        lastPosition: (j['lastPosition'] as num?)?.toDouble() ?? 0,
        duration: (j['duration'] as num?)?.toDouble() ?? 0,
      );

  HistoryItem copyWith({double? lastPosition, double? duration, DateTime? playedAt}) =>
      HistoryItem(
        url: url,
        displayName: displayName,
        playedAt: playedAt ?? this.playedAt,
        lastPosition: lastPosition ?? this.lastPosition,
        duration: duration ?? this.duration,
      );
}

/// Singleton that manages play history persistence via SharedPreferences.
class HistoryStore {
  HistoryStore._();
  static final HistoryStore instance = HistoryStore._();

  static const _kKey = 'player_history';
  static const _kMaxItems = 50;

  final List<HistoryItem> _items = [];

  List<HistoryItem> get items => List.unmodifiable(_items);

  /// Load from storage — call once at startup.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List<dynamic>;
        _items.clear();
        _items.addAll(list
            .cast<Map<String, dynamic>>()
            .map(HistoryItem.fromJson));
        // newest first
        _items.sort((a, b) => b.playedAt.compareTo(a.playedAt));
      }
    } catch (_) {}
  }

  /// Record / update a play event. Call when playback starts.
  Future<void> recordPlay({
    required String url,
    required String displayName,
    double lastPosition = 0,
    double duration = 0,
  }) async {
    final now = DateTime.now();
    final idx = _items.indexWhere((e) => e.url == url);
    if (idx >= 0) {
      _items[idx] = _items[idx].copyWith(
        lastPosition: lastPosition,
        duration: duration,
        playedAt: now,
      );
      // Move to top
      final item = _items.removeAt(idx);
      _items.insert(0, item);
    } else {
      _items.insert(0, HistoryItem(
        url: url,
        displayName: displayName,
        playedAt: now,
        lastPosition: lastPosition,
        duration: duration,
      ));
    }
    // Trim to max
    while (_items.length > _kMaxItems) {
      _items.removeLast();
    }
    await _persist();
  }

  /// Update position for an already-recorded URL (called every 30s during playback).
  Future<void> updatePosition(String url, double position, double duration) async {
    final idx = _items.indexWhere((e) => e.url == url);
    if (idx < 0) return;
    _items[idx] = _items[idx].copyWith(
      lastPosition: position,
      duration: duration,
    );
    await _persist();
  }

  /// Remove a single item.
  Future<void> remove(String url) async {
    _items.removeWhere((e) => e.url == url);
    await _persist();
  }

  /// Clear all history.
  Future<void> clear() async {
    _items.clear();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(_items.map((e) => e.toJson()).toList());
      await prefs.setString(_kKey, json);
    } catch (_) {}
  }
}
