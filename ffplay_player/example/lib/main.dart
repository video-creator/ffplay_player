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
  String _status = 'Ready - Click "Create Player" to start';
  String? _currentUrl;
  
  // For seek slider - only seek on drag end
  bool _isDragging = false;
  double _dragPosition = 0;
  double? _seekingPosition; // Target position when seeking, null when not seeking
  
  @override
  void initState() {
    super.initState();
  }

  void _createPlayer() {
    _controller?.dispose();
    
    try {
      _controller = FfplayPlayerController();
      _controller!.onStateChanged = _onStateChanged;
      _controller!.onStatsUpdated = _onStatsUpdated;
      _controller!.onError = _onError;
      
      setState(() {
        _status = 'Player created - Enter URL or select a file';
      });
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
    // Clear seeking position when actual position is close to target
    if (_seekingPosition != null) {
      final diff = (stats.position - _seekingPosition!).abs();
      // If we're within 0.5 seconds of the target, consider seek complete
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
        label: 'Video files',
        extensions: <String>[
          'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v', 
          'mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a'
        ],
      );
      
      final XFile? file = await openFile(acceptedTypeGroups: [typeGroup]);
      
      if (file != null) {
        setState(() {
          _currentUrl = file.path;
          _status = 'File selected: ${file.name}';
        });
        if (_controller != null) {
          await _controller!.setUrl(file.path);
        }
      }
    } catch (e) {
      setState(() {
        _status = 'Error picking file: $e';
      });
    }
  }

  void _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null && data!.text!.isNotEmpty) {
        setState(() {
          _currentUrl = data.text;
          _status = 'URL pasted from clipboard';
        });
        if (_controller != null) {
          await _controller!.setUrl(data.text!);
        }
      } else {
        setState(() {
          _status = 'Clipboard is empty';
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Error pasting: $e';
      });
    }
  }

  Future<void> _play() async {
    if (_controller == null) {
      _createPlayer();
      // Wait a bit for player to be created
      await Future.delayed(const Duration(milliseconds: 100));
    }
    
    if (_currentUrl == null || _currentUrl!.isEmpty) {
      setState(() {
        _status = 'Please enter a URL or select a file';
      });
      return;
    }
    
    // Check if file exists for local paths
    if (!_currentUrl!.startsWith('http://') && !_currentUrl!.startsWith('https://') && 
        !_currentUrl!.startsWith('rtmp://') && !_currentUrl!.startsWith('rtsp://')) {
      final file = File(_currentUrl!);
      if (!await file.exists()) {
        setState(() {
          _status = 'File not found: $_currentUrl';
        });
        return;
      }
    }
    
    await _controller!.setUrl(_currentUrl!);
    
    setState(() {
      _status = 'Starting playback...';
    });
    
    final success = await _controller!.play();
    setState(() {
      _status = success ? 'Playing' : 'Failed to start playback';
    });
  }

  void _stop() {
    if (_controller != null) {
      _controller!.stop();
      setState(() {
        _status = 'Stopped';
      });
    }
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
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.light,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('FFplay Player Demo'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          actions: [
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: 'About',
              onPressed: () {
                showAboutDialog(
                  context: context,
                  applicationName: 'FFplay Player Demo',
                  applicationLegalese: 'A Flutter plugin for video playback using ffplay_jni.\n\n'
                    'Supports:\n'
                    '• Local video files\n'
                    '• Network streams (HTTP/HTTPS)\n'
                    '• Seek, pause, volume control\n'
                    '• Multiple formats (MP4, MKV, AVI, etc.)',
                );
              },
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status Card
              Card(
                color: _status.contains('Error') ? Colors.red.shade50 : null,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Icon(
                        _status.contains('Error') ? Icons.error_outline : Icons.info_outline,
                        color: _status.contains('Error') ? Colors.red : Colors.blue,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _status,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              
              // Video Player View
              if (_controller != null) ...[
                Container(
                  height: 300,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: FfplayPlayer(
                      controller: _controller!,
                      url: _currentUrl,
                      backgroundColor: Colors.black,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              
              // Player Creation
              if (_controller == null)
                ElevatedButton.icon(
                  onPressed: _createPlayer,
                  icon: const Icon(Icons.add),
                  label: const Text('Create Player'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(16),
                  ),
                ),
              
              if (_controller != null) ...[
                // Progress Section
                if (_controller!.duration > 0) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                formatDuration(_isDragging ? _dragPosition : (_seekingPosition ?? _controller!.position)),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                formatDuration(_controller!.duration),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                          Slider(
                            value: _isDragging 
                                ? _dragPosition.clamp(0.0, _controller!.duration) 
                                : (_seekingPosition ?? _controller!.position).clamp(0.0, _controller!.duration),
                            max: _controller!.duration > 0 ? _controller!.duration : 1,
                            onChangeStart: (value) {
                              _isDragging = true;
                              _dragPosition = value;
                            },
                            onChanged: (value) {
                              // Update local value during drag without seeking
                              setState(() {
                                _dragPosition = value;
                              });
                            },
                            onChangeEnd: (value) {
                              // Set seeking position to show target while seeking
                              setState(() {
                                _isDragging = false;
                                _seekingPosition = value;
                              });
                              _seek(value);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                
                // Volume Control
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            IconButton(
                              icon: Icon(_controller!.muted ? Icons.volume_off : Icons.volume_up),
                              onPressed: _toggleMute,
                              tooltip: _controller!.muted ? 'Unmute' : 'Mute',
                            ),
                            Expanded(
                              child: Slider(
                                value: _controller!.volume.toDouble(),
                                min: 0,
                                max: 100,
                                onChanged: (value) => _setVolume(value.toInt()),
                              ),
                            ),
                            SizedBox(
                              width: 50,
                              child: Text(
                                '${_controller!.volume}%',
                                textAlign: TextAlign.right,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                
                // Main Controls
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          onPressed: _play,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: _controller!.state == FfplayPlayerState.playing ? _pause : null,
                          icon: const Icon(Icons.pause),
                          label: const Text('Pause'),
                        ),
                        ElevatedButton.icon(
                          onPressed: _controller!.state == FfplayPlayerState.paused ? _resume : null,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Resume'),
                        ),
                        ElevatedButton.icon(
                          onPressed: _stop,
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                
                // Seek Controls
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        Text('Seek', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            ElevatedButton(
                              onPressed: () => _controller?.seekRelative(-30),
                              child: const Text('-30s'),
                            ),
                            ElevatedButton(
                              onPressed: () => _controller?.seekRelative(-10),
                              child: const Text('-10s'),
                            ),
                            ElevatedButton(
                              onPressed: () => _controller?.seekRelative(-5),
                              child: const Text('-5s'),
                            ),
                            ElevatedButton(
                              onPressed: () => _controller?.seekRelative(5),
                              child: const Text('+5s'),
                            ),
                            ElevatedButton(
                              onPressed: () => _controller?.seekRelative(10),
                              child: const Text('+10s'),
                            ),
                            ElevatedButton(
                              onPressed: () => _controller?.seekRelative(30),
                              child: const Text('+30s'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              
              // URL Input Section
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Media Source', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _pickFile,
                              icon: const Icon(Icons.folder_open),
                              label: const Text('Select File'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _pasteFromClipboard,
                              icon: const Icon(Icons.content_paste),
                              label: const Text('Paste URL'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              
              // Sample URLs Section
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Sample Videos', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ActionChip(
                            label: const Text('Big Buck Bunny (10s)'),
                            onPressed: () async {
                              final url = 'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4';
                              setState(() {
                                _currentUrl = url;
                                _status = 'Sample video selected';
                              });
                              if (_controller != null) {
                                await _controller!.setUrl(url);
                              }
                            },
                          ),
                          ActionChip(
                            label: const Text('Sintel (10s)'),
                            onPressed: () async {
                              final url = 'https://test-videos.co.uk/vids/sintel/mp4/h264/360/Sintel_360_10s_1MB.mp4';
                              setState(() {
                                _currentUrl = url;
                                _status = 'Sample video selected';
                              });
                              if (_controller != null) {
                                await _controller!.setUrl(url);
                              }
                            },
                          ),
                          ActionChip(
                            label: const Text('Jellyfish (10s)'),
                            onPressed: () async {
                              final url = 'https://test-videos.co.uk/vids/jellyfish/mp4/h264/360/Jellyfish_360_10s_1MB.mp4';
                              setState(() {
                                _currentUrl = url;
                                _status = 'Sample video selected';
                              });
                              if (_controller != null) {
                                await _controller!.setUrl(url);
                              }
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
