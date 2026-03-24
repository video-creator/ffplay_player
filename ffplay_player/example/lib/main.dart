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

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const _HomePage(),
    );
  }
}

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  FfplayPlayerController? _controller;
  String _status = 'Ready - Select a file to start';
  String? _currentUrl;
  
  // For seek slider
  bool _isDragging = false;
  double _dragPosition = 0;
  double? _seekingPosition;
  
  // Loop and speed settings
  int _loop = 1;
  double _speed = 1.0;

  // ASR / subtitle state
  bool _asrEnabled = false;
  String _currentSubtitle = '';
  String _lastFinalSubtitle = '';
  // 用于 isFinal 后延迟清屏
  bool _subtitleClearing = false;

  // Default model path — user can change this
  static const String _defaultModelDir =
      '/Users/wangyaqiang/Downloads/sherpa-models/sherpa-onnx-streaming-paraformer-bilingual-zh-en';
  // Silero VAD model path for sentence boundary detection
  static const String _defaultVadModel =
      '/Users/wangyaqiang/Downloads/sherpa-models/silero-vad/silero_vad.onnx';
  // ct-transformer punctuation model path (optional)
  static const String _defaultPunctModel =
      '/Users/wangyaqiang/Downloads/sherpa-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12/model.onnx';
  
  @override
  void initState() {
    super.initState();
    _createPlayer();
  }
  
  void _createPlayer() {
    _controller?.dispose();
    _controller = null;
    
    try {
      _controller = FfplayPlayerController();
      _controller!.onStateChanged = _onStateChanged;
      _controller!.onStatsUpdated = _onStatsUpdated;
      _controller!.onError = _onError;
      _controller!.onSubtitleUpdate = _onSubtitleUpdate;
      setState(() {});
    } catch (e) {
      setState(() {
        _status = 'Error creating player: $e';
      });
    }
  }

  void _onSubtitleUpdate(String text, bool isFinal, double positionS) {
    if (isFinal && text.isNotEmpty) {
      // 收到 final 结果：立即显示带标点的完整句子，然后延迟 1.5s 清屏
      setState(() {
        _currentSubtitle = text;
        _lastFinalSubtitle = text;
        _subtitleClearing = true;
      });
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && _subtitleClearing) {
          setState(() {
            _currentSubtitle = '';
            _subtitleClearing = false;
          });
        }
      });
    } else if (!_subtitleClearing) {
      // partial 结果：只在没有等待清屏时才更新（避免清屏前又显示新 partial）
      setState(() {
        _currentSubtitle = text;
      });
    } else {
      // 清屏等待期间收到新 partial，说明新句已开始，立即取消清屏并显示
      setState(() {
        _subtitleClearing = false;
        _currentSubtitle = text;
      });
    }
  }

  Future<void> _toggleAsr() async {
    if (_controller == null) return;
    if (!_asrEnabled) {
      // Init ASR with model directory and VAD model for better sentence segmentation
      final success = await _controller!.initAsr(
        _defaultModelDir,
        vadModel: _defaultVadModel,
        punctModel: _defaultPunctModel,
      );
      if (success) {
        setState(() {
          _asrEnabled = true;
          _currentSubtitle = '';
          _lastFinalSubtitle = '';
          _status = 'ASR 已启用';
        });
      } else {
        setState(() {
          _status = '❌ ASR 初始化失败，请确认模型路径: $_defaultModelDir';
        });
      }
    } else {
      await _controller!.enableAsr(false);
      setState(() {
        _asrEnabled = false;
        _currentSubtitle = '';
        _status = 'ASR 已停用';
      });
    }
  }

  Future<void> _resetPlayer() async {
    if (_controller != null) {
      await _controller!.stop();
      _seekingPosition = null;
      _isDragging = false;
      _dragPosition = 0;
    }
  }

  void _onStateChanged(FfplayPlayerState state) {
    setState(() {
      _status = 'State: ${state.name}';
    });
  }

  void _onStatsUpdated(FfplayPlayerStats stats) {
    if (_seekingPosition != null && !stats.seeking) {
      final diff = (stats.position - _seekingPosition!).abs();
      if (diff < 1.0) {
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
        await _resetPlayer();
        setState(() {
          _currentUrl = file.path;
          _status = file.name;
        });
        // Don't manually call setUrl/play here - let FfplayPlayer widget handle it
      }
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
    }
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null && data!.text!.isNotEmpty) {
        await _resetPlayer();
        setState(() {
          _currentUrl = data.text;
          _status = 'URL loaded';
        });
        // Don't manually call setUrl/play here - let FfplayPlayer widget handle it
      }
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
    }
  }

  Future<void> _playSampleVideo(String url, String name) async {
    await _resetPlayer();
    setState(() {
      _currentUrl = url;
      _status = name;
    });
    // Don't manually call setUrl/play here - let FfplayPlayer widget handle it
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

  Future<void> _seek(double seconds) async {
    _controller?.seek(seconds);
    if (_controller?.state == FfplayPlayerState.stopped || 
        _controller?.state == FfplayPlayerState.paused) {
      setState(() {
        _status = 'Seeking...';
      });
    }
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
  
  void _toggleLoop() {
    int newLoop = _loop == 1 ? 0 : 1;
    _loop = newLoop;
    _controller?.setLoop(newLoop);
    setState(() {});
  }
  
  void _setSpeed(double speed) {
    _speed = speed;
    _controller?.setSpeed(speed);
    setState(() {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                applicationLegalese: 'A Flutter video player using ffplay_jni.\n\n'
                    'Supports MP4, MKV, AVI, MOV, WebM and more.',
              );
            },
          ),
        ],
      ),
      body: Container(
        color: Colors.black,
        child: Column(
          children: [
            // Video player area with subtitle overlay
            Expanded(
              child: Stack(
                children: [
                  _controller != null
                      ? FfplayPlayer(
                          controller: _controller!,
                          url: _currentUrl,
                          autoPlay: true,
                          backgroundColor: Colors.black,
                        )
                      : const Center(
                          child: Text('No player', style: TextStyle(color: Colors.white54)),
                        ),

                  // Real-time ASR subtitle overlay
                  if (_asrEnabled && _currentSubtitle.isNotEmpty)
                    Positioned(
                      bottom: 24,
                      left: 40,
                      right: 40,
                      child: Center(
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 700),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.72),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _currentSubtitle,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              height: 1.4,
                              fontWeight: FontWeight.w500,
                              shadows: [
                                Shadow(
                                  offset: Offset(1, 1),
                                  blurRadius: 3,
                                  color: Colors.black,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
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
                  
                  // Control buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
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
                      
                      const SizedBox(width: 16),
                      
                      // ASR subtitle toggle button
                      IconButton(
                        icon: Icon(
                          Icons.closed_caption,
                          color: _asrEnabled ? Colors.blue : Colors.white38,
                        ),
                        iconSize: 24,
                        tooltip: _asrEnabled ? '关闭字幕' : '开启字幕 (ASR)',
                        onPressed: _toggleAsr,
                      ),

                      IconButton(
                        icon: Icon(
                          _loop == 0 ? Icons.repeat : Icons.repeat_one,
                          color: _loop == 0 ? Colors.green : Colors.white70,
                        ),
                        iconSize: 24,
                        tooltip: _loop == 0 ? 'Loop: ON' : 'Loop: OFF',
                        onPressed: _toggleLoop,
                      ),
                      
                      const SizedBox(width: 8),
                      
                      const Text('Speed:', style: TextStyle(fontSize: 12, color: Colors.white70)),
                      const SizedBox(width: 4),
                      DropdownButton<double>(
                        value: _speed,
                        dropdownColor: Colors.grey[900],
                        underline: Container(),
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                        items: const [
                          DropdownMenuItem(value: 0.25, child: Text('0.25x')),
                          DropdownMenuItem(value: 0.5, child: Text('0.5x')),
                          DropdownMenuItem(value: 0.75, child: Text('0.75x')),
                          DropdownMenuItem(value: 1.0, child: Text('1.0x')),
                          DropdownMenuItem(value: 1.25, child: Text('1.25x')),
                          DropdownMenuItem(value: 1.5, child: Text('1.5x')),
                          DropdownMenuItem(value: 1.75, child: Text('1.75x')),
                          DropdownMenuItem(value: 2.0, child: Text('2.0x')),
                        ],
                        onChanged: (value) {
                          if (value != null) _setSpeed(value);
                        },
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
