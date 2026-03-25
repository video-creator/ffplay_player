import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ffplay_player/ffplay_player.dart';
import 'package:file_selector/file_selector.dart';
import 'package:desktop_drop/desktop_drop.dart';

import 'history_store.dart';
import 'subtitle_history.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FfplayPlayerPlugin.initialize();
  await HistoryStore.instance.load();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FFplay Player',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const AppShell(),
    );
  }
}

// ─────────────────────────────────────────────
// AppShell: multi-tab manager
// ─────────────────────────────────────────────

class _TabData {
  final String id;
  String title;
  String? currentUrl;
  FfplayPlayerController controller;
  bool asrEnabled;
  bool asrLoading;   // true while ASR models are loading in background
  String currentSubtitle;
  String finalSubtitleBuffer;  // accumulated final sentences (space-separated)
  bool subtitleClearing;       // kept for API compat, no longer used for clear logic
  Timer? clearTimer;           // auto-clear timer after silence
  final SubtitleHistory subtitleHistory;
  Timer? autoSaveTimer;

  _TabData({
    required this.id,
    required this.title,
    required this.controller,
  })  : currentUrl = null,
        asrEnabled = false,
        asrLoading = false,
        currentSubtitle = '',
        finalSubtitleBuffer = '',
        subtitleClearing = false,
        subtitleHistory = SubtitleHistory();

  void dispose() {
    autoSaveTimer?.cancel();
    clearTimer?.cancel();
    controller.dispose();
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const int _maxTabs = 4;
  final List<_TabData> _tabs = [];
  int _activeIndex = 0;

  static int _tabCounter = 1;

  @override
  void initState() {
    super.initState();
    _addTab();
  }

  @override
  void dispose() {
    for (final t in _tabs) {
      t.dispose();
    }
    super.dispose();
  }

  _TabData _makeTab() {
    final id = 'tab_${_tabCounter++}';
    final ctrl = FfplayPlayerController();
    final tab = _TabData(id: id, title: '新窗口 $_tabCounter', controller: ctrl);
    ctrl.onSubtitleUpdate = (text, isFinal, posS) => _onSubtitle(tab, text, isFinal, posS);
    return tab;
  }

  void _addTab() {
    if (_tabs.length >= _maxTabs) return;
    setState(() {
      final tab = _makeTab();
      _tabs.add(tab);
      _activeIndex = _tabs.length - 1;
    });
  }

  void _closeTab(int index) {
    if (_tabs.length <= 1) return;
    setState(() {
      _tabs[index].dispose();
      _tabs.removeAt(index);
      if (_activeIndex >= _tabs.length) {
        _activeIndex = _tabs.length - 1;
      }
    });
  }

  void _selectTab(int index) {
    setState(() => _activeIndex = index);
  }

  // ── subtitle callback ──
  //
  // Clear-screen rules (applied when isFinal=true):
  //   A) New sentence alone > 15 chars  → clear immediately, show new sentence alone.
  //   B) New sentence alone ≤ 15 chars:
  //        • Accumulated (prev + new) > 30 chars  → clear, show new sentence alone.
  //        • Otherwise                             → append with a space (keep both).
  //   After any final, a 1-second pause timer is started.  If no new speech
  //   arrives within 1 s the screen clears (handles rule "pause > 1 s → clear").
  //
  // Partial results are shown as a live preview appended after the current buffer.
  // Subtitle is displayed with fontSize=20 in a maxWidth=720 box → ~18 CJK chars per line.
  // We keep to ONE line (maxLines=1) so the overlay never grows taller.
  // Rules (applied on isFinal):
  //   • New sentence alone ≥ _kLineCap chars  → clear first, show new sentence alone.
  //   • Combined (prev + new) ≥ _kLineCap     → clear first, show new sentence alone.
  //   • Combined < _kLineCap                  → append with a space.
  //   In all cases a 1-second silence timer triggers a clear.
  static const int _kLineCap = 18; // chars that fit in one line at fontSize 20 / width 720

  void _clearSubtitle(_TabData tab) {
    if (mounted) {
      setState(() {
        tab.finalSubtitleBuffer = '';
        tab.currentSubtitle = '';
        tab.subtitleClearing = false;
      });
    }
  }

  void _onSubtitle(_TabData tab, String text, bool isFinal, double posS) {
    if (isFinal && text.isNotEmpty) {
      tab.subtitleHistory.add(text, posS);
      tab.clearTimer?.cancel();

      final prev = tab.finalSubtitleBuffer.trim();
      final joined = prev.isEmpty ? text : '$prev $text';

      // Clear if either the new sentence alone or the combined text fills the line.
      if (text.length >= _kLineCap || joined.length >= _kLineCap) {
        tab.finalSubtitleBuffer = text; // start fresh
      } else {
        tab.finalSubtitleBuffer = joined; // keep both
      }

      setState(() {
        tab.currentSubtitle = tab.finalSubtitleBuffer;
        tab.subtitleClearing = false;
      });

      // Start 1-second pause timer. Cleared if the next partial arrives in time.
      tab.clearTimer = Timer(const Duration(seconds: 1), () => _clearSubtitle(tab));
    } else if (text.isNotEmpty) {
      // Partial preview: user is still speaking — cancel clear timer.
      // Show already-confirmed text + space + current partial so the display
      // reads naturally without the confirmed part disappearing mid-sentence.
      tab.clearTimer?.cancel();
      final prev = tab.finalSubtitleBuffer.trim();
      final display = prev.isEmpty ? text : '$prev $text';
      setState(() => tab.currentSubtitle = display);
    }
  }

  // ── open URL into a tab ──
  Future<void> _openInTab(_TabData tab, String url, String name) async {
    // Clear subtitle state
    tab.clearTimer?.cancel();
    setState(() {
      tab.currentSubtitle = '';
      tab.finalSubtitleBuffer = '';
      tab.subtitleClearing = false;
      tab.subtitleHistory.clear();
      tab.title = name.length > 20 ? '${name.substring(0, 18)}…' : name;
      tab.currentUrl = url;
    });
    await HistoryStore.instance.recordPlay(url: url, displayName: name);
    // Start auto-save timer
    tab.autoSaveTimer?.cancel();
    tab.autoSaveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final pos = tab.controller.position;
      final dur = tab.controller.duration;
      if (url.isNotEmpty && pos > 0) {
        HistoryStore.instance.updatePosition(url, pos, dur);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Tab bar
        Material(
          color: Colors.grey[900],
          child: _TabBar(
            tabs: _tabs,
            activeIndex: _activeIndex,
            maxTabs: _maxTabs,
            onSelect: _selectTab,
            onClose: _closeTab,
            onAdd: _addTab,
          ),
        ),
        // Active player window
        Expanded(
          child: IndexedStack(
            index: _activeIndex,
            children: List.generate(_tabs.length, (i) {
              return _PlayerWindow(
                key: ValueKey(_tabs[i].id),
                tab: _tabs[i],
                onOpenInNewTab: _tabs.length < _maxTabs
                    ? (url, name) {
                        _addTab();
                        _openInTab(_tabs.last, url, name);
                      }
                    : null,
                onOpenUrl: (url, name) => _openInTab(_tabs[i], url, name),
                onTabUpdated: () => setState(() {}),
              );
            }),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// Tab bar widget
// ─────────────────────────────────────────────

class _TabBar extends StatelessWidget {
  final List<_TabData> tabs;
  final int activeIndex;
  final int maxTabs;
  final void Function(int) onSelect;
  final void Function(int) onClose;
  final VoidCallback onAdd;

  const _TabBar({
    required this.tabs,
    required this.activeIndex,
    required this.maxTabs,
    required this.onSelect,
    required this.onClose,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(tabs.length, (i) {
                  final isActive = i == activeIndex;
                  return GestureDetector(
                    onTap: () => onSelect(i),
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 100, maxWidth: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: isActive ? Colors.grey[800] : Colors.grey[900],
                        border: Border(
                          bottom: BorderSide(
                            color: isActive ? Colors.indigo : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              tabs[i].title,
                              style: TextStyle(
                                fontSize: 12,
                                color: isActive ? Colors.white : Colors.white54,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (tabs.length > 1) ...[
                            const SizedBox(width: 4),
                            InkWell(
                              onTap: () => onClose(i),
                              borderRadius: BorderRadius.circular(8),
                              child: const Icon(Icons.close, size: 14, color: Colors.white38),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
          if (tabs.length < maxTabs)
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              tooltip: '新建窗口',
              onPressed: onAdd,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Player window widget (one per tab)
// ─────────────────────────────────────────────

class _PlayerWindow extends StatefulWidget {
  final _TabData tab;
  final void Function(String url, String name)? onOpenInNewTab;
  final void Function(String url, String name) onOpenUrl;
  final VoidCallback onTabUpdated;

  const _PlayerWindow({
    super.key,
    required this.tab,
    required this.onOpenInNewTab,
    required this.onOpenUrl,
    required this.onTabUpdated,
  });

  @override
  State<_PlayerWindow> createState() => _PlayerWindowState();
}

class _PlayerWindowState extends State<_PlayerWindow> {
  bool _isDragging = false;
  double _dragPosition = 0;
  double? _seekingPosition;
  int _loop = 1;
  double _speed = 1.0;
  bool _isDragOver = false;
  bool _showSubtitlePanel = false;
  String _status = '准备就绪 - 选择文件或拖入视频开始播放';

  // ASR model paths
  static const String _defaultModelDir =
      '/Users/wangyaqiang/Downloads/sherpa-models/sherpa-onnx-streaming-paraformer-bilingual-zh-en';
  static const String _defaultVadModel =
      '/Users/wangyaqiang/Downloads/sherpa-models/silero-vad/silero_vad.onnx';
  static const String _defaultPunctModel =
      '/Users/wangyaqiang/Downloads/sherpa-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12/model.onnx';

  _TabData get _tab => widget.tab;
  FfplayPlayerController get _ctrl => _tab.controller;

  @override
  void initState() {
    super.initState();
    _ctrl.onStateChanged = (s) => setState(() => _status = 'State: ${s.name}');
    _ctrl.onStatsUpdated = _onStats;
    _ctrl.onError = (e) => setState(() => _status = 'Error: $e');
    // ASR async load completion callback
    _ctrl.onAsrReady = (success, error) {
      if (!mounted) return;
      setState(() {
        _tab.asrLoading = false;
        if (success) {
          _tab.asrEnabled = true;
          _status = 'ASR 已启用';
        } else {
          _tab.asrEnabled = false;
          _status = '❌ ASR 初始化失败: ${error ?? "unknown"}';
        }
      });
      widget.onTabUpdated();
    };
  }

  void _onStats(FfplayPlayerStats stats) {
    if (_seekingPosition != null && !stats.seeking) {
      if ((stats.position - _seekingPosition!).abs() < 1.0) {
        _seekingPosition = null;
      }
    }
    setState(() {});
  }

  // ── open url ──
  Future<void> _openUrl(String url, String name) async {
    setState(() {
      _seekingPosition = null;
      _isDragging = false;
      _dragPosition = 0;
      _status = name;
    });
    widget.onOpenUrl(url, name);
  }

  Future<void> _pickFile() async {
    const typeGroup = XTypeGroup(
      label: 'Media files',
      extensions: ['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v',
                    'mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a'],
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file != null) await _openUrl(file.path, file.name);
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      await _openUrl(data.text!, data.text!);
    }
  }

  void _play() async {
    if (_tab.currentUrl == null || _tab.currentUrl!.isEmpty) return;
    final url = _tab.currentUrl!;
    if (!url.startsWith('http') && !url.startsWith('rtmp') && !url.startsWith('rtsp')) {
      if (!await File(url).exists()) {
        setState(() => _status = '文件不存在');
        return;
      }
    }
    await _ctrl.setUrl(url);
    final ok = await _ctrl.play();
    setState(() => _status = ok ? '播放中' : '启动失败');
  }

  void _stop() {
    _ctrl.stop();
    setState(() => _status = '已停止');
  }

  void _pause() {
    _ctrl.pause();
    setState(() => _status = '已暂停');
  }

  void _resume() {
    _ctrl.resume();
    setState(() => _status = '播放中');
  }

  Future<void> _toggleAsr() async {
    if (_tab.asrLoading) return; // prevent double-tap while loading
    if (!_tab.asrEnabled) {
      // Kick off async model load — UI immediately shows loading state
      setState(() {
        _tab.asrLoading = true;
        _tab.currentSubtitle = '';
        _status = 'ASR 加载中...';
      });
      widget.onTabUpdated();
      // initAsr now returns immediately (async on native side).
      // Result comes back via onAsrReady callback registered in initState.
      await _ctrl.initAsr(
        _defaultModelDir,
        vadModel: _defaultVadModel,
        punctModel: _defaultPunctModel,
      );
    } else {
      await _ctrl.enableAsr(false);
      setState(() {
        _tab.asrEnabled = false;
        _tab.asrLoading = false;
        _tab.currentSubtitle = '';
        _status = 'ASR 已停用';
      });
      widget.onTabUpdated();
    }
  }

  // ── drop handler ──
  void _onDrop(List<String> paths) {
    if (paths.isEmpty) return;
    final first = paths.first;
    final name = first.split('/').last;
    _openUrl(first, name);
    // Extra files → new tabs
    if (widget.onOpenInNewTab != null) {
      for (int i = 1; i < paths.length; i++) {
        final p = paths[i];
        widget.onOpenInNewTab!(p, p.split('/').last);
      }
    }
  }

  // ── history dialog ──
  void _showHistory() {
    showDialog(
      context: context,
      builder: (_) => _HistoryDialog(
        onPlay: (item, resume) {
          Navigator.of(context).pop();
          _openUrl(item.url, item.displayName).then((_) {
            if (resume && item.lastPosition > 0) {
              Future.delayed(const Duration(milliseconds: 500), () {
                _ctrl.seek(item.lastPosition);
              });
            }
          });
        },
      ),
    );
  }

  // ── export SRT ──
  Future<void> _exportSrt() async {
    if (_tab.subtitleHistory.entries.isEmpty) return;
    final srt = _tab.subtitleHistory.toSrt();
    final saveFile = await openFile(
      acceptedTypeGroups: [const XTypeGroup(label: 'SRT', extensions: ['srt'])],
    );
    // file_selector doesn't support save dialog directly; use getSavePath if available
    // Fallback: write to Downloads
    final dir = Platform.environment['HOME'] ?? '.';
    final savePathFallback = '$dir/Downloads/${_tab.title}.srt';
    try {
      await File(savePathFallback).writeAsString(srt);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出: $savePathFallback')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e')),
        );
      }
    }
    // saveFile was shown as a fallback open-file dialog; unused in this flow
    debugPrint('SRT export: dialog result = ${saveFile?.name}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        title: Text(_status, style: const TextStyle(fontSize: 13)),
        toolbarHeight: 40,
        actions: [
          // Open file
          PopupMenuButton<String>(
            icon: const Icon(Icons.folder_open, size: 20),
            tooltip: '打开媒体',
            onSelected: (v) {
              if (v == 'file') _pickFile();
              if (v == 'clipboard') _pasteClipboard();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'file', child: ListTile(leading: Icon(Icons.folder), title: Text('打开文件...'))),
              PopupMenuItem(value: 'clipboard', child: ListTile(leading: Icon(Icons.content_paste), title: Text('粘贴 URL'))),
            ],
          ),
          // History
          IconButton(
            icon: const Icon(Icons.history, size: 20),
            tooltip: '播放历史',
            onPressed: _showHistory,
          ),
          // Subtitle panel toggle
          IconButton(
            icon: Icon(
              Icons.subtitles,
              size: 20,
              color: _showSubtitlePanel ? Colors.indigo[300] : Colors.white70,
            ),
            tooltip: '字幕记录',
            onPressed: () => setState(() => _showSubtitlePanel = !_showSubtitlePanel),
          ),
        ],
      ),
      body: Row(
        children: [
          // Main video + controls
          Expanded(
            child: Column(
              children: [
                // Video + subtitle overlay + drag-drop
                Expanded(
                  child: DropTarget(
                    onDragEntered: (_) => setState(() => _isDragOver = true),
                    onDragExited: (_) => setState(() => _isDragOver = false),
                    onDragDone: (detail) {
                      setState(() => _isDragOver = false);
                      final paths = detail.files.map((f) => f.path).toList();
                      _onDrop(paths);
                    },
                    child: Stack(
                      children: [
                        // Video player
                        _tab.currentUrl != null
                            ? FfplayPlayer(
                                controller: _ctrl,
                                url: _tab.currentUrl,
                                autoPlay: true,
                                backgroundColor: Colors.black,
                              )
                            : const Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.movie, size: 64, color: Colors.white24),
                                    SizedBox(height: 12),
                                    Text('拖入视频文件或点击打开', style: TextStyle(color: Colors.white38)),
                                  ],
                                ),
                              ),

                        // Drag-over overlay
                        if (_isDragOver)
                          Container(
                            color: Colors.indigo.withOpacity(0.35),
                            child: const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.video_file, size: 72, color: Colors.white),
                                  SizedBox(height: 12),
                                  Text('松开以播放', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                          ),

                        // ASR subtitle overlay
                        if (_tab.asrEnabled && _tab.currentSubtitle.isNotEmpty)
                          Positioned(
                            bottom: 24,
                            left: 40,
                            right: 40,
                            child: Center(
                              child: Container(
                                constraints: const BoxConstraints(maxWidth: 720),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.75),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  _tab.currentSubtitle,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    height: 1.4,
                                    fontWeight: FontWeight.w500,
                                    shadows: [Shadow(offset: Offset(1, 1), blurRadius: 3, color: Colors.black)],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                // Control bar
                _ControlBar(
                  controller: _ctrl,
                  loop: _loop,
                  speed: _speed,
                  asrEnabled: _tab.asrEnabled,
                  asrLoading: _tab.asrLoading,
                  isDragging: _isDragging,
                  dragPosition: _dragPosition,
                  seekingPosition: _seekingPosition,
                  onPlay: _play,
                  onPause: _pause,
                  onResume: _resume,
                  onStop: _stop,
                  onSeek: (v) {
                    setState(() { _seekingPosition = v; _isDragging = false; });
                    _ctrl.seek(v);
                  },
                  onDragStart: (v) => setState(() { _isDragging = true; _dragPosition = v; }),
                  onDragUpdate: (v) => setState(() => _dragPosition = v),
                  onVolume: (v) => _ctrl.setVolume(v.toInt()),
                  onMute: () => _ctrl.setMute(!_ctrl.muted),
                  onLoop: () {
                    setState(() => _loop = _loop == 1 ? 0 : 1);
                    _ctrl.setLoop(_loop);
                  },
                  onSpeed: (v) {
                    setState(() => _speed = v);
                    _ctrl.setSpeed(v);
                  },
                  onAsr: _toggleAsr,
                  onSeekRelative: (d) => _ctrl.seekRelative(d),
                ),
              ],
            ),
          ),

          // Subtitle history panel
          if (_showSubtitlePanel)
            _SubtitlePanel(
              history: _tab.subtitleHistory,
              controller: _ctrl,
              onExportSrt: _exportSrt,
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Control bar
// ─────────────────────────────────────────────

class _ControlBar extends StatelessWidget {
  final FfplayPlayerController controller;
  final int loop;
  final double speed;
  final bool asrEnabled;
  final bool asrLoading;
  final bool isDragging;
  final double dragPosition;
  final double? seekingPosition;
  final VoidCallback onPlay, onPause, onResume, onStop, onMute, onLoop, onAsr;
  final void Function(double) onSeek, onDragStart, onDragUpdate, onVolume, onSpeed;
  final void Function(double) onSeekRelative;

  const _ControlBar({
    required this.controller,
    required this.loop,
    required this.speed,
    required this.asrEnabled,
    required this.asrLoading,
    required this.isDragging,
    required this.dragPosition,
    required this.seekingPosition,
    required this.onPlay,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    required this.onSeek,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onVolume,
    required this.onMute,
    required this.onLoop,
    required this.onSpeed,
    required this.onAsr,
    required this.onSeekRelative,
  });

  @override
  Widget build(BuildContext context) {
    final dur = controller.duration;
    final pos = isDragging
        ? dragPosition
        : (seekingPosition ?? controller.position);

    return Container(
      color: Colors.grey[900],
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Progress slider
          if (dur > 0)
            Row(
              children: [
                Text(formatDuration(pos), style: const TextStyle(fontSize: 11, color: Colors.white70)),
                Expanded(
                  child: Slider(
                    value: pos.clamp(0.0, dur),
                    max: dur,
                    onChangeStart: onDragStart,
                    onChanged: onDragUpdate,
                    onChangeEnd: onSeek,
                  ),
                ),
                Text(formatDuration(dur), style: const TextStyle(fontSize: 11, color: Colors.white70)),
              ],
            ),
          // Buttons row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(icon: const Icon(Icons.replay_30), iconSize: 24, tooltip: '-30s', onPressed: () => onSeekRelative(-30)),
              IconButton(icon: const Icon(Icons.replay_10), iconSize: 24, tooltip: '-10s', onPressed: () => onSeekRelative(-10)),
              IconButton(icon: const Icon(Icons.stop), iconSize: 28, color: Colors.red, onPressed: onStop),
              _playPauseButton(),
              IconButton(icon: const Icon(Icons.forward_10), iconSize: 24, tooltip: '+10s', onPressed: () => onSeekRelative(10)),
              IconButton(icon: const Icon(Icons.forward_30), iconSize: 24, tooltip: '+30s', onPressed: () => onSeekRelative(30)),
              const SizedBox(width: 16),
              // Volume
              IconButton(
                icon: Icon(controller.muted ? Icons.volume_off : Icons.volume_up),
                tooltip: controller.muted ? '取消静音' : '静音',
                onPressed: onMute,
              ),
              SizedBox(
                width: 80,
                child: Slider(
                  value: controller.volume.toDouble(),
                  min: 0, max: 100,
                  onChanged: (v) => onVolume(v),
                ),
              ),
              Text('${controller.volume}%', style: const TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(width: 12),
              // ASR
              if (asrLoading)
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: Padding(
                    padding: EdgeInsets.all(10),
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.indigo),
                  ),
                )
              else
                IconButton(
                  icon: Icon(Icons.closed_caption,
                      color: asrEnabled ? Colors.indigo[300] : Colors.white38),
                  tooltip: asrEnabled ? '关闭字幕' : '开启字幕 (ASR)',
                  onPressed: onAsr,
                ),
              // Loop
              IconButton(
                icon: Icon(loop == 0 ? Icons.repeat : Icons.repeat_one,
                    color: loop == 0 ? Colors.green : Colors.white54),
                tooltip: loop == 0 ? 'Loop: ON' : 'Loop: OFF',
                onPressed: onLoop,
              ),
              // Speed
              const Text('速度:', style: TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(width: 4),
              DropdownButton<double>(
                value: speed,
                dropdownColor: Colors.grey[900],
                underline: const SizedBox(),
                style: const TextStyle(fontSize: 11, color: Colors.white70),
                items: const [
                  DropdownMenuItem(value: 0.5, child: Text('0.5x')),
                  DropdownMenuItem(value: 0.75, child: Text('0.75x')),
                  DropdownMenuItem(value: 1.0, child: Text('1.0x')),
                  DropdownMenuItem(value: 1.25, child: Text('1.25x')),
                  DropdownMenuItem(value: 1.5, child: Text('1.5x')),
                  DropdownMenuItem(value: 2.0, child: Text('2.0x')),
                ],
                onChanged: (v) { if (v != null) onSpeed(v); },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _playPauseButton() {
    if (controller.state == FfplayPlayerState.playing) {
      return IconButton(icon: const Icon(Icons.pause), iconSize: 36, color: Colors.white, onPressed: onPause);
    } else if (controller.state == FfplayPlayerState.paused) {
      return IconButton(icon: const Icon(Icons.play_arrow), iconSize: 36, color: Colors.green, onPressed: onResume);
    } else {
      return IconButton(icon: const Icon(Icons.play_arrow), iconSize: 36, color: Colors.green, onPressed: onPlay);
    }
  }
}

// ─────────────────────────────────────────────
// Subtitle history panel (right sidebar)
// ─────────────────────────────────────────────

class _SubtitlePanel extends StatefulWidget {
  final SubtitleHistory history;
  final FfplayPlayerController controller;
  final Future<void> Function() onExportSrt;

  const _SubtitlePanel({
    required this.history,
    required this.controller,
    required this.onExportSrt,
  });

  @override
  State<_SubtitlePanel> createState() => _SubtitlePanelState();
}

class _SubtitlePanelState extends State<_SubtitlePanel> {
  final ScrollController _scroll = ScrollController();
  bool _autoScroll = true;

  @override
  void didUpdateWidget(_SubtitlePanel old) {
    super.didUpdateWidget(old);
    if (_autoScroll && _scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.history.entries;
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: Colors.grey[850],
        border: const Border(left: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.grey[800],
            child: Row(
              children: [
                const Text('字幕记录', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const Spacer(),
                // Auto-scroll toggle
                Tooltip(
                  message: _autoScroll ? '关闭自动滚动' : '开启自动滚动',
                  child: IconButton(
                    icon: Icon(_autoScroll ? Icons.vertical_align_bottom : Icons.list,
                        size: 16,
                        color: _autoScroll ? Colors.indigo[300] : Colors.white54),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    onPressed: () => setState(() => _autoScroll = !_autoScroll),
                  ),
                ),
                // Export SRT
                Tooltip(
                  message: '导出 SRT',
                  child: IconButton(
                    icon: const Icon(Icons.download, size: 16, color: Colors.white54),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    onPressed: widget.onExportSrt,
                  ),
                ),
                // Clear
                Tooltip(
                  message: '清空记录',
                  child: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 16, color: Colors.white38),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    onPressed: () => setState(() => widget.history.clear()),
                  ),
                ),
              ],
            ),
          ),
          // Entry list
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text('暂无字幕记录', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: entries.length,
                    itemBuilder: (_, i) {
                      final e = entries[i];
                      final isCurrentish = (widget.controller.position - e.positionS).abs() < 3.0;
                      return InkWell(
                        onTap: () => widget.controller.seek(e.positionS),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: isCurrentish ? Colors.indigo.withOpacity(0.15) : null,
                            border: const Border(bottom: BorderSide(color: Colors.white10)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                formatDuration(e.positionS),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: isCurrentish ? Colors.indigo[300] : Colors.white38,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                e.text,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isCurrentish ? Colors.white : Colors.white70,
                                ),
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
    );
  }
}

// ─────────────────────────────────────────────
// History dialog
// ─────────────────────────────────────────────

class _HistoryDialog extends StatefulWidget {
  final void Function(HistoryItem item, bool resume) onPlay;

  const _HistoryDialog({required this.onPlay});

  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  @override
  Widget build(BuildContext context) {
    final items = HistoryStore.instance.items;
    return Dialog(
      backgroundColor: Colors.grey[850],
      child: SizedBox(
        width: 560,
        height: 480,
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Text('播放历史', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      HistoryStore.instance.clear();
                      setState(() {});
                    },
                    child: const Text('清空全部', style: TextStyle(color: Colors.red)),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // List
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('暂无历史记录', style: TextStyle(color: Colors.white38)))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final item = items[i];
                        return ListTile(
                          leading: const Icon(Icons.movie_outlined, color: Colors.white38),
                          title: Text(item.displayName, style: const TextStyle(fontSize: 13)),
                          subtitle: Text(
                            '${_formatDateTime(item.playedAt)}  ${item.progressText}',
                            style: const TextStyle(fontSize: 11, color: Colors.white38),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (item.lastPosition > 0) ...[
                                TextButton(
                                  onPressed: () => widget.onPlay(item, true),
                                  child: Text('续播 ${formatDuration(item.lastPosition)}',
                                      style: const TextStyle(fontSize: 11)),
                                ),
                              ],
                              TextButton(
                                onPressed: () => widget.onPlay(item, false),
                                child: const Text('从头播放', style: TextStyle(fontSize: 11)),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, size: 16, color: Colors.white38),
                                onPressed: () {
                                  HistoryStore.instance.remove(item.url);
                                  setState(() {});
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}-${dt.day}';
  }
}

// ─────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────

String formatDuration(double seconds) {
  if (seconds.isNaN || seconds.isInfinite || seconds < 0) return '00:00';
  final d = Duration(seconds: seconds.toInt());
  String p(int n) => n.toString().padLeft(2, '0');
  if (d.inHours > 0) return '${p(d.inHours)}:${p(d.inMinutes.remainder(60))}:${p(d.inSeconds.remainder(60))}';
  return '${p(d.inMinutes)}:${p(d.inSeconds.remainder(60))}';
}
