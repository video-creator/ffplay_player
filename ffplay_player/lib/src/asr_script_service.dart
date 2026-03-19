import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'asr_service.dart' show TranscriptionSentence, TranscriptionResult;

/// ASR Script Service
/// Calls the Python asr_manager.py script to manage ASR installation
class AsrScriptService {
  static final AsrScriptService _instance = AsrScriptService._internal();
  factory AsrScriptService() => _instance;
  AsrScriptService._internal();

  String? _baseDir;
  String? _scriptPath;
  String? _venvPython;
  bool _isInstalled = false;
  bool _isRunning = false;
  Process? _serviceProcess;
  String _downloadSpeed = '';
  
  // Stream controllers for state updates
  final _progressController = StreamController<ProgressEvent>.broadcast();
  final _completeController = StreamController<CompleteEvent>.broadcast();
  
  /// Stream of progress events
  Stream<ProgressEvent> get onProgressStream => _progressController.stream;
  
  /// Stream of complete events
  Stream<CompleteEvent> get onCompleteStream => _completeController.stream;

  /// Progress callback: (status, percent)
  void Function(String status, double percent)? onProgress;

  /// Complete callback: (success, error)
  void Function(bool success, String? error)? onComplete;

  /// Download progress callback: (model, sizeMb, sizeBytes)
  void Function(String model, double sizeMb, int sizeBytes)? onDownloadProgress;

  /// Get current download speed
  String get downloadSpeed => _downloadSpeed;

  /// Get the base directory for ASR installation
  Future<String> _getBaseDir() async {
    if (_baseDir != null) return _baseDir!;

    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '';
      _baseDir = '$home/Library/Application Support/com.example.ffplayPlayerExample/asr';
    } else {
      final home = Platform.environment['HOME'] ?? '';
      _baseDir = '$home/.ffplay_player/asr';
    }

    return _baseDir!;
  }

  /// Get the path to the Python script
  /// If the script doesn't exist in the ASR directory, it will be created
  Future<String> _getScriptPath() async {
    if (_scriptPath != null) return _scriptPath!;

    final baseDir = await _getBaseDir();
    final scriptDir = '$baseDir/scripts';
    _scriptPath = '$scriptDir/asr_manager.py';

    // Ensure script directory exists
    final scriptDirFile = Directory(scriptDir);
    if (!await scriptDirFile.exists()) {
      await scriptDirFile.create(recursive: true);
    }

    // Check if script exists, if not, create it
    final scriptFile = File(_scriptPath!);
    if (!await scriptFile.exists()) {
      // Create the embedded script
      await _createEmbeddedScript(scriptFile.path);
    }

    return _scriptPath!;
  }

  /// Create the embedded Python script
  Future<void> _createEmbeddedScript(String scriptPath) async {
    // This is a placeholder - in production, the script should be bundled with the app
    // For now, we'll check if the script exists in the example directory
    final possiblePaths = [
      // Try PWD-based path (for development)
      '${Platform.environment['PWD']}/example/scripts/asr_manager.py',
      // Try relative to executable
      '${Platform.resolvedExecutable}/../../example/scripts/asr_manager.py',
    ];

    for (final path in possiblePaths) {
      final file = File(path);
      if (await file.exists()) {
        await file.copy(scriptPath);
        return;
      }
    }

    // If no script found, create a minimal stub that reports an error
    await File(scriptPath).writeAsString('''
#!/usr/bin/env python3
import json
import sys
print(json.dumps({"event": "error", "message": "ASR manager script not found. Please reinstall the application."}))
sys.exit(1)
''');
  }

  /// Get the path to the venv Python
  Future<String> _getVenvPython() async {
    if (_venvPython != null) return _venvPython!;

    final baseDir = await _getBaseDir();
    _venvPython = '$baseDir/venv/bin/python';

    return _venvPython!;
  }

  /// Emit a progress event
  void _emitProgress(String status, double percent) {
    onProgress?.call(status, percent);
    _progressController.add(ProgressEvent(status, percent));
  }

  /// Emit a complete event
  void _emitComplete(bool success, String? error) {
    onComplete?.call(success, error);
    _completeController.add(CompleteEvent(success, error));
  }

  /// Run a Python command and parse JSON output
  Future<Map<String, dynamic>> _runCommand(List<String> args, {bool useVenv = false}) async {
    String scriptPath;
    try {
      scriptPath = await _getScriptPath();
    } catch (e) {
      _emitComplete(false, 'Failed to get script path: $e');
      return {'event': 'error', 'message': 'Failed to get script path: $e'};
    }
    
    String pythonPath = useVenv ? await _getVenvPython() : 'python3';

    // Print debug info
    print('[ASR] Running: $pythonPath $scriptPath ${args.join(' ')}');
    print('[ASR] Script exists: ${await File(scriptPath).exists()}');
    print('[ASR] Python exists: ${await File(pythonPath).exists()}');

    Process process;
    try {
      process = await Process.start(
        pythonPath,
        [scriptPath, ...args],
        environment: {
          'PYTHONUNBUFFERED': '1',
        },
      );
    } catch (e) {
      _emitComplete(false, 'Failed to start process: $e');
      return {'event': 'error', 'message': 'Failed to start process: $e'};
    }

    final results = <Map<String, dynamic>>[];
    String? lastError;

    // Parse stdout for JSON output
    process.stdout.transform(utf8.decoder).listen((data) {
      print('[ASR stdout] $data');
      for (final line in data.split('\n')) {
        if (line.isEmpty) continue;
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          results.add(json);

          // Handle different event types
          final event = json['event'] as String?;
          switch (event) {
            case 'progress':
              final status = json['status'] as String? ?? '';
              final percent = (json['percent'] as num?)?.toDouble() ?? 0.0;
              _emitProgress(status, percent);
              break;
            case 'download_progress':
              final model = json['model'] as String? ?? '';
              final sizeMb = (json['size_mb'] as num?)?.toDouble() ?? 0.0;
              final sizeBytes = (json['size_bytes'] as num?)?.toInt() ?? 0;
              _downloadSpeed = '${sizeMb.toStringAsFixed(1)} MB';
              onDownloadProgress?.call(model, sizeMb, sizeBytes);
              break;
            case 'complete':
              final success = json['success'] as bool? ?? false;
              _downloadSpeed = '';
              _emitComplete(success, null);
              break;
            case 'error':
              lastError = json['message'] as String?;
              _downloadSpeed = '';
              _emitComplete(false, lastError);
              break;
            case 'status':
              // Status event, don't trigger callbacks
              break;
          }
        } catch (e) {
          // Not a JSON line, ignore
          print('[ASR] Non-JSON line: $line');
        }
      }
    });

    // Capture stderr
    process.stderr.transform(utf8.decoder).listen((data) {
      print('[ASR stderr] $data');
      if (data.isNotEmpty) {
        lastError = data;
      }
    });

    final exitCode = await process.exitCode;
    print('[ASR] Exit code: $exitCode');

    // Return the last result or error
    if (results.isNotEmpty) {
      return results.last;
    }

    return {
      'event': 'error',
      'message': lastError ?? 'Unknown error (exit code: $exitCode)',
    };
  }

  /// Check if ASR is installed
  Future<bool> checkInstalled() async {
    try {
      final result = await _runCommand(['check-status']);
      _isInstalled = result['installed'] as bool? ?? false;
      return _isInstalled;
    } catch (e) {
      return false;
    }
  }

  /// Get detailed installation status
  Future<Map<String, dynamic>> getStatus() async {
    try {
      final result = await _runCommand(['check-status']);
      return result;
    } catch (e) {
      return {
        'venv_exists': false,
        'firered_exists': false,
        'models': {'FireRedASR2-AED': false, 'FireRedVAD': false},
        'installed': false,
      };
    }
  }

  /// Install ASR environment
  Future<bool> install({bool downloadModels = true, bool testMode = false, int testSizeMb = 1}) async {
    final args = ['install'];
    if (downloadModels) {
      args.add('--download-models');
    }
    if (testMode) {
      args.add('--test-mode');
      args.add('--test-size-mb');
      args.add(testSizeMb.toString());
    }

    try {
      final result = await _runCommand(args);
      if (result['event'] == 'complete' && result['success'] == true) {
        _isInstalled = true;
        return true;
      }
      return false;
    } catch (e) {
      _emitComplete(false, e.toString());
      return false;
    }
  }

  /// Download models only
  Future<bool> downloadModels({bool testMode = false, int testSizeMb = 1}) async {
    final args = ['download-models'];
    if (testMode) {
      args.add('--test-mode');
      args.add('--test-size-mb');
      args.add(testSizeMb.toString());
    }

    try {
      final result = await _runCommand(args, useVenv: true);
      if (result['event'] == 'complete' && result['success'] == true) {
        _isInstalled = true;
        return true;
      }
      return false;
    } catch (e) {
      _emitComplete(false, e.toString());
      return false;
    }
  }

  /// Start ASR HTTP service
  Future<bool> startService({String host = '127.0.0.1', int port = 8765}) async {
    if (_isRunning) return true;

    try {
      final scriptPath = await _getScriptPath();
      final venvPython = await _getVenvPython();

      _serviceProcess = await Process.start(
        venvPython,
        [scriptPath, 'start-service', '--host', host, '--port', port.toString()],
        environment: {
          'PYTHONUNBUFFERED': '1',
        },
      );

      // Wait for service to start
      await Future.delayed(const Duration(seconds: 3));

      // Check if service is running
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse('http://$host:$port/status'));
        final response = await request.close();
        _isRunning = response.statusCode == 200;
      } catch (e) {
        _isRunning = false;
      } finally {
        client.close();
      }

      return _isRunning;
    } catch (e) {
      return false;
    }
  }

  /// Stop ASR service
  void stopService() {
    if (_serviceProcess != null) {
      _serviceProcess!.kill();
      _serviceProcess = null;
      _isRunning = false;
    }
  }

  /// Repair ASR installation
  Future<bool> repair() async {
    try {
      final result = await _runCommand(['repair']);
      if (result['event'] == 'complete' && result['success'] == true) {
        _isInstalled = true;
        return true;
      }
      return false;
    } catch (e) {
      _emitComplete(false, e.toString());
      return false;
    }
  }

  /// Repair dependencies (alias for repair)
  Future<bool> repairDependencies() async {
    return repair();
  }

  /// Uninstall ASR
  Future<bool> uninstall() async {
    stopService();
    
    try {
      final result = await _runCommand(['uninstall']);
      if (result['event'] == 'complete' && result['success'] == true) {
        _isInstalled = false;
        return true;
      }
      return false;
    } catch (e) {
      _emitComplete(false, e.toString());
      return false;
    }
  }

  /// Transcribe audio file
  /// Returns a TranscriptionResult with sentences and timing
  Future<TranscriptionResult> transcribe(String audioPath) async {
    print('[ASR] transcribe called with: $audioPath');
    
    try {
      final result = await _runCommand(['transcribe', audioPath], useVenv: true);
      print('[ASR] transcribe result: $result');
      
      // Check for error
      if (result['event'] == 'error') {
        return TranscriptionResult(
          success: false,
          error: result['message'] as String? ?? 'Unknown error',
        );
      }
      
      // Parse transcription result
      // Python returns data directly at root level
      if (result['event'] != 'transcription') {
        return TranscriptionResult(
          success: false,
          error: 'Unexpected event type: ${result['event']}',
        );
      }
      
      final sentences = (result['sentences'] as List?)
          ?.map((s) => TranscriptionSentence.fromJson(s as Map<String, dynamic>))
          .toList() ?? [];
      
      return TranscriptionResult(
        success: result['success'] as bool? ?? true,
        sentences: sentences,
        durationMs: result['duration_ms'] as int? ?? 0,
        text: result['text'] as String? ?? '',
      );
    } catch (e) {
      print('[ASR] transcribe exception: $e');
      return TranscriptionResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Dispose resources
  void dispose() {
    stopService();
    onProgress = null;
    onComplete = null;
    onDownloadProgress = null;
    _progressController.close();
    _completeController.close();
  }

  /// Check if ASR is installed
  bool get isInstalled => _isInstalled;

  /// Check if ASR service is running
  bool get isRunning => _isRunning;
}

/// Progress event
class ProgressEvent {
  final String status;
  final double percent;
  
  ProgressEvent(this.status, this.percent);
}

/// Complete event
class CompleteEvent {
  final bool success;
  final String? error;
  
  CompleteEvent(this.success, this.error);
}
