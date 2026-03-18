import 'dart:convert';
import 'dart:io';

/// ASR Service client for speech-to-text using FireRedASR2S
/// 
/// This client communicates with the local ASR HTTP service.
/// The service should be running at http://127.0.0.1:8765 by default.
class AsrService {
  final String host;
  final int port;
  final Duration timeout;

  AsrService({
    this.host = '127.0.0.1',
    this.port = 8765,
    this.timeout = const Duration(seconds: 300), // 5 minutes for long audio
  });

  String get _baseUrl => 'http://$host:$port';

  /// Check if the ASR service is running
  Future<AsrStatus> checkStatus() async {
    try {
      final data = await _get('/status');
      return AsrStatus(
        running: data['status'] == 'running',
        modelsAvailable: data['models_available'] as bool? ?? false,
      );
    } catch (e) {
      return AsrStatus(running: false, modelsAvailable: false, error: e.toString());
    }
  }

  /// Check model download status
  Future<ModelStatus> checkModelsStatus() async {
    try {
      final data = await _get('/models/status');
      final models = (data['models'] as Map<String, dynamic>?) ?? {};
      final progress = data['download_progress'] as Map<String, dynamic>?;
      
      return ModelStatus(
        models: models.map((k, v) => MapEntry(k, v as bool? ?? false)),
        allDownloaded: data['all_downloaded'] as bool? ?? false,
        downloading: progress?['downloading'] as bool? ?? false,
        downloadProgress: progress?['progress'] as int? ?? 0,
        downloadStatus: progress?['status'] as String? ?? '',
      );
    } catch (e) {
      return ModelStatus(models: {}, allDownloaded: false, error: e.toString());
    }
  }

  /// Start downloading models
  Future<DownloadResult> downloadModels() async {
    try {
      final data = await _post('/models/download', {});
      return DownloadResult(
        started: data['status'] == 'Download started',
        progress: data['progress'] as Map<String, dynamic>?,
      );
    } catch (e) {
      return DownloadResult(started: false, error: e.toString());
    }
  }

  /// Transcribe an audio file
  /// 
  /// [audioPath] - Path to the audio file (should be 16kHz mono WAV)
  /// Returns transcription result with sentences and timing
  Future<TranscriptionResult> transcribe(String audioPath) async {
    print('[AsrService] transcribe called with: $audioPath');
    try {
      print('[AsrService] Calling POST /transcribe...');
      final data = await _post('/transcribe', {'audio_path': audioPath});
      print('[AsrService] Response data: $data');
      
      if (data['error'] != null) {
        return TranscriptionResult(
          success: false,
          error: data['error'] as String,
        );
      }
      
      return TranscriptionResult(
        success: data['success'] as bool? ?? true,
        sentences: (data['sentences'] as List?)
            ?.map((s) => TranscriptionSentence.fromJson(s as Map<String, dynamic>))
            .toList() ?? [],
        durationMs: data['duration_ms'] as int? ?? 0,
      );
    } catch (e) {
      return TranscriptionResult(success: false, error: e.toString());
    }
  }

  /// Transcribe with automatic retry and waiting
  Future<TranscriptionResult> transcribeWithRetry(
    String audioPath, {
    int maxRetries = 3,
    Duration retryDelay = const Duration(seconds: 2),
  }) async {
    for (int i = 0; i < maxRetries; i++) {
      final result = await transcribe(audioPath);
      if (result.success) {
        return result;
      }
      
      // Check if it's a service unavailable error
      if (result.error?.contains('Connection refused') == true && i < maxRetries - 1) {
        await Future.delayed(retryDelay);
        continue;
      }
      
      return result;
    }
    return TranscriptionResult(success: false, error: 'Max retries exceeded');
  }

  // HTTP helpers
  Future<Map<String, dynamic>> _get(String path) async {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    
    try {
      final request = await client.getUrl(Uri.parse('$_baseUrl$path'));
      final response = await request.close();
      
      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        return json.decode(body) as Map<String, dynamic>;
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    
    try {
      final request = await client.postUrl(Uri.parse('$_baseUrl$path'));
      request.headers.contentType = ContentType.json;
      request.write(json.encode(body));
      final response = await request.close();
      
      final responseBody = await response.transform(utf8.decoder).join();
      
      if (responseBody.isEmpty) {
        return {};
      }
      
      return json.decode(responseBody) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }
}

/// ASR service status
class AsrStatus {
  final bool running;
  final bool modelsAvailable;
  final String? error;

  const AsrStatus({
    required this.running,
    required this.modelsAvailable,
    this.error,
  });
}

/// Model download status
class ModelStatus {
  final Map<String, bool> models;
  final bool allDownloaded;
  final bool downloading;
  final int downloadProgress;
  final String downloadStatus;
  final String? error;

  const ModelStatus({
    required this.models,
    required this.allDownloaded,
    this.downloading = false,
    this.downloadProgress = 0,
    this.downloadStatus = '',
    this.error,
  });

  bool get hasModels => models.values.any((v) => v);
}

/// Download result
class DownloadResult {
  final bool started;
  final Map<String, dynamic>? progress;
  final String? error;

  const DownloadResult({
    required this.started,
    this.progress,
    this.error,
  });
}

/// Transcription sentence
class TranscriptionSentence {
  final int startMs;
  final int endMs;
  final String text;
  final List<TranscriptionWord>? words;

  const TranscriptionSentence({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.words,
  });

  factory TranscriptionSentence.fromJson(Map<String, dynamic> json) {
    return TranscriptionSentence(
      startMs: json['start_ms'] as int? ?? 0,
      endMs: json['end_ms'] as int? ?? 0,
      text: json['text'] as String? ?? '',
      words: json['words'] != null
          ? (json['words'] as List)
              .map((w) => TranscriptionWord.fromJson(w as Map<String, dynamic>))
              .toList()
          : null,
    );
  }

  Duration get start => Duration(milliseconds: startMs);
  Duration get end => Duration(milliseconds: endMs);
}

/// Word-level transcription
class TranscriptionWord {
  final String word;
  final int startMs;
  final int endMs;
  final double? confidence;

  const TranscriptionWord({
    required this.word,
    required this.startMs,
    required this.endMs,
    this.confidence,
  });

  factory TranscriptionWord.fromJson(Map<String, dynamic> json) {
    return TranscriptionWord(
      word: json['word'] as String? ?? '',
      startMs: json['start_ms'] as int? ?? 0,
      endMs: json['end_ms'] as int? ?? 0,
      confidence: json['confidence'] as double?,
    );
  }
}

/// Transcription result
class TranscriptionResult {
  final bool success;
  final List<TranscriptionSentence> sentences;
  final int durationMs;
  final String? error;
  final String text;

  const TranscriptionResult({
    required this.success,
    this.sentences = const [],
    this.durationMs = 0,
    this.error,
    this.text = '',
  });

  Duration get duration => Duration(milliseconds: durationMs);
}
