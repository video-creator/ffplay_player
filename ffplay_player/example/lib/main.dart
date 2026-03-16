import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';

import 'package:ffplay_player/ffplay_player.dart';
import 'package:file_selector/file_selector.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FfplayPlayerPlugin.initialize();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  FfplayPlayerController? _controller;
  String _status = 'Ready - Select a file to start';
  String? _currentUrl;
  
  // For seek slider - only seek on drag end
  bool _isDragging = false;
  double _dragPosition = 0;
  double? _seekingPosition;
  
  @override
  void initState() {
    super.initState();
    _createPlayer();
  }

  void _createPlayer() {
    _controller?.dispose();
    
    try {
      _controller = FfplayPlayerController();
      _controller!.onStateChanged = _onStateChanged;
      _controller!.onStatsUpdated = _onStatsUpdated;
      _controller!.onError = _onError;
      setState(() {});
    } catch (e) {
      setState(() {
        _status = 'Error creating player: $e';
      });
    }
  }

  void _onStateChanged(FfplayPlayerState state) {
    setState(() {
      _status = 'State: ${state.name}';
    });
  }

  void _onStatsUpdated(FfplayPlayerStats stats) {
    if (_seekingPosition != null) {
      final diff = (stats.position - _seekingPosition!).abs();
      if (diff < 0.5) {
        _seekingPosition = null;
      }
    }
    setState(() {});
  }

  void _onError(String error) {
    setState(() {
      _status = 'Error: $error';
    });
  }

  Future<void> _pickFile() async {
    try {
      const XTypeGroup typeGroup = XTypeGroup(
        label: 'Media files',
        extensions: <String>[
          'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v', 
          'mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a'
        ],
      );
      
      final XFile? file = await openFile(acceptedTypeGroups: [typeGroup]);
      
      if (file != null) {
        setState(() {
          _currentUrl = file.path;
          _status = file.name;
        });
        if (_controller != null) {
          await _controller!.setUrl(file.path);
        }
      }
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
    }
  }

  void _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null && data!.text!.isNotEmpty) {
        setState(() {
          _currentUrl = data.text;
          _status = 'URL loaded';
        });
        if (_controller != null) {
          await _controller!.setUrl(data.text!);
        }
      }
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
    }
  }

  Future<void> _playSampleVideo(String url, String name) async {
    setState(() {
      _currentUrl = url;
      _status = name;
    });
    if (_controller != null) {
      await _controller!.setUrl(url);
    }
  }

  Future<void> _play() async {
    if (_controller == null) {
      _createPlayer();
      await Future.delayed(const Duration(milliseconds: 100));
    }
    
    if (_currentUrl == null || _currentUrl!.isEmpty) {
      setState(() {
        _status = 'Please select a file';
      });
      return;
    }
    
    if (!_currentUrl!.startsWith('http://') && !_currentUrl!.startsWith('https://') && 
        !_currentUrl!.startsWith('rtmp://') && !_currentUrl!.startsWith('rtsp://')) {
      final file = File(_currentUrl!);
      if (!await file.exists()) {
        setState(() {
          _status = 'File not found';
        });
        return;
      }
    }
    
    await _controller!.setUrl(_currentUrl!);
    final success = await _controller!.play();
    setState(() {
      _status = success ? 'Playing' : 'Failed to start';
    });
  }

  void _stop() {
    _controller?.stop();
    setState(() {
      _status = 'Stopped';
    });
  }

  void _pause() {
    _controller?.pause();
    setState(() {
      _status = 'Paused';
    });
  }

  void _resume() {
    _controller?.resume();
    setState(() {
      _status = 'Playing';
    });
  }

  void _seek(double seconds) {
    _controller?.seek(seconds);
  }

  void _setVolume(int volume) {
    _controller?.setVolume(volume);
    setState(() {});
  }

  void _toggleMute() {
    if (_controller != null) {
      _controller!.setMute(!_controller!.muted);
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: Text(_status, style: const TextStyle(fontSize: 14)),
          actions: [
            // File menu
            PopupMenuButton<String>(
              icon: const Icon(Icons.folder_open),
              tooltip: 'Open Media',
              onSelected: (value) {
                if (value == 'file') {
                  _pickFile();
                } else if (value == 'clipboard') {
                  _pasteFromClipboard();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'file', child: ListTile(leading: Icon(Icons.folder), title: Text('Open File...'))),
                const PopupMenuItem(value: 'clipboard', child: ListTile(leading: Icon(Icons.content_paste), title: Text('Paste URL'))),
              ],
            ),
            // Sample videos menu
            PopupMenuButton<String>(
              icon: const Icon(Icons.video_library),
              tooltip: 'Sample Videos',
              onSelected: (value) {
                switch (value) {
                  case 'bigbuck':
                    _playSampleVideo('https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4', 'Big Buck Bunny');
                    break;
                  case 'sintel':
                    _playSampleVideo('https://test-videos.co.uk/vids/sintel/mp4/h264/360/Sintel_360_10s_1MB.mp4', 'Sintel');
                    break;
                  case 'jellyfish':
                    _playSampleVideo('https://test-videos.co.uk/vids/jellyfish/mp4/h264/360/Jellyfish_360_10s_1MB.mp4', 'Jellyfish');
                    break;
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'bigbuck', child: Text('Big Buck Bunny (10s)')),
                const PopupMenuItem(value: 'sintel', child: Text('Sintel (10s)')),
                const PopupMenuItem(value: 'jellyfish', child: Text('Jellyfish (10s)')),
              ],
            ),
            // Info
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: 'About',
              onPressed: () {
                showAboutDialog(
                  context: context,
                  applicationName: 'FFplay Player',
                  applicationLegalese: 'A Flutter video player using ffplay_jni.\n\nSupports MP4, MKV, AVI, MOV, WebM and more.',
                );
              },
            ),
          ],
        ),
        body: Column(
          children: [
            // Video player area - expanded to fill most of the screen
            Expanded(
              child: Container(
                color: Colors.black,
                child: _controller != null
                    ? FfplayPlayer(
                        controller: _controller!,
                        url: _currentUrl,
                        backgroundColor: Colors.black,
                      )
                    : const Center(
                        child: Text('No player', style: TextStyle(color: Colors.white54)),
                      ),
              ),
            ),
            
            // Bottom control bar
            Container(
              color: Colors.grey[900],
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Progress slider
                  if (_controller != null && _controller!.duration > 0) ...[
                    Row(
                      children: [
                        Text(
                          formatDuration(_isDragging ? _dragPosition : (_seekingPosition ?? _controller!.position)),
                          style: const TextStyle(fontSize: 12, color: Colors.white70),
                        ),
                        Expanded(
                          child: Slider(
                            value: _isDragging 
                                ? _dragPosition.clamp(0.0, _controller!.duration) 
                                : (_seekingPosition ?? _controller!.position).clamp(0.0, _controller!.duration),
                            max: _controller!.duration > 0 ? _controller!.duration : 1,
                            onChangeStart: (value) {
                              _isDragging = true;
                              _dragPosition = value;
                            },
                            onChanged: (value) {
                              setState(() {
                                _dragPosition = value;
                              });
                            },
                            onChangeEnd: (value) {
                              setState(() {
                                _isDragging = false;
                                _seekingPosition = value;
                              });
                              _seek(value);
                            },
                          ),
                        ),
                        Text(
                          formatDuration(_controller!.duration),
                          style: const TextStyle(fontSize: 12, color: Colors.white70),
                        ),
                      ],
                    ),
                  ],
                  
                  // Control buttons row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Seek backward buttons
                      IconButton(
                        icon: const Icon(Icons.replay_30),
                        iconSize: 28,
                        tooltip: '-30s',
                        onPressed: () => _controller?.seekRelative(-30),
                      ),
                      IconButton(
                        icon: const Icon(Icons.replay_10),
                        iconSize: 28,
                        tooltip: '-10s',
                        onPressed: () => _controller?.seekRelative(-10),
                      ),
                      
                      // Play/Pause/Resume
                      IconButton(
                        icon: const Icon(Icons.stop),
                        iconSize: 32,
                        color: Colors.red,
                        tooltip: 'Stop',
                        onPressed: _stop,
                      ),
                      
                      if (_controller?.state == FfplayPlayerState.playing)
                        IconButton(
                          icon: const Icon(Icons.pause),
                          iconSize: 40,
                          color: Colors.white,
                          tooltip: 'Pause',
                          onPressed: _pause,
                        )
                      else if (_controller?.state == FfplayPlayerState.paused)
                        IconButton(
                          icon: const Icon(Icons.play_arrow),
                          iconSize: 40,
                          color: Colors.green,
                          tooltip: 'Resume',
                          onPressed: _resume,
                        )
                      else
                        IconButton(
                          icon: const Icon(Icons.play_arrow),
                          iconSize: 40,
                          color: Colors.green,
                          tooltip: 'Play',
                          onPressed: _play,
                        ),
                      
                      // Seek forward buttons
                      IconButton(
                        icon: const Icon(Icons.forward_10),
                        iconSize: 28,
                        tooltip: '+10s',
                        onPressed: () => _controller?.seekRelative(10),
                      ),
                      IconButton(
                        icon: const Icon(Icons.forward_30),
                        iconSize: 28,
                        tooltip: '+30s',
                        onPressed: () => _controller?.seekRelative(30),
                      ),
                      
                      const SizedBox(width: 24),
                      
                      // Volume control
                      IconButton(
                        icon: Icon(_controller?.muted == true ? Icons.volume_off : Icons.volume_up),
                        tooltip: _controller?.muted == true ? 'Unmute' : 'Mute',
                        onPressed: _toggleMute,
                      ),
                      SizedBox(
                        width: 100,
                        child: Slider(
                          value: (_controller?.volume ?? 100).toDouble(),
                          min: 0,
                          max: 100,
                          onChanged: (value) => _setVolume(value.toInt()),
                        ),
                      ),
                      Text(
                        '${_controller?.volume ?? 100}%',
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
