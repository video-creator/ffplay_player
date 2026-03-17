import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

/// Player state enumeration
enum FfplayPlayerState {
  idle,
  playing,
  paused,
  stopped,
  error,
}

/// Player statistics
class FfplayPlayerStats {
  final double position;
  final double duration;
  final FfplayPlayerState state;
  final bool seeking;

  FfplayPlayerStats({
    required this.position,
    required this.duration,
    required this.state,
    this.seeking = false,
  });

  double get progress {
    if (duration <= 0) return 0;
    final p = position / duration;
    return p.clamp(0.0, 1.0);
  }
}

/// Callback types
typedef PlayerStateCallback = void Function(FfplayPlayerState state);
typedef PlayerStatsCallback = void Function(FfplayPlayerStats stats);
typedef PlayerErrorCallback = void Function(String error);

/// Controller for the FfplayPlayer widget
class FfplayPlayerController {
  int? _viewId;
  MethodChannel? _channel;
  
  FfplayPlayerState _state = FfplayPlayerState.idle;
  double _position = 0;
  double _duration = 0;
  int _volume = 100;
  bool _muted = false;
  int _loop = 1;  // 1 = no loop (default), 0 = infinite
  double _speed = 1.0;  // 1.0 = normal speed
  String? _url;
  
  // Callbacks
  PlayerStateCallback? onStateChanged;
  PlayerStatsCallback? onStatsUpdated;
  PlayerErrorCallback? onError;
  
  FfplayPlayerController();
  
  /// Called when the platform view is created
  void _attachToView(int viewId, BinaryMessenger messenger) {
    _viewId = viewId;
    _channel = MethodChannel('ffplay_player_view_$viewId');
    _channel!.setMethodCallHandler(_handleMethodCall);
  }
  
  int? get viewId => _viewId;
  bool get isAttached => _viewId != null && _channel != null;
  FfplayPlayerState get state => _state;
  double get position => _position;
  double get duration => _duration;
  int get volume => _volume;
  bool get muted => _muted;
  String? get url => _url;
  
  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onStatsUpdate':
        final args = call.arguments as Map<dynamic, dynamic>;
        _position = (args['position'] as num?)?.toDouble() ?? 0;
        _duration = (args['duration'] as num?)?.toDouble() ?? 0;
        final stateStr = args['state'] as String? ?? 'idle';
        _state = _parseState(stateStr);
        final seeking = (args['seeking'] as bool?) ?? false;
        onStatsUpdated?.call(FfplayPlayerStats(
          position: _position,
          duration: _duration,
          state: _state,
          seeking: seeking,
        ));
        onStateChanged?.call(_state);
        break;
      case 'onPlaybackComplete':
        _state = FfplayPlayerState.stopped;
        onStateChanged?.call(_state);
        break;
    }
  }
  
  FfplayPlayerState _parseState(String state) {
    switch (state) {
      case 'playing':
        return FfplayPlayerState.playing;
      case 'paused':
        return FfplayPlayerState.paused;
      case 'stopped':
        return FfplayPlayerState.stopped;
      case 'error':
        return FfplayPlayerState.error;
      default:
        return FfplayPlayerState.idle;
    }
  }
  
  /// Set the media URL
  Future<void> setUrl(String url) async {
    _url = url;
    if (_channel != null) {
      await _channel!.invokeMethod('setUrl', {'url': url});
    }
  }
  
  /// Start playback
  Future<bool> play() async {
    if (_channel == null) return false;
    
    final result = await _channel!.invokeMethod('play');
    if (result == true) {
      _state = FfplayPlayerState.playing;
      onStateChanged?.call(_state);
    }
    return result == true;
  }
  
  /// Pause playback
  Future<void> pause() async {
    if (_channel == null) return;
    await _channel!.invokeMethod('pause');
    _state = FfplayPlayerState.paused;
    onStateChanged?.call(_state);
  }
  
  /// Resume playback
  Future<void> resume() async {
    if (_channel == null) return;
    await _channel!.invokeMethod('resume');
    _state = FfplayPlayerState.playing;
    onStateChanged?.call(_state);
  }
  
  /// Stop playback
  Future<void> stop() async {
    if (_channel == null) return;
    await _channel!.invokeMethod('stop');
    _state = FfplayPlayerState.stopped;
    onStateChanged?.call(_state);
  }
  
  /// Seek to position (seconds)
  Future<void> seek(double position) async {
    if (_channel == null) return;
    await _channel!.invokeMethod('seek', {'position': position});
  }
  
  /// Seek relative (seconds)
  Future<void> seekRelative(double delta) async {
    if (_channel == null) return;
    await _channel!.invokeMethod('seekRelative', {'delta': delta});
  }
  
  /// Check if seeking is in progress
  Future<bool> isSeeking() async {
    if (_channel == null) return false;
    final result = await _channel!.invokeMethod('isSeeking');
    return result == true;
  }
  
  /// Set volume (0-100)
  Future<void> setVolume(int volume) async {
    _volume = volume.clamp(0, 100);
    if (_channel != null) {
      await _channel!.invokeMethod('setVolume', {'volume': _volume});
    }
  }
  
  /// Set mute
  Future<void> setMute(bool muted) async {
    _muted = muted;
    if (_channel != null) {
      await _channel!.invokeMethod('setMute', {'muted': muted});
    }
  }
  
  /// Set loop count (0 = infinite, 1 = no loop)
  Future<void> setLoop(int loop) async {
    _loop = loop;
    if (_channel != null) {
      await _channel!.invokeMethod('setLoop', {'loop': loop});
    }
  }
  
  /// Get loop count
  int get loop => _loop;
  
  /// Set playback speed (0.25 to 4.0, 1.0 = normal)
  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(0.25, 4.0);
    if (_channel != null) {
      await _channel!.invokeMethod('setSpeed', {'speed': _speed});
    }
  }
  
  /// Get playback speed
  double get speed => _speed;
  
  /// Get current position
  Future<double> getPosition() async {
    if (_channel == null) return 0;
    final result = await _channel!.invokeMethod('getPosition');
    return (result as num?)?.toDouble() ?? 0;
  }
  
  /// Get duration
  Future<double> getDuration() async {
    if (_channel == null) return 0;
    final result = await _channel!.invokeMethod('getDuration');
    return (result as num?)?.toDouble() ?? 0;
  }
  
  /// Dispose the controller
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    _viewId = null;
  }
}

/// A widget that displays a video player using the native platform view.
class FfplayPlayer extends StatefulWidget {
  final FfplayPlayerController controller;
  final String? url;
  final bool autoPlay;
  final Color backgroundColor;
  
  const FfplayPlayer({
    super.key,
    required this.controller,
    this.url,
    this.autoPlay = false,
    this.backgroundColor = Colors.black,
  });
  
  @override
  State<FfplayPlayer> createState() => _FfplayPlayerState();
}

class _FfplayPlayerState extends State<FfplayPlayer> {
  bool _initialized = false;
  
  @override
  void initState() {
    super.initState();
  }
  
  @override
  void didUpdateWidget(FfplayPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url && widget.url != null && _initialized) {
      widget.controller.setUrl(widget.url!).then((_) {
        if (widget.autoPlay) {
          widget.controller.play();
        }
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: 'ffplay_player_view',
        creationParams: <String, dynamic>{
          'url': widget.url,
          'autoPlay': widget.autoPlay,
        },
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    }
    
    return Center(
      child: Text(
        'FfplayPlayer is not supported on ${defaultTargetPlatform.name}',
        style: const TextStyle(color: Colors.red),
      ),
    );
  }
  
  void _onPlatformViewCreated(int viewId) {
    widget.controller._attachToView(viewId, WidgetsBinding.instance.defaultBinaryMessenger);
    
    setState(() {
      _initialized = true;
    });
    
    // Set initial URL if provided
    if (widget.url != null) {
      widget.controller.setUrl(widget.url!).then((_) {
        if (widget.autoPlay) {
          widget.controller.play();
        }
      });
    }
  }
}

/// Main plugin class for initialization
class FfplayPlayerPlugin {
  static const MethodChannel _channel = MethodChannel('ffplay_player');
  
  static bool _initialized = false;
  
  /// Initialize the plugin
  static Future<void> initialize() async {
    if (_initialized) return;
    
    await _channel.invokeMethod('initialize');
    _initialized = true;
  }
  
  /// Check if initialized
  static bool get isInitialized => _initialized;
}

/// Helper function to format duration
String formatDuration(double seconds) {
  if (seconds.isNaN || seconds.isInfinite || seconds < 0) return '00:00';
  
  final duration = Duration(seconds: seconds.toInt());
  String twoDigits(int n) => n.toString().padLeft(2, '0');
  
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final secs = duration.inSeconds.remainder(60);
  
  if (hours > 0) {
    return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(secs)}';
  }
  return '${twoDigits(minutes)}:${twoDigits(secs)}';
}
