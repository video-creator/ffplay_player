import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Model download result enum (private)
enum _ModelDownloadResult {
  success,
  stalled,
  failed,
  error,
}

/// ASR Installer Service
/// 
/// Handles the complete ASR setup process:
/// 1. Install Python via Homebrew (if not installed)
/// 2. Create Python virtual environment
/// 3. Clone FireRedASR2S repository
/// 4. Install Python dependencies in venv
/// 5. Download ASR models
/// 6. Start ASR HTTP service
/// 7. Manage service lifecycle
class AsrInstallerService {
  static final AsrInstallerService _instance = AsrInstallerService._internal();
  factory AsrInstallerService() => _instance;
  AsrInstallerService._internal();

  // Configuration
  static const String fireredRepo = 'https://github.com/FireRedTeam/FireRedASR2S.git';
  static const String defaultHost = '127.0.0.1';
  static const int defaultPort = 8765;
  
  // State
  String? _asrPath;
  String? _venvPath;
  String? _pythonPath;
  String? _pipPath;
  Process? _asrProcess;
  bool _isInstalled = false;
  bool _isRunning = false;
  String _installStatus = '';
  double _installProgress = 0.0;
  
  // Getters
  bool get isInstalled => _isInstalled;
  bool get isRunning => _isRunning;
  String get installStatus => _installStatus;
  double get installProgress => _installProgress;
  String? get asrPath => _asrPath;
  String? get venvPath => _venvPath;
  
  // Callbacks
  void Function(String status, double progress)? onProgress;
  void Function(bool success, String? error)? onComplete;

  /// Get clean environment without PYTHONPATH interference
  /// This is important because system PYTHONPATH may point to incompatible libraries
  Map<String, String> _getCleanEnv({String? pythonPath}) {
    final env = Map<String, String>.from(Platform.environment);
    // Clear PYTHONPATH to avoid loading incompatible system libraries
    // (e.g., Python 2.7 site-packages with x86_64 binaries on arm64 Mac)
    if (pythonPath != null) {
      env['PYTHONPATH'] = pythonPath;
    } else {
      env.remove('PYTHONPATH');
    }
    env['PYTHONDONTWRITEBYTECODE'] = '1';
    return env;
  }

  /// Get the base directory for ASR installation
  Future<String> _getBaseDir() async {
    final appSupport = await getApplicationSupportDirectory();
    return '${appSupport.path}/asr';
  }

  /// Check if Homebrew is installed
  Future<bool> checkHomebrewInstalled() async {
    try {
      final result = await Process.run('which', ['brew']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  /// Check if Python is installed (system or via brew)
  Future<bool> checkPythonInstalled() async {
    // Check common Python paths
    final pythonPaths = [
      '/opt/homebrew/bin/python3',  // Apple Silicon Homebrew
      '/usr/local/bin/python3',      // Intel Homebrew
      '/usr/bin/python3',            // System Python
    ];
    
    for (final path in pythonPaths) {
      try {
        if (await File(path).exists()) {
          final result = await Process.run(path, ['--version']);
          if (result.exitCode == 0) {
            _pythonPath = path;
            return true;
          }
        }
      } catch (e) {
        continue;
      }
    }
    
    // Try PATH lookup
    try {
      final result = await Process.run('which', ['python3']);
      if (result.exitCode == 0) {
        final path = (result.stdout as String).trim();
        if (path.isNotEmpty) {
          _pythonPath = path;
          return true;
        }
      }
    } catch (e) {
      // Ignore
    }
    
    return false;
  }

  /// Check if pip is installed
  Future<bool> checkPipInstalled() async {
    if (_pythonPath != null) {
      try {
        final result = await Process.run(_pythonPath!, ['-m', 'pip', '--version']);
        return result.exitCode == 0;
      } catch (e) {
        return false;
      }
    }
    return false;
  }

  /// Install Python via Homebrew (requires Homebrew to be pre-installed)
  Future<bool> _installPythonViaHomebrew() async {
    // Check if Homebrew is installed
    if (!await checkHomebrewInstalled()) {
      _complete(false, 'Homebrew is not installed.\n\n'
          'Please install Homebrew first by running this command in Terminal:\n\n'
          '/bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"\n\n'
          'After installing Homebrew, run the ASR installation again.');
      return false;
    }
    
    _updateProgress('Installing Python via Homebrew...', 0.05);
    
    try {
      // Install Python via Homebrew
      final brewResult = await Process.run(
        'brew',
        ['install', 'python@3.11'],
      );
      
      if (brewResult.exitCode != 0) {
        // Try without version
        final brewResult2 = await Process.run(
          'brew',
          ['install', 'python3'],
        );
        
        if (brewResult2.exitCode != 0) {
          _complete(false, 'Failed to install Python via Homebrew.\n\n'
              'Please try manually: brew install python@3.11');
          return false;
        }
      }
      
      // Set Python path
      _pythonPath = '/opt/homebrew/bin/python3';
      if (!await File(_pythonPath!).exists()) {
        _pythonPath = '/usr/local/bin/python3';
        if (!await File(_pythonPath!).exists()) {
          // Try to find python3
          final whichResult = await Process.run('which', ['python3']);
          if (whichResult.exitCode == 0) {
            _pythonPath = (whichResult.stdout as String).trim();
          } else {
            _complete(false, 'Could not find Python after installation');
            return false;
          }
        }
      }
      
      return true;
    } catch (e) {
      _complete(false, 'Error installing Python: $e');
      return false;
    }
  }

  /// Create Python virtual environment
  Future<bool> _createVirtualEnvironment(String baseDir) async {
    _venvPath = '$baseDir/venv';
    
    // Check if venv already exists
    final venvPython = '$_venvPath/bin/python';
    if (await File(venvPython).exists()) {
      _updateProgress('Virtual environment already exists', 0.15);
      _pipPath = '$_venvPath/bin/pip';
      return true;
    }
    
    _updateProgress('Creating Python virtual environment...', 0.12);
    
    try {
      // Create venv
      final venvResult = await Process.run(
        _pythonPath ?? 'python3',
        ['-m', 'venv', _venvPath!],
      );
      
      if (venvResult.exitCode != 0) {
        _complete(false, 'Failed to create virtual environment: ${venvResult.stderr}');
        return false;
      }
      
      // Set pip path in venv
      _pipPath = '$_venvPath/bin/pip';
      
      // Verify venv was created
      if (!await File(venvPython).exists()) {
        _complete(false, 'Virtual environment was not created properly');
        return false;
      }
      
      // Upgrade pip in venv
      _updateProgress('Upgrading pip...', 0.14);
      await Process.run(_pipPath!, ['install', '--upgrade', 'pip', '--quiet']);
      
      return true;
    } catch (e) {
      _complete(false, 'Error creating virtual environment: $e');
      return false;
    }
  }

  /// Check if FireRedASR2S is already installed
  Future<bool> checkInstalled() async {
    final baseDir = await _getBaseDir();
    final fireredDir = '$baseDir/FireRedASR2S';
    final venvDir = '$baseDir/venv';
    final venvPython = '$venvDir/bin/python';
    final modelsDir = '$fireredDir/pretrained_models';
    
    // Check if venv exists
    if (!await File(venvPython).exists()) {
      _isInstalled = false;
      return false;
    }
    
    // Check if models directory exists
    if (!await Directory(modelsDir).exists()) {
      _isInstalled = false;
      return false;
    }
    
    // Check if required models are downloaded (ONLY by checking .download_complete marker file)
    // The marker file is only created when download is 100% complete
    final requiredModels = ['FireRedASR2-AED', 'FireRedVAD'];
    for (final model in requiredModels) {
      final markerFile = '$modelsDir/$model/.download_complete';
      
      // Only check marker file - it's created only when download completes successfully
      if (!await File(markerFile).exists()) {
        _isInstalled = false;
        return false;
      }
    }
    
    // All checks passed
    _asrPath = fireredDir;
    _venvPath = venvDir;
    _pipPath = '$venvDir/bin/pip';
    _isInstalled = true;
    return true;
  }

  /// Repair by reinstalling dependencies (keep models if already downloaded)
  Future<bool> repairDependencies() async {
    try {
      _updateProgress('Starting repair...', 0.0);
      _isInstalled = false;  // Reset state at the beginning
      
      // Step 1: Backup models if they exist and are complete
      final baseDir = await _getBaseDir();
      final modelsDir = '$baseDir/FireRedASR2S/pretrained_models';
      String? modelsBackup;
      
      if (await Directory(modelsDir).exists()) {
        // Check if models are complete (have .download_complete marker)
        final aedMarker = '$modelsDir/FireRedASR2-AED/.download_complete';
        final vadMarker = '$modelsDir/FireRedVAD/.download_complete';
        
        if (await File(aedMarker).exists() && await File(vadMarker).exists()) {
          // Models are complete, back them up
          modelsBackup = '$baseDir/models_backup_${DateTime.now().millisecondsSinceEpoch}';
          _updateProgress('Backing up complete models...', 0.1);
          final result = await Process.run('cp', ['-r', modelsDir, modelsBackup]);
          if (result.exitCode != 0) {
            print('Warning: Failed to backup models: ${result.stderr}');
            modelsBackup = null;
          }
        } else {
          _updateProgress('Models incomplete, will re-download', 0.1);
        }
      }
      
      // Step 2: Uninstall (will delete everything)
      _updateProgress('Uninstalling...', 0.2);
      final uninstalled = await uninstall();
      if (!uninstalled) {
        _complete(false, 'Uninstall failed during repair');
        return false;
      }
      
      // Step 3: Reinstall (without downloading models first)
      _updateProgress('Reinstalling dependencies...', 0.3);
      final installed = await install(downloadModels: false);
      if (!installed) {
        _complete(false, 'Reinstall failed during repair');
        return false;
      }
      
      // Step 4: Restore models from backup if available
      if (modelsBackup != null && await Directory(modelsBackup).exists()) {
        _updateProgress('Restoring models...', 0.8);
        final newModelsDir = '$baseDir/FireRedASR2S/pretrained_models';
        await Directory(newModelsDir).create(recursive: true);
        
        final copyResult1 = await Process.run('cp', ['-r', '$modelsBackup/FireRedASR2-AED', newModelsDir]);
        final copyResult2 = await Process.run('cp', ['-r', '$modelsBackup/FireRedVAD', newModelsDir]);
        
        // Clean up backup
        await Directory(modelsBackup).delete(recursive: true);
        
        if (copyResult1.exitCode == 0 && copyResult2.exitCode == 0) {
          _isInstalled = true;
          _updateProgress('Repair complete!', 1.0);
          _complete(true, null);
          return true;
        } else {
          _updateProgress('Failed to restore models, will download', 0.85);
        }
      }
      
      // Step 5: Download models if no backup or restore failed
      _updateProgress('Downloading models...', 0.85);
      if (!await _downloadModels()) {
        _complete(false, 'Failed to download models during repair');
        return false;
      }
      
      // Verify models are downloaded
      final finalModelsDir = '$baseDir/FireRedASR2S/pretrained_models';
      final finalAedMarker = '$finalModelsDir/FireRedASR2-AED/.download_complete';
      final finalVadMarker = '$finalModelsDir/FireRedVAD/.download_complete';
      
      if (await File(finalAedMarker).exists() && await File(finalVadMarker).exists()) {
        _isInstalled = true;
        _updateProgress('Repair complete!', 1.0);
        _complete(true, null);
        return true;
      } else {
        _complete(false, 'Model verification failed after download');
        return false;
      }
      
    } catch (e) {
      _complete(false, 'Repair failed: $e');
      return false;
    }
  }

  /// Uninstall ASR completely
  Future<bool> uninstall() async {
    try {
      _updateProgress('Uninstalling ASR...', 0.0);
      
      // Stop service first
      stopService();
      
      final baseDir = await _getBaseDir();
      
      // Delete venv
      if (await Directory('$baseDir/venv').exists()) {
        _updateProgress('Removing virtual environment...', 0.3);
        await Directory('$baseDir/venv').delete(recursive: true);
      }
      
      // Delete FireRedASR2S
      if (await Directory('$baseDir/FireRedASR2S').exists()) {
        _updateProgress('Removing FireRedASR2S...', 0.6);
        await Directory('$baseDir/FireRedASR2S').delete(recursive: true);
      }
      
      // Delete service script
      if (await File('$baseDir/asr_embedded_service.py').exists()) {
        await File('$baseDir/asr_embedded_service.py').delete();
      }
      
      _asrPath = null;
      _venvPath = null;
      _pipPath = null;
      _isInstalled = false;
      
      _updateProgress('Uninstall complete!', 1.0);
      _complete(true, null);
      return true;
      
    } catch (e) {
      _complete(false, 'Uninstall failed: $e');
      return false;
    }
  }

  /// Check if models are downloaded
  Future<Map<String, bool>> checkModelsDownloaded() async {
    if (_asrPath == null) {
      await checkInstalled();
    }
    
    if (_asrPath == null) {
      return {'FireRedASR2-AED': false, 'FireRedVAD': false};
    }
    
    final modelsDir = '$_asrPath/pretrained_models';
    return {
      'FireRedASR2-AED': await Directory('$modelsDir/FireRedASR2-AED').exists(),
      'FireRedVAD': await Directory('$modelsDir/FireRedVAD').exists(),
    };
  }

  /// Install FireRedASR2S with automatic Python installation
  Future<bool> install({bool downloadModels = true}) async {
    try {
      _updateProgress('Checking prerequisites...', 0.0);
      
      // Check and install Python if needed
      if (!await checkPythonInstalled()) {
        _updateProgress('Python not found. Attempting to install...', 0.01);
        
        if (!await _installPythonViaHomebrew()) {
          return false;
        }
      } else {
        _updateProgress('Python found: $_pythonPath', 0.02);
      }
      
      // Verify Python works - try multiple methods
      bool pythonWorks = false;
      String? pythonError;
      
      // Method 1: Try with current path
      if (_pythonPath != null) {
        try {
          final testResult = await Process.run(
            _pythonPath!,
            ['--version'],
          );
          if (testResult.exitCode == 0) {
            pythonWorks = true;
            _updateProgress('Python verified: ${testResult.stdout}'.trim(), 0.03);
          } else {
            pythonError = 'Exit code: ${testResult.exitCode}, stderr: ${testResult.stderr}';
          }
        } catch (e) {
          pythonError = e.toString();
        }
      }
      
      // Method 2: Try with python3 from PATH
      if (!pythonWorks) {
        try {
          final testResult = await Process.run('python3', ['--version']);
          if (testResult.exitCode == 0) {
            pythonWorks = true;
            _pythonPath = 'python3';
            _updateProgress('Python verified via PATH', 0.03);
          }
        } catch (e) {
          pythonError = e.toString();
        }
      }
      
      // Method 3: Try common paths
      if (!pythonWorks) {
        final commonPaths = [
          '/opt/homebrew/bin/python3',
          '/usr/local/bin/python3',
          '/usr/bin/python3',
        ];
        
        for (final path in commonPaths) {
          if (await File(path).exists()) {
            try {
              final testResult = await Process.run(path, ['--version']);
              if (testResult.exitCode == 0) {
                pythonWorks = true;
                _pythonPath = path;
                _updateProgress('Python verified at $path', 0.03);
                break;
              }
            } catch (e) {
              // Try next path
            }
          }
        }
      }
      
      if (!pythonWorks) {
        _complete(false, 'Could not find a working Python installation.\n\n'
            'Please install Python 3.8+ via Homebrew:\n'
            '  brew install python@3.11\n\n'
            'Or verify your Python installation works:\n'
            '  python3 --version\n\n'
            'Error: $pythonError');
        return false;
      }
      
      final baseDir = await _getBaseDir();
      final fireredDir = '$baseDir/FireRedASR2S';
      
      // Create base directory
      if (!await Directory(baseDir).exists()) {
        await Directory(baseDir).create(recursive: true);
      }
      
      // Create virtual environment
      if (!await _createVirtualEnvironment(baseDir)) {
        return false;
      }
      
      // Clone repository if not exists
      if (!await Directory(fireredDir).exists()) {
        _updateProgress('Cloning FireRedASR2S repository...', 0.18);
        
        try {
          final cloneResult = await Process.run(
            'git',
            ['clone', '--depth', '1', fireredRepo, fireredDir],
          );
          
          if (cloneResult.exitCode != 0) {
            _complete(false, 'Failed to clone repository: ${cloneResult.stderr}');
            return false;
          }
        } catch (e) {
          _complete(false, 'Error cloning repository: $e');
          return false;
        }
      } else {
        _updateProgress('Repository already exists', 0.18);
      }
      
      _asrPath = fireredDir;
      
      // Install dependencies in venv
      _updateProgress('Installing Python dependencies...', 0.25);
      
      try {
        // On macOS, we need to install CPU version of PyTorch
        // The original requirements.txt uses CUDA which doesn't work on macOS
        final isMacOS = Platform.isMacOS;
        
        if (isMacOS) {
          // Install PyTorch CPU version first
          _updateProgress('Installing PyTorch (CPU version for macOS)...', 0.26);
          final torchResult = await Process.run(
            _pipPath!,
            ['install', 'torch', 'torchaudio', '--quiet'],
          );
          
          if (torchResult.exitCode != 0) {
            _complete(false, 'Failed to install PyTorch: ${torchResult.stderr}');
            return false;
          }
          
          // Install other dependencies (skip torch and torchaudio which are already installed)
          _updateProgress('Installing other dependencies...', 0.30);
          final otherDeps = [
            'transformers>=4.40.0',
            'numpy>=1.24.0',
            'cn2an',
            'kaldiio',
            'kaldi_native_fbank',
            'sentencepiece',
            'soundfile',
            'textgrid',
            'peft>=0.13.2',
            'huggingface_hub>=0.34.0,<1.0',  // Version constraint to avoid conflict with transformers
            'modelscope',  // ModelScope for faster download in China
          ];
          
          final pipResult = await Process.run(
            _pipPath!,
            ['install', ...otherDeps, '--quiet'],
          );
          
          if (pipResult.exitCode != 0) {
            _complete(false, 'Failed to install dependencies: ${pipResult.stderr}');
            return false;
          }
        } else {
          // On other platforms, use the original requirements.txt
          final pipResult = await Process.run(
            _pipPath!,
            ['install', '-r', '$fireredDir/requirements.txt', '--quiet'],
          );
          
          if (pipResult.exitCode != 0) {
            _complete(false, 'Failed to install dependencies: ${pipResult.stderr}');
            return false;
          }
        }
      } catch (e) {
        _complete(false, 'Error installing dependencies: $e');
        return false;
      }
      
      // Install additional packages
      _updateProgress('Installing additional packages...', 0.35);
      try {
        await Process.run(_pipPath!, ['install', '-U', 'huggingface_hub', '--quiet']);
      } catch (e) {
        // Non-fatal
      }
      
      if (downloadModels) {
        // Download models
        if (!await _downloadModels()) {
          return false;
        }
      }
      
      // Only mark as installed if models are ready
      // Check if required models exist
      final modelsDir = '$_asrPath/pretrained_models';
      final aedMarker = '$modelsDir/FireRedASR2-AED/.download_complete';
      final vadMarker = '$modelsDir/FireRedVAD/.download_complete';
      
      if (await File(aedMarker).exists() && await File(vadMarker).exists()) {
        _isInstalled = true;
        _updateProgress('Installation complete!', 1.0);
        _complete(true, null);
        return true;
      } else if (downloadModels) {
        // Models were supposed to be downloaded but markers don't exist
        _complete(false, 'Model download verification failed');
        return false;
      } else {
        // Models not downloaded yet, don't mark as installed
        _updateProgress('Installation complete (models not downloaded yet)', 1.0);
        _complete(true, null);
        return true;
      }
      
    } catch (e) {
      _complete(false, 'Installation failed: $e');
      return false;
    }
  }

  // Download state
  String _downloadSpeed = '';
  double _downloadProgress = 0.0;
  String _downloadFile = '';
  
  // Getters for download info
  String get downloadSpeed => _downloadSpeed;
  double get downloadProgress => _downloadProgress;
  String get downloadFile => _downloadFile;
  
  /// Download a single model with progress tracking
  Future<bool> _downloadModel(String modelId, String localDir, double progressStart, double progressEnd) async {
    if (_venvPath == null) return false;
    
    final venvPython = '$_venvPath/bin/python';
    final env = _getCleanEnv(pythonPath: _asrPath);
    
    // Create download script if not exists
    final baseDir = await _getBaseDir();
    final scriptDir = '$baseDir/scripts';
    final downloadScript = '$scriptDir/download_model.py';
    
    // Ensure script directory exists
    if (!await Directory(scriptDir).exists()) {
      await Directory(scriptDir).create(recursive: true);
    }
    
    // Create download script
    await _createDownloadScript(downloadScript);
    
    const int maxRetries = 5;
    const Duration stallTimeout = Duration(seconds: 120); // 2 minutes without progress
    
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      if (attempt > 0) {
        _updateProgress('Retry attempt ${attempt + 1}/$maxRetries...', progressStart);
        await Future.delayed(const Duration(seconds: 2));
        
        // Clean up incomplete download
        if (await Directory(localDir).exists()) {
          try {
            await Directory(localDir).delete(recursive: true);
          } catch (e) {
            print('Warning: Failed to clean up incomplete download: $e');
          }
        }
      }
      
      try {
        final result = await _runDownloadProcess(
          venvPython: venvPython,
          downloadScript: downloadScript,
          modelId: modelId,
          localDir: localDir,
          env: env,
          progressStart: progressStart,
          progressEnd: progressEnd,
          stallTimeout: stallTimeout,
        );
        
        if (result == _ModelDownloadResult.success) {
          return true;
        } else if (result == _ModelDownloadResult.stalled) {
          _updateProgress('Download stalled, retrying...', progressStart);
          continue; // Retry
        } else {
          // Failed or error
          return false;
        }
      } catch (e) {
        _updateProgress('Download error: $e', progressStart);
        continue; // Retry
      }
    }
    
    _complete(false, 'Failed to download $modelId after $maxRetries attempts');
    return false;
  }
  
  Future<_ModelDownloadResult> _runDownloadProcess({
    required String venvPython,
    required String downloadScript,
    required String modelId,
    required String localDir,
    required Map<String, String> env,
    required double progressStart,
    required double progressEnd,
    required Duration stallTimeout,
  }) async {
    final process = await Process.start(
      venvPython,
      [downloadScript, '--model', modelId, '--local-dir', localDir],
      environment: env,
    );
    
    bool completed = false;
    bool stalled = false;
    String errorMsg = '';
    DateTime lastProgressTime = DateTime.now();
    
    // Parse stdout for progress
    process.stdout.transform(utf8.decoder).listen((data) {
      for (final line in data.split('\n')) {
        if (line.isEmpty) continue;
        
        if (line.startsWith('[SIZE]')) {
          lastProgressTime = DateTime.now(); // Update last progress time
          try {
            final sizeBytes = int.parse(line.substring('[SIZE]'.length).trim());
            final sizeMB = sizeBytes / (1024 * 1024);
            _downloadSpeed = '${sizeMB.toStringAsFixed(1)} MB';
            
            _updateProgress(
              'Downloading ${modelId.split('/').last}: ${sizeMB.toStringAsFixed(1)} MB',
              progressStart,
            );
          } catch (e) {
            // Ignore parse errors
          }
        } else if (line.startsWith('[START]')) {
          lastProgressTime = DateTime.now();
          _updateProgress('Starting download: ${modelId.split('/').last}...', progressStart);
        } else if (line.startsWith('[COMPLETE]')) {
          completed = true;
          _downloadSpeed = '';
          _updateProgress('Download complete: ${modelId.split('/').last}', progressEnd);
        } else if (line.startsWith('[ERROR]')) {
          errorMsg = line.substring('[ERROR]'.length).trim();
        } else if (line.startsWith('[FAILED]')) {
          errorMsg = line.substring('[FAILED]'.length).trim();
        }
      }
    });
    
    // Capture stderr
    process.stderr.transform(utf8.decoder).listen((data) {
      if (data.isNotEmpty && !data.contains('KeyboardInterrupt')) {
        errorMsg = data;
      }
    });
    
    // Stall detection timer - check every 10 seconds
    Timer? stallTimer;
    stallTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      final elapsed = DateTime.now().difference(lastProgressTime);
      if (elapsed > stallTimeout && !completed) {
        print('Download stalled for ${elapsed.inSeconds}s, killing process');
        stalled = true;
        timer.cancel();
        process.kill(ProcessSignal.sigkill);
      }
    });
    
    try {
      final exitCode = await process.exitCode;
      stallTimer.cancel();
      
      if (stalled) {
        return _ModelDownloadResult.stalled;
      } else if (exitCode == 0 && completed) {
        return _ModelDownloadResult.success;
      } else {
        if (errorMsg.isNotEmpty) {
          _complete(false, 'Failed to download $modelId: $errorMsg');
        }
        return _ModelDownloadResult.failed;
      }
    } catch (e) {
      stallTimer.cancel();
      if (stalled) {
        return _ModelDownloadResult.stalled;
      }
      return _ModelDownloadResult.error;
    }
  }
  
  /// Create the download script
  Future<void> _createDownloadScript(String scriptPath) async {
    const scriptContent = '''
#!/usr/bin/env python3
"""Model download script with progress tracking via ModelScope."""
import sys
import os
import time
import argparse
from pathlib import Path

def format_size(size_bytes):
    if size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    elif size_bytes < 1024 * 1024 * 1024:
        return f"{size_bytes / 1024 / 1024:.1f} MB"
    else:
        return f"{size_bytes / 1024 / 1024 / 1024:.2f} GB"

def get_dir_size(path):
    """Get total size of directory."""
    total = 0
    try:
        for f in Path(path).rglob('*'):
            if f.is_file():
                total += f.stat().st_size
    except:
        pass
    return total

def download_model(model_id, local_dir):
    """Download model from ModelScope."""
    try:
        from modelscope import snapshot_download
        
        print(f"[START] Downloading {model_id}")
        sys.stdout.flush()
        
        # Report progress periodically
        import threading
        stop_reporter = threading.Event()
        
        def report_progress():
            while not stop_reporter.is_set():
                try:
                    size = get_dir_size(local_dir)
                    print(f"[SIZE] {size}")
                    sys.stdout.flush()
                except:
                    pass
                time.sleep(1)
        
        reporter = threading.Thread(target=report_progress)
        reporter.daemon = True
        reporter.start()
        
        try:
            snapshot_download(
                model_id=model_id,
                cache_dir=os.path.dirname(local_dir),
                local_dir=local_dir,
            )
        finally:
            stop_reporter.set()
            reporter.join(timeout=2)
        
        final_size = get_dir_size(local_dir)
        
        # Create completion marker file
        marker_file = os.path.join(local_dir, ".download_complete")
        with open(marker_file, 'w') as f:
            f.write(f"model_id: {model_id}\\n")
            f.write(f"download_time: {time.strftime('%Y-%m-%d %H:%M:%S')}\\n")
            f.write(f"size: {final_size}\\n")
        
        print(f"[SIZE] {final_size}")
        print(f"[COMPLETE] Download finished, size: {format_size(final_size)}")
        sys.stdout.flush()
        return 0
        
    except KeyboardInterrupt:
        print("[ABORT] Download interrupted")
        sys.stdout.flush()
        return 1
    except Exception as e:
        print(f"[ERROR] {str(e)}")
        sys.stdout.flush()
        return 1

def main():
    parser = argparse.ArgumentParser(description='Download model with progress via ModelScope')
    parser.add_argument('--model', required=True, help='Model ID')
    parser.add_argument('--local-dir', required=True, help='Local directory to save model')
    args = parser.parse_args()
    os.makedirs(args.local_dir, exist_ok=True)
    exit_code = download_model(args.model, args.local_dir)
    sys.exit(exit_code)

if __name__ == '__main__':
    main()
''';
    
    await File(scriptPath).writeAsString(scriptContent);
  }

  /// Download ASR models with progress tracking
  Future<bool> _downloadModels() async {
    if (_asrPath == null || _venvPath == null) return false;
    
    try {
      final modelsDir = '$_asrPath/pretrained_models';
      if (!await Directory(modelsDir).exists()) {
        await Directory(modelsDir).create(recursive: true);
      }
      
      // Download FireRedASR2-AED (progress: 0.45 - 0.85)
      // Skip if .download_complete marker file exists
      final aedMarker = '$modelsDir/FireRedASR2-AED/.download_complete';
      if (!await File(aedMarker).exists()) {
        if (!await _downloadModel('xukaituo/FireRedASR2-AED', '$modelsDir/FireRedASR2-AED', 0.45, 0.85)) {
          return false;
        }
      } else {
        _updateProgress('FireRedASR2-AED already downloaded', 0.85);
      }
      
      // Download FireRedVAD (progress: 0.85 - 0.95)
      // Skip if .download_complete marker file exists
      final vadMarker = '$modelsDir/FireRedVAD/.download_complete';
      if (!await File(vadMarker).exists()) {
        if (!await _downloadModel('xukaituo/FireRedVAD', '$modelsDir/FireRedVAD', 0.85, 0.95)) {
          return false;
        }
      } else {
        _updateProgress('FireRedVAD already downloaded', 0.95);
      }
      
      return true;
    } catch (e) {
      _complete(false, 'Failed to download models: $e');
      return false;
    }
  }
  
  /// Start the ASR HTTP service
  Future<bool> startService({String host = defaultHost, int port = defaultPort}) async {
    if (_isRunning) return true;
    
    if (_asrPath == null || _venvPath == null) {
      await checkInstalled();
    }
    
    if (_asrPath == null || _venvPath == null) {
      _complete(false, 'ASR not installed. Please install first.');
      return false;
    }
    
    try {
      // Create ASR service script
      final serviceScript = await _createServiceScript();
      
      final venvPython = '$_venvPath/bin/python';
      
      // Build environment - clear PYTHONPATH to avoid conflicts with system Python paths
      // This ensures venv uses only its own site-packages
      final env = Map<String, String>.from(Platform.environment);
      env['PYTHONPATH'] = _asrPath!;  // Only include ASR path, not system paths
      env['PYTHONDONTWRITEBYTECODE'] = '1';  // Don't write .pyc files
      
      // Start the service using venv Python
      _asrProcess = await Process.start(
        venvPython,
        [serviceScript, '--host', host, '--port', port.toString(), '--asr-path', _asrPath!],
        environment: env,
      );
      
      // Monitor output
      _asrProcess!.stdout.transform(utf8.decoder).listen((data) {
        print('[ASR Service] $data');
      });
      
      _asrProcess!.stderr.transform(utf8.decoder).listen((data) {
        print('[ASR Service Error] $data');
      });
      
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
      
      if (_isRunning) {
        print('ASR service started successfully on $host:$port');
      } else {
        print('Failed to start ASR service');
      }
      
      return _isRunning;
      
    } catch (e) {
      print('Failed to start ASR service: $e');
      return false;
    }
  }

  /// Stop the ASR service
  void stopService() {
    if (_asrProcess != null) {
      _asrProcess!.kill();
      _asrProcess = null;
      _isRunning = false;
    }
  }

  /// Create the embedded ASR service script
  Future<String> _createServiceScript() async {
    final baseDir = await _getBaseDir();
    final scriptPath = '$baseDir/asr_embedded_service.py';
    
    final script = _getEmbeddedServiceScript();
    
    await File(scriptPath).writeAsString(script);
    return scriptPath;
  }

  /// Get the embedded ASR service Python script
  String _getEmbeddedServiceScript() {
    return '''
#!/usr/bin/env python3
"""
Embedded FireRedASR2S HTTP Service
"""
import argparse
import json
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from typing import Optional, Dict, Any

# Add FireRedASR2S to path
firered_path = os.environ.get("ASR_PATH", "") or os.environ.get("PYTHONPATH", "")
if firered_path:
    sys.path.insert(0, firered_path)

# Global ASR system
asr_system = None

def init_asr_system(firered_path: str) -> bool:
    """Initialize the ASR system."""
    global asr_system
    
    if asr_system is not None:
        return True
    
    try:
        if firered_path:
            sys.path.insert(0, firered_path)
        from fireredasr2s import FireRedAsr2System, FireRedAsr2SystemConfig
        
        asr_system_config = FireRedAsr2SystemConfig()
        asr_system = FireRedAsr2System(asr_system_config)
        print("ASR system initialized successfully")
        return True
    except Exception as e:
        print(f"Failed to initialize ASR: {e}")
        return False

def transcribe_audio(audio_path: str) -> Optional[Dict[str, Any]]:
    """Transcribe audio file."""
    global asr_system
    
    if not os.path.exists(audio_path):
        return {"error": f"Audio file not found: {audio_path}"}
    
    if asr_system is None:
        return {"error": "ASR system not initialized"}
    
    try:
        result = asr_system.process(audio_path)
        sentences = []
        for sent in result.get("sentences", []):
            sentences.append({
                "start_ms": sent.get("start_ms", 0),
                "end_ms": sent.get("end_ms", 0),
                "text": sent.get("text", ""),
            })
        
        return {
            "success": True,
            "sentences": sentences,
            "duration_ms": int(result.get("dur_s", 0) * 1000),
        }
    except Exception as e:
        return {"error": f"Transcription failed: {str(e)}"}

class ASRHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress logging
    
    def send_json_response(self, data: Dict[str, Any], status: int = 200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode("utf-8"))
    
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
    
    def do_GET(self):
        if self.path == "/status":
            self.send_json_response({
                "status": "running",
                "models_available": asr_system is not None
            })
        else:
            self.send_json_response({"error": "Not found"}, 404)
    
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        
        try:
            data = json.loads(body) if body else {}
        except:
            self.send_json_response({"error": "Invalid JSON"}, 400)
            return
        
        if self.path == "/transcribe":
            audio_path = data.get("audio_path")
            if not audio_path:
                self.send_json_response({"error": "audio_path required"}, 400)
                return
            
            result = transcribe_audio(audio_path)
            if "error" in result:
                self.send_json_response(result, 500)
            else:
                self.send_json_response(result)
        else:
            self.send_json_response({"error": "Not found"}, 404)

def main():
    parser = argparse.ArgumentParser(description="FireRedASR2S Embedded Service")
    parser.add_argument("--host", type=str, default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--asr-path", type=str, default="")
    args = parser.parse_args()
    
    firered_path = args.asr_path or os.environ.get("PYTHONPATH", "")
    
    print(f"Initializing ASR system from: {firered_path}")
    init_asr_system(firered_path)
    
    server = HTTPServer((args.host, args.port), ASRHandler)
    print(f"ASR service running at http://{args.host}:{args.port}")
    server.serve_forever()

if __name__ == "__main__":
    main()
''';
  }

  void _updateProgress(String status, double progress) {
    _installStatus = status;
    _installProgress = progress;
    onProgress?.call(status, progress);
  }

  void _complete(bool success, String? error) {
    onComplete?.call(success, error);
  }

  /// Dispose resources
  void dispose() {
    stopService();
  }
}
