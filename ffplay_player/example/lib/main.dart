import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';

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
  
  // ASR services
  final AsrScriptService _installer = AsrScriptService();
  final AsrService _asrService = AsrService();
  
  // Subtitles
  SubtitleTrack? _subtitleTrack;
  SubtitleEntry? _currentSubtitle;
  bool _showSubtitlePanel = false;
  
  // ASR state
  bool _isGeneratingSubtitles = false;
  bool _asrInstalled = false;
  bool _asrRunning = false;
  
  // Global installation state (shared between dialog and background)
  bool _isInstalling = false;
  String _installStatus = '';
  double _installProgress = 0.0;
  List<String> _installLogs = [];
  
  @override
  void initState() {
    super.initState();
    _createPlayer();
    _checkAsrStatus();
    _setupInstallCallbacks();
  }
  
  void _createPlayer() {
    _controller?.dispose();
    _controller = null;
    
    try {
      _controller = FfplayPlayerController();
      _controller!.onStateChanged = _onStateChanged;
      _controller!.onStatsUpdated = _onStatsUpdated;
      _controller!.onError = _onError;
      setState(() {});
    } catch (e) {
      print('[GenerateSubtitles] Exception: $e');
      setState(() {
        _status = 'Error creating player: $e';
      });
    }
  }
  
  Future<void> _checkAsrStatus() async {
    _asrInstalled = await _installer.checkInstalled();
    
    // Check if service is running
    final status = await _asrService.checkStatus();
    _asrRunning = status.running;
    
    setState(() {});
  }
  
  void _setupInstallCallbacks() {
    _installer.onProgress = (status, progress) {
      setState(() {
        _installStatus = status;
        _installProgress = progress;
        _installLogs.add('[${DateTime.now().toString().substring(11, 19)}] $status');
      });
    };
    
    _installer.onComplete = (success, error) {
      setState(() {
        _isInstalling = false;
        if (success) {
          _asrInstalled = true;
          _installLogs.add('[${DateTime.now().toString().substring(11, 19)}] ✓ Installation complete!');
          _status = 'ASR installed successfully';
        } else {
          _installLogs.add('[${DateTime.now().toString().substring(11, 19)}] ✗ Error: $error');
        }
      });
      if (success) {
        _checkAsrStatus();
        _showInstallNotification('Installation complete!', success: true);
        Future.delayed(const Duration(seconds: 1), () {
          _startAsrService();
        });
      } else {
        _showInstallNotification('Installation failed: $error', success: false);
      }
    };
  }
  
  void _showInstallNotification(String message, {required bool success}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(success ? Icons.check_circle : Icons.error, color: success ? Colors.green : Colors.red),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: success ? Colors.green[800] : Colors.red[800],
        duration: const Duration(seconds: 5),
      ),
    );
  }
  
  void _showInstallDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _InstallProgressDialog(
        installer: _installer,
        isInstalling: _isInstalling,
        installStatus: _installStatus,
        installProgress: _installProgress,
        installLogs: List.from(_installLogs),
        asrInstalled: _asrInstalled,
        onStateUpdate: (isInstalling, status, progress, logs) {
          setState(() {
            _isInstalling = isInstalling;
            _installStatus = status;
            _installProgress = progress;
            _installLogs = logs;
          });
        },
        onComplete: (success) {
          if (success) {
            _checkAsrStatus();
          }
        },
        onClose: () {
          Navigator.pop(dialogContext);
        },
      ),
    );
  }
  
  Future<void> _startAsrService() async {
    final success = await _installer.startService();
    if (success) {
      await Future.delayed(const Duration(seconds: 2));
      final status = await _asrService.checkStatus();
      setState(() {
        _asrRunning = status.running;
        if (_asrRunning) {
          _status = 'ASR service running';
        }
      });
    }
  }
  
  Future<void> _generateSubtitles() async {
    print('[GenerateSubtitles] Starting subtitle generation');
    print('[GenerateSubtitles] Video URL: $_currentUrl');
    print('[GenerateSubtitles] ASR installed: $_asrInstalled');
    
    if (_currentUrl == null) {
      setState(() => _status = 'No video loaded');
      return;
    }
    
    // Check if ASR is installed
    if (!_asrInstalled) {
      _showInstallDialog();
      return;
    }
    
    // No need to start HTTP service - we call Python script directly
    
    setState(() {
      _isGeneratingSubtitles = true;
      _status = 'Extracting audio...';
    });
    
    try {
      // Create temp directory for audio extraction
      final tempDir = await getTemporaryDirectory();
      final audioPath = '${tempDir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.wav';
      print('[GenerateSubtitles] Audio output path: $audioPath');
      
      // Extract audio using ffmpeg_transcoder_run
      print('[GenerateSubtitles] Extracting audio...');
      final extractResult = await FfplayPlayerPlugin.extractAudio(
        inputPath: _currentUrl!,
        outputPath: audioPath,
        sampleRate: 16000,
      );
      
      print('[GenerateSubtitles] Extract result: $extractResult');
      
      if (extractResult != 0) {
        print('[GenerateSubtitles] ERROR: Audio extraction failed');
        setState(() {
          _status = 'Audio extraction failed: $extractResult';
          _isGeneratingSubtitles = false;
        });
        return;
      }
      
      // Check if file was created
      final audioFile = File(audioPath);
      if (await audioFile.exists()) {
        final fileSize = await audioFile.length();
        print('[GenerateSubtitles] Audio file created, size: $fileSize bytes');
      } else {
        print('[GenerateSubtitles] ERROR: Audio file not created');
        setState(() {
          _status = 'Audio file not created';
          _isGeneratingSubtitles = false;
        });
        return;
      }
      
      setState(() => _status = 'Transcribing audio...');
      
      // Transcribe using ASR script service (direct Python call, no HTTP)
      print('[GenerateSubtitles] Calling _installer.transcribe...');
      final result = await _installer.transcribe(audioPath);
      
      print('[GenerateSubtitles] Transcribe result: success=${result.success}, error=${result.error}, sentences=${result.sentences.length}');
      
      if (result.success) {
        setState(() {
          _subtitleTrack = SubtitleTrack(
            entries: result.sentences
                .map((s) => SubtitleEntry(
                      startMs: s.startMs,
                      endMs: s.endMs,
                      text: s.text,
                    ))
                .toList(),
            durationMs: result.durationMs,
          );
          _status = 'Subtitles generated: ${result.sentences.length} segments';
          _showSubtitlePanel = true;
        });
      } else {
        setState(() {
          _status = 'Transcription failed: ${result.error}';
        });
      }
      
      // Clean up temp file
      if (await audioFile.exists()) {
        await audioFile.delete();
      }
    } catch (e) {
      print('[GenerateSubtitles] Exception: $e');
      setState(() {
        _status = 'Error: $e';
      });
    } finally {
      setState(() {
        _isGeneratingSubtitles = false;
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
    
    // Update current subtitle
    if (_subtitleTrack != null) {
      final position = Duration(milliseconds: (stats.position * 1000).toInt());
      final entry = _subtitleTrack!.getEntryAt(position);
      if (entry != _currentSubtitle) {
        _currentSubtitle = entry;
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
          _subtitleTrack = null;
          _currentSubtitle = null;
        });
        if (_controller != null) {
          await _controller!.setUrl(file.path);
          await _controller!.play();
        }
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
          _subtitleTrack = null;
          _currentSubtitle = null;
        });
        if (_controller != null) {
          await _controller!.setUrl(data.text!);
          await _controller!.play();
        }
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
      _subtitleTrack = null;
      _currentSubtitle = null;
    });
    if (_controller != null) {
      await _controller!.setUrl(url);
      await _controller!.play();
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
    _installer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _isInstalling 
          ? Row(
              children: [
                const SizedBox(width: 8, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Installing ASR...', style: const TextStyle(fontSize: 14)),
                      Text(_installStatus, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                ),
              ],
            )
          : Text(_status, style: const TextStyle(fontSize: 14)),
        actions: [
          // Generate Subtitles button
          IconButton(
            icon: Badge(
              isLabelVisible: !_asrInstalled && !_isInstalling,
              label: const Text('!'),
              child: const Icon(Icons.auto_awesome),
            ),
            tooltip: 'Generate Subtitles',
            onPressed: _isGeneratingSubtitles || _isInstalling ? null : _generateSubtitles,
          ),
          
          // ASR Menu
          PopupMenuButton<String>(
            icon: const Icon(Icons.settings_suggest),
            tooltip: 'ASR Settings',
            onSelected: (value) {
              switch (value) {
                case 'install':
                  _showInstallDialog();
                  break;
                case 'start':
                  _startAsrService();
                  break;
                case 'check':
                  _checkAsrStatus();
                  break;
                case 'toggle_panel':
                  setState(() => _showSubtitlePanel = !_showSubtitlePanel);
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                child: ListTile(
                  leading: _isInstalling 
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(
                        _asrInstalled ? Icons.check_circle : Icons.download,
                        color: _asrInstalled ? Colors.green : null,
                      ),
                  title: Text(_isInstalling 
                    ? 'ASR Installing... (${(_installProgress * 100).toInt()}%)' 
                    : (_asrInstalled ? 'ASR Installed' : 'Install ASR')),
                ),
                value: 'install',
              ),
              PopupMenuItem(
                enabled: _asrInstalled && !_asrRunning && !_isInstalling,
                child: ListTile(
                  leading: Icon(
                    _asrRunning ? Icons.check_circle : Icons.play_circle,
                    color: _asrRunning ? Colors.green : null,
                  ),
                  title: Text(_asrRunning ? 'Service Running' : 'Start Service'),
                ),
                value: 'start',
              ),
              const PopupMenuItem(
                value: 'check',
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('Refresh Status'),
                ),
              ),
              const PopupMenuItem(
                value: 'toggle_panel',
                child: ListTile(
                  leading: Icon(Icons.view_sidebar),
                  title: Text('Toggle Subtitle Panel'),
                ),
              ),
            ],
          ),
          
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
                    'Supports MP4, MKV, AVI, MOV, WebM and more.\n\n'
                    'With AI-powered subtitle generation using FireRedASR2S.\n\n'
                    'ASR Status: ${_asrInstalled ? "Installed" : "Not installed"}\n'
                    'Service: ${_asrRunning ? "Running" : "Stopped"}',
              );
            },
          ),
        ],
      ),
      body: Row(
        children: [
          // Main content
          Expanded(
            flex: _showSubtitlePanel && _subtitleTrack != null ? 2 : 1,
            child: Column(
              children: [
                // Video player area
                Expanded(
                  child: Stack(
                    children: [
                      Container(
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
                      // Subtitle overlay
                      if (_currentSubtitle != null)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 80,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            color: Colors.black54,
                            child: Text(
                              _currentSubtitle!.text,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                shadows: [
                                  Shadow(
                                    offset: Offset(1, 1),
                                    blurRadius: 2,
                                    color: Colors.black,
                                  ),
                                ],
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      // Loading indicator
                      if (_isGeneratingSubtitles)
                        Positioned.fill(
                          child: Container(
                            color: Colors.black54,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const CircularProgressIndicator(),
                                  const SizedBox(height: 16),
                                  Text(_status, style: const TextStyle(color: Colors.white)),
                                ],
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
          
          // Subtitle panel
          if (_showSubtitlePanel && _subtitleTrack != null)
            Container(
              width: 300,
              color: Colors.grey[850],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    color: Colors.grey[900],
                    child: Row(
                      children: [
                        const Icon(Icons.subtitles, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Subtitles (${_subtitleTrack!.entries.length})',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() => _showSubtitlePanel = false),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _subtitleTrack!.entries.length,
                      itemBuilder: (context, index) {
                        final entry = _subtitleTrack!.entries[index];
                        final isActive = entry == _currentSubtitle;
                        return InkWell(
                          onTap: () => _seek(entry.start.inSeconds.toDouble()),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            color: isActive ? Colors.indigo.withOpacity(0.3) : null,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${_formatTime(entry.start)} - ${_formatTime(entry.end)}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isActive ? Colors.indigo[200] : Colors.grey[500],
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  entry.text,
                                  style: TextStyle(color: isActive ? Colors.white : Colors.grey[300]),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
  
  String _formatTime(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// Installation progress dialog widget
class _InstallProgressDialog extends StatefulWidget {
  final AsrScriptService installer;
  final bool isInstalling;
  final String installStatus;
  final double installProgress;
  final List<String> installLogs;
  final bool asrInstalled;
  final void Function(bool isInstalling, String status, double progress, List<String> logs) onStateUpdate;
  final void Function(bool success) onComplete;
  final VoidCallback onClose;

  const _InstallProgressDialog({
    required this.installer,
    required this.isInstalling,
    required this.installStatus,
    required this.installProgress,
    required this.installLogs,
    required this.asrInstalled,
    required this.onStateUpdate,
    required this.onComplete,
    required this.onClose,
  });

  @override
  State<_InstallProgressDialog> createState() => _InstallProgressDialogState();
}

class _InstallProgressDialogState extends State<_InstallProgressDialog> {
  final ScrollController _scrollController = ScrollController();
  late TextEditingController _logController;
  
  // Stream subscriptions
  StreamSubscription<ProgressEvent>? _progressSubscription;
  StreamSubscription<CompleteEvent>? _completeSubscription;
  
  // Local copies of state for UI updates
  late bool _isInstalling;
  late String _installStatus;
  late double _installProgress;
  late List<String> _installLogs;
  late bool _asrInstalled;
  
  @override
  void initState() {
    super.initState();
    // Initialize from widget props
    _isInstalling = widget.isInstalling;
    _installStatus = widget.installStatus;
    _installProgress = widget.installProgress;
    _installLogs = List.from(widget.installLogs);
    _asrInstalled = widget.asrInstalled;
    
    // If no logs, add initial log
    if (_installLogs.isEmpty) {
      _installLogs.add('[${DateTime.now().toString().substring(11, 19)}] Ready to install');
    }
    
    _logController = TextEditingController(text: _installLogs.join('\n'));
    _scrollToBottom();
    
    // Subscribe to progress events
    _progressSubscription = widget.installer.onProgressStream.listen((event) {
      _updateState(
        status: event.status,
        progress: event.percent / 100.0, // Convert percent to 0-1 range
        logEntry: '[${DateTime.now().toString().substring(11, 19)}] ${event.status}',
      );
    });
    
    // Subscribe to complete events
    _completeSubscription = widget.installer.onCompleteStream.listen((event) {
      _updateState(
        isInstalling: false,
        logEntry: event.success 
          ? '[${DateTime.now().toString().substring(11, 19)}] ✓ Installation complete!'
          : '[${DateTime.now().toString().substring(11, 19)}] ✗ Error: ${event.error}',
      );
      widget.onComplete(event.success);
    });
  }
  
  void _updateState({bool? isInstalling, String? status, double? progress, String? logEntry}) {
    setState(() {
      if (isInstalling != null) _isInstalling = isInstalling;
      if (status != null) _installStatus = status;
      if (progress != null) _installProgress = progress;
      if (logEntry != null) _installLogs.add(logEntry);
    });
    _updateLogText();
    // Notify parent of state change
    widget.onStateUpdate(_isInstalling, _installStatus, _installProgress, List.from(_installLogs));
  }
  
  void _updateLogText() {
    _logController.text = _installLogs.join('\n');
    _scrollToBottom();
  }
  
  @override
  void dispose() {
    _progressSubscription?.cancel();
    _completeSubscription?.cancel();
    _logController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
  
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }
  
  Future<void> _startInstallation() async {
    _updateState(
      isInstalling: true,
      status: 'Starting installation...',
      progress: 0.0,
      logEntry: '[${DateTime.now().toString().substring(11, 19)}] Starting ASR installation...',
    );
    
    await widget.installer.install(downloadModels: true);
  }
  
  Future<void> _repairDependencies() async {
    _updateState(
      isInstalling: true,
      status: 'Repairing dependencies...',
      progress: 0.0,
      logEntry: '[${DateTime.now().toString().substring(11, 19)}] Starting dependency repair...',
    );
    
    await widget.installer.repairDependencies();
  }
  
  Future<void> _uninstall() async {
    _updateState(
      isInstalling: true,
      status: 'Uninstalling...',
      progress: 0.0,
      logEntry: '[${DateTime.now().toString().substring(11, 19)}] Starting uninstall...',
    );
    
    await widget.installer.uninstall();
    _updateState(
      isInstalling: false,
      logEntry: '[${DateTime.now().toString().substring(11, 19)}] Uninstall complete',
    );
    setState(() {
      _asrInstalled = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.download),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_asrInstalled ? 'ASR Status' : 'Install ASR'),
          ),
        ],
      ),
      content: SizedBox(
        width: 580,
        height: 650,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
            // Status info
            if (_asrInstalled && !_isInstalling) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text('ASR is installed and ready to use'),
                    ),
                  ],
                ),
              ),
            ] else if (!_isInstalling) ...[
              const Text(
                'This will install:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              _buildStep('Python 3.11 (via Homebrew)', 'If not already installed'),
              _buildStep('FireRedASR2S', 'Speech recognition engine (~50MB)'),
              _buildStep('Python dependencies', 'Required packages'),
              _buildStep('ASR models', 'FireRedASR2-AED (~500MB) + FireRedVAD (~50MB)'),
            ],
            
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            
            // Progress section
            if (_isInstalling) ...[
              Text(
                'Progress: $_installStatus',
                style: const TextStyle(fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: _installProgress,
                backgroundColor: Colors.grey[700],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${(_installProgress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                  if (widget.installer.downloadSpeed.isNotEmpty)
                    Text(
                      widget.installer.downloadSpeed,
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                    ),
                ],
              ),
            ],
            
            const SizedBox(height: 12),
            
            // Log section - with minimum height constraint
            const Text(
              'Installation Log:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: 150,
                maxHeight: 300,
              ),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: TextField(
                  controller: _logController,
                  scrollController: _scrollController,
                  maxLines: null,
                  expands: true,
                  readOnly: true,
                  enableInteractiveSelection: true,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.grey[400],
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    isDense: true,
                  ),
                ),
              ),
            ),
            
            // Prerequisites warning
            if (!_isInstalling && !_asrInstalled) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.orange),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.warning, color: Colors.orange, size: 16),
                        SizedBox(width: 8),
                        Text('Prerequisites:', style: TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      '• Homebrew must be installed\n'
                      '• Run in Terminal: /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"',
                      style: TextStyle(fontSize: 11, color: Colors.grey[300]),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
        if (_isInstalling)
          TextButton.icon(
            onPressed: widget.onClose,
            icon: const Icon(Icons.minimize),
            label: const Text('Run in Background'),
          ),
        TextButton(
          onPressed: _isInstalling ? null : widget.onClose,
          child: const Text('Close'),
        ),
        if (!_isInstalling && !_asrInstalled)
          ElevatedButton.icon(
            onPressed: _startInstallation,
            icon: const Icon(Icons.download),
            label: const Text('Install ASR'),
          ),
        if (!_isInstalling && _asrInstalled) ...[
          TextButton.icon(
            onPressed: _repairDependencies,
            icon: const Icon(Icons.build),
            label: const Text('Repair'),
          ),
          TextButton.icon(
            onPressed: _uninstall,
            icon: const Icon(Icons.delete, color: Colors.red),
            label: const Text('Uninstall', style: TextStyle(color: Colors.red)),
          ),
        ],
      ],
    );
  }

  Widget _buildStep(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline, size: 16, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
