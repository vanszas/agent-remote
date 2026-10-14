import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'agent_remote_connector.dart';
import 'app_controller.dart';

class ScreenRemotePage extends StatefulWidget {
  const ScreenRemotePage({
    super.key,
    required this.app,
    required this.remote,
    this.isTab = false,
  });

  final AppController app;
  final AgentRemoteConnector remote;
  final bool isTab;

  @override
  State<ScreenRemotePage> createState() => _ScreenRemotePageState();
}

class _ScreenRemotePageState extends State<ScreenRemotePage> {
  Uint8List? _currentFrame;
  bool _isPlaying = true;
  bool _isLoading = true;
  bool _isFullscreen = false;
  bool _showShortcuts = true;
  bool _showTrackpad = false;
  final bool _showVirtualCursor = true;
  Offset _virtualCursor = const Offset(0.5, 0.5);
  Offset _trackpadPos = const Offset(20, 140);
  String _resolution = '720p';
  String _profile = 'seimbang';
  String _monitor = 'primary';
  List<Map<String, Object?>> _monitors = [];
  double _aspectRatio = 16 / 9;
  int _fps = 0;
  int _framesRendered = 0;
  DateTime _lastFpsCheck = DateTime.now();
  String? _error;
  bool _isDisposed = false;
  final GlobalKey _viewportKey = GlobalKey();
  final FocusNode _imeFocusNode = FocusNode();
  final TextEditingController _imeController =
      TextEditingController(text: '\u200B');
  List<Map<String, String>> _shortcuts = [
    {'label': 'Save', 'key': 'Ctrl+S'},
    {'label': 'Desktop', 'key': 'Win+D'},
    {'label': 'Tab', 'key': 'Alt+Tab'},
    {'label': 'Close', 'key': 'Alt+F4'},
    {'label': 'Undo', 'key': 'Ctrl+Z'},
    {'label': 'TaskMgr', 'key': 'Ctrl+Shift+Esc'},
    {'label': 'Refresh', 'key': 'F5'},
    {'label': 'Copy', 'key': 'Ctrl+C'},
    {'label': 'Paste', 'key': 'Ctrl+V'},
  ];

  @override
  void initState() {
    super.initState();
    _loadScreenInfo();
    _loadCustomShortcuts();
    _startStreamLoop();
  }

  Future<void> _loadCustomShortcuts() async {
    try {
      final list = await widget.remote.getCustomShortcuts();
      if (list.isNotEmpty && mounted) {
        setState(() {
          _shortcuts = list;
        });
      }
    } catch (_) {}
  }

  void _toggleFullscreen() {
    setState(() {
      _isFullscreen = !_isFullscreen;
      if (_isFullscreen) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    });
  }

  void _triggerShortcut(String key) {
    HapticFeedback.lightImpact();
    widget.remote.sendHotkey(key).catchError((_) => <String, Object?>{});
  }

  void _showAddShortcutDialog() {
    final labelCtrl = TextEditingController();
    final keyCtrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tambah Shortcut PC'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: labelCtrl,
              decoration: const InputDecoration(
                labelText: 'Label (misal: Build)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: keyCtrl,
              decoration: const InputDecoration(
                labelText: 'Kombinasi Key (misal: Ctrl+B atau Ctrl+Shift+B)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () {
              final label = labelCtrl.text.trim();
              final key = keyCtrl.text.trim();
              if (label.isNotEmpty && key.isNotEmpty) {
                final updated = List<Map<String, String>>.from(_shortcuts);
                updated.add({'label': label, 'key': key});
                setState(() => _shortcuts = updated);
                widget.remote.saveCustomShortcuts(updated).catchError((_) => updated);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadScreenInfo() async {
    try {
      final info = await widget.remote.getScreenInfo();
      final raw = info['monitors'] as List?;
      if (raw != null && mounted) {
        setState(() {
          _monitors = raw
              .whereType<Map>()
              .map((m) => Map<String, Object?>.from(m))
              .toList();
          _updateAspectRatio();
        });
      }
    } catch (_) {}
  }

  void _updateAspectRatio() {
    for (final m in _monitors) {
      if (m['id'] == _monitor) {
        final w = (m['width'] as num?)?.toDouble() ?? 1920;
        final h = (m['height'] as num?)?.toDouble() ?? 1080;
        if (h > 0) {
          _aspectRatio = w / h;
          return;
        }
      }
    }
    if (_monitor == 'virtual' || _monitor == 'all') {
      _aspectRatio = 3000 / 1920;
    } else {
      _aspectRatio = 16 / 9;
    }
  }

  String get _currentMonitorLabel {
    for (final m in _monitors) {
      if (m['id'] == _monitor) {
        return m['name']?.toString() ?? _monitor.toUpperCase();
      }
    }
    if (_monitor == 'primary') return 'Monitor 1 (Utama)';
    if (_monitor == 'virtual' || _monitor == 'all') return 'Semua Layar';
    return _monitor.toUpperCase();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _imeFocusNode.dispose();
    _imeController.dispose();
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  Widget _buildHiddenImeField() {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 70,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: !_imeActive
            ? const SizedBox.shrink()
            : Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(12),
                color: const Color(0xFF1E1E2E).withValues(alpha: 0.95),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              focusNode: _imeFocusNode,
                              controller: _imeController,
                              style: const TextStyle(color: Colors.white, fontSize: 14),
                              decoration: const InputDecoration(
                                hintText: 'Ketik teks / perintah untuk PC...',
                                hintStyle: TextStyle(color: Colors.white54, fontSize: 13),
                                isDense: true,
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(vertical: 8),
                              ),
                              textInputAction: TextInputAction.send,
                              onSubmitted: (val) {
                                if (val.isNotEmpty) {
                                  _sendInput(action: 'key', text: val);
                                  _sendInput(action: 'key', key: 'Enter');
                                  _imeController.clear();
                                }
                              },
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.backspace_outlined, size: 20, color: Colors.white70),
                            tooltip: 'Backspace',
                            onPressed: () => _sendInput(action: 'key', key: 'Backspace'),
                          ),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              backgroundColor: const Color(0xFF6366F1),
                            ),
                            icon: const Icon(Icons.send, size: 16),
                            label: const Text('Kirim', style: TextStyle(fontSize: 12)),
                            onPressed: () {
                              final text = _imeController.text;
                              if (text.isNotEmpty) {
                                _sendInput(action: 'key', text: text);
                                _imeController.clear();
                              }
                            },
                          ),
                        ],
                      ),
                      const Divider(color: Colors.white12, height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _buildQuickKeyPill('Enter', 'Enter'),
                            _buildQuickKeyPill('Tab', 'Tab'),
                            _buildQuickKeyPill('Esc', 'Escape'),
                            _buildQuickKeyPill('Space', 'Space'),
                            _buildQuickKeyPill('Ctrl+C', 'ctrl+c', isHotkey: true),
                            _buildQuickKeyPill('Ctrl+V', 'ctrl+v', isHotkey: true),
                            _buildQuickKeyPill('Ctrl+Z', 'ctrl+z', isHotkey: true),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildQuickKeyPill(String label, String key, {bool isHotkey = false}) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          HapticFeedback.lightImpact();
          if (isHotkey) {
            widget.remote.sendHotkey(key).catchError((_) => <String, Object?>{});
          } else {
            _sendInput(action: 'key', key: key);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white24, width: 0.8),
          ),
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
          ),
        ),
      ),
    );
  }

  bool _imeActive = false;

  void _toggleNativeKeyboard() {
    setState(() {
      _imeActive = !_imeActive;
    });
    if (_imeActive) {
      _imeFocusNode.requestFocus();
    } else {
      _imeFocusNode.unfocus();
    }
  }

  Future<void> _startStreamLoop() async {
    while (!_isDisposed) {
      if (!_isPlaying) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }
      try {
        final frame = await widget.remote.getScreenFrame(
          resolution: _resolution,
          quality: _profile == 'hemat' ? 50 : (_profile == 'seimbang' ? 75 : (_profile == 'tajam' ? 88 : 95)),
          monitor: _monitor,
          profile: _profile,
        );
        if (_isDisposed) break;

        _framesRendered++;
        final now = DateTime.now();
        final diff = now.difference(_lastFpsCheck).inMilliseconds;
        if (diff >= 1000) {
          if (mounted) {
            setState(() {
              _fps = (_framesRendered * 1000 ~/ diff);
              _framesRendered = 0;
              _lastFpsCheck = now;
            });
          }
        }

        if (mounted) {
          setState(() {
            _currentFrame = frame;
            _isLoading = false;
            _error = null;
          });
        }
      } catch (err) {
        if (_isDisposed) break;
        if (mounted) {
          setState(() {
            _error = err.toString();
            _isLoading = false;
          });
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    }
  }

  void _sendInput({
    required String action,
    double x = 0.0,
    double y = 0.0,
    String button = 'left',
    int delta = 0,
    String key = '',
    String text = '',
  }) {
    final finalKey = text.isNotEmpty ? text : key;
    widget.remote.sendScreenInput(
      action: action,
      x: x.clamp(0.0, 1.0),
      y: y.clamp(0.0, 1.0),
      button: button,
      delta: delta,
      key: finalKey,
      monitor: _monitor,
    ).catchError((err) {
      debugPrint('[SCREEN_INPUT_ERR] $err');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal input: $err'),
            duration: const Duration(seconds: 1),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return <String, Object?>{};
    });
  }

  Offset? _normalizeCoordinates(Offset globalPos) {
    final renderBox =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return null;
    final localPos = renderBox.globalToLocal(globalPos);
    final size = renderBox.size;
    if (size.width <= 0 || size.height <= 0) return null;

    final containerAspect = size.width / size.height;
    final imageAspect = _aspectRatio;

    double imgW = size.width;
    double imgH = size.height;
    double padX = 0.0;
    double padY = 0.0;

    if (containerAspect > imageAspect) {
      imgW = size.height * imageAspect;
      padX = (size.width - imgW) / 2.0;
    } else {
      imgH = size.width / imageAspect;
      padY = (size.height - imgH) / 2.0;
    }

    if (imgW <= 0 || imgH <= 0) return null;

    final nx = ((localPos.dx - padX) / imgW).clamp(0.0, 1.0);
    final ny = ((localPos.dy - padY) / imgH).clamp(0.0, 1.0);
    return Offset(nx, ny);
  }

  Widget _buildShortcutBar(ColorScheme colors) {
    return Container(
      color: _isFullscreen
          ? Colors.black.withValues(alpha: 0.45)
          : colors.surfaceContainerHighest.withValues(alpha: 0.95),
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          // Skill quick chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: ActionChip(
              avatar: const Icon(Icons.forum_outlined, size: 14),
              label: const Text('/debate', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              onPressed: () {
                HapticFeedback.lightImpact();
                _sendInput(action: 'type', text: '/debate ');
              },
              padding: const EdgeInsets.symmetric(horizontal: 6),
              visualDensity: VisualDensity.compact,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: ActionChip(
              avatar: const Icon(Icons.psychology_outlined, size: 14),
              label: const Text('/fable-mind', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              onPressed: () {
                HapticFeedback.lightImpact();
                _sendInput(action: 'type', text: '/fable-mind ');
              },
              padding: const EdgeInsets.symmetric(horizontal: 6),
              visualDensity: VisualDensity.compact,
            ),
          ),
          for (final s in _shortcuts)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: ActionChip(
                label: Text(
                  s['label'] ?? s['key'] ?? '',
                  style: const TextStyle(fontSize: 11),
                ),
                onPressed: () => _triggerShortcut(s['key'] ?? ''),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                visualDensity: VisualDensity.compact,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: IconButton(
              tooltip: 'Tambah Shortcut',
              icon: const Icon(Icons.add_circle_outline, size: 20),
              onPressed: _showAddShortcutDialog,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFloatingTrackpad(ColorScheme colors) {
    return Positioned(
      left: _trackpadPos.dx,
      top: _trackpadPos.dy,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: Colors.black.withValues(alpha: 0.85),
        child: Container(
          width: 220,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: colors.primary.withValues(alpha: 0.4),
              width: 1.2,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onPanUpdate: (details) {
                  setState(() {
                    _trackpadPos += details.delta;
                  });
                },
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest.withValues(alpha: 0.6),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.drag_indicator, size: 16, color: Colors.white70),
                      const SizedBox(width: 4),
                      const Text(
                        'Trackpad',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Tutup Trackpad',
                        icon: const Icon(Icons.close, size: 16, color: Colors.white70),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () {
                          setState(() {
                            _showTrackpad = false;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
              GestureDetector(
                onPanUpdate: (details) {
                  final dx = details.delta.dx * 0.003;
                  final dy = details.delta.dy * 0.003;
                  setState(() {
                    _virtualCursor = Offset(
                      (_virtualCursor.dx + dx).clamp(0.0, 1.0),
                      (_virtualCursor.dy + dy).clamp(0.0, 1.0),
                    );
                  });
                  _sendInput(
                    action: 'move',
                    x: _virtualCursor.dx,
                    y: _virtualCursor.dy,
                  );
                },
                onTap: () {
                  HapticFeedback.selectionClick();
                  _sendInput(
                    action: 'click',
                    x: _virtualCursor.dx,
                    y: _virtualCursor.dy,
                    button: 'left',
                  );
                },
                onDoubleTap: () {
                  HapticFeedback.lightImpact();
                  _sendInput(
                    action: 'double_click',
                    x: _virtualCursor.dx,
                    y: _virtualCursor.dy,
                  );
                },
                onLongPress: () {
                  HapticFeedback.mediumImpact();
                  _sendInput(
                    action: 'rclick',
                    x: _virtualCursor.dx,
                    y: _virtualCursor.dy,
                    button: 'right',
                  );
                },
                child: Container(
                  height: 100,
                  width: double.infinity,
                  margin: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.touch_app_outlined,
                          size: 26,
                          color: Colors.white.withValues(alpha: 0.25),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Swipe: Gerak • Tap: Klik\nLong-press: Klik R',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 9,
                            color: Colors.white.withValues(alpha: 0.45),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 6, right: 6, bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          minimumSize: const Size(0, 28),
                          side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                        ),
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          _sendInput(
                            action: 'click',
                            x: _virtualCursor.dx,
                            y: _virtualCursor.dy,
                            button: 'left',
                          );
                        },
                        child: const Text('Klik L', style: TextStyle(fontSize: 11, color: Colors.white)),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          minimumSize: const Size(0, 28),
                          side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                        ),
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          _sendInput(
                            action: 'rclick',
                            x: _virtualCursor.dx,
                            y: _virtualCursor.dy,
                            button: 'right',
                          );
                        },
                        child: const Text('Klik R', style: TextStyle(fontSize: 11, color: Colors.white)),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Scroll Naik',
                      icon: const Icon(Icons.arrow_upward, size: 16, color: Colors.white70),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      onPressed: () => _sendInput(action: 'scroll', delta: 120),
                    ),
                    IconButton(
                      tooltip: 'Scroll Turun',
                      icon: const Icon(Icons.arrow_downward, size: 16, color: Colors.white70),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      onPressed: () => _sendInput(action: 'scroll', delta: -120),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final screenStream = LayoutBuilder(
      builder: (ctx, constraints) {
        return GestureDetector(
          onTapDown: (details) {
            final norm =
                _normalizeCoordinates(details.globalPosition);
            if (norm != null) {
              setState(() => _virtualCursor = norm);
              _sendInput(
                action: 'click',
                x: norm.dx,
                y: norm.dy,
              );
            }
          },
          onDoubleTapDown: (details) {
            final norm =
                _normalizeCoordinates(details.globalPosition);
            if (norm != null) {
              setState(() => _virtualCursor = norm);
              _sendInput(
                action: 'double_click',
                x: norm.dx,
                y: norm.dy,
              );
            }
          },
          onLongPressStart: (details) {
            final norm =
                _normalizeCoordinates(details.globalPosition);
            if (norm != null) {
              setState(() => _virtualCursor = norm);
              HapticFeedback.mediumImpact();
              _sendInput(
                action: 'rclick',
                x: norm.dx,
                y: norm.dy,
              );
            }
          },
          onPanUpdate: (details) {
            final norm =
                _normalizeCoordinates(details.globalPosition);
            if (norm != null) {
              setState(() => _virtualCursor = norm);
              _sendInput(
                action: 'move',
                x: norm.dx,
                y: norm.dy,
              );
            }
          },
          child: InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: Center(
              child: AspectRatio(
                aspectRatio: _aspectRatio,
                child: LayoutBuilder(
                  builder: (ctx, aspectConstraints) {
                    final w = aspectConstraints.maxWidth;
                    final h = aspectConstraints.maxHeight;
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: Image.memory(
                            _currentFrame!,
                            key: _viewportKey,
                            gaplessPlayback: true,
                            fit: BoxFit.fill,
                          ),
                        ),
                        // Client-side Virtual Cursor Overlay (Computer Use Style)
                        if (_showVirtualCursor)
                          Positioned(
                            left: (_virtualCursor.dx * w).clamp(0.0, w) - 2,
                            top: (_virtualCursor.dy * h).clamp(0.0, h) - 2,
                            child: IgnorePointer(
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Positioned(
                                    left: 1,
                                    top: 1,
                                    child: Transform.rotate(
                                      angle: -0.6,
                                      child: Icon(
                                        Icons.navigation,
                                        size: 22,
                                        color: Colors.black.withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ),
                                  Transform.rotate(
                                    angle: -0.6,
                                    child: const Icon(
                                      Icons.navigation,
                                      size: 20,
                                      color: Color(0xFFFF9100),
                                    ),
                                  ),
                                  Positioned(
                                    left: 2,
                                    top: 2,
                                    child: Container(
                                      width: 4,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.orange.withValues(alpha: 0.8),
                                            blurRadius: 4,
                                            spreadRadius: 2,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );

    if (_isFullscreen) {
      return Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: _error != null
                  ? Center(
                      child: Text(
                        'Gagal memuat layar: $_error',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    )
                  : (_isLoading && _currentFrame == null)
                      ? const Center(child: CircularProgressIndicator())
                      : screenStream,
            ),
            // Floating exit fullscreen button
            Positioned(
              top: 16,
              right: 16,
              child: SafeArea(
                child: IconButton.filledTonal(
                  tooltip: 'Keluar Layar Penuh',
                  icon: const Icon(Icons.fullscreen_exit),
                  onPressed: _toggleFullscreen,
                ),
              ),
            ),
            // Floating Trackpad in Fullscreen
            if (_showTrackpad) _buildFloatingTrackpad(colors),
            // Floating translucent shortcut & tool bar at bottom
            if (_showShortcuts)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildShortcutBar(colors),
                      Container(
                        color: Colors.black.withValues(alpha: 0.45),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            IconButton(
                              tooltip: _showTrackpad ? 'Tutup Trackpad' : 'Trackpad Melayang',
                              icon: Icon(
                                Icons.mouse,
                                size: 20,
                                color: _showTrackpad ? Colors.orangeAccent : Colors.white,
                              ),
                              onPressed: () => setState(() => _showTrackpad = !_showTrackpad),
                            ),
                            IconButton(
                              tooltip: 'Klik Kiri',
                              icon: const Icon(Icons.mouse_outlined, size: 20, color: Colors.white),
                              onPressed: () => _sendInput(action: 'click', button: 'left'),
                            ),
                            IconButton(
                              tooltip: 'Klik Kanan',
                              icon: const Icon(Icons.touch_app_outlined, size: 20, color: Colors.white),
                              onPressed: () => _sendInput(action: 'rclick', button: 'right'),
                            ),
                            IconButton(
                              tooltip: 'Scroll Naik',
                              icon: const Icon(Icons.arrow_upward_outlined, size: 20, color: Colors.white),
                              onPressed: () => _sendInput(action: 'scroll', delta: 120),
                            ),
                            IconButton(
                              tooltip: 'Scroll Turun',
                              icon: const Icon(Icons.arrow_downward_outlined, size: 20, color: Colors.white),
                              onPressed: () => _sendInput(action: 'scroll', delta: -120),
                            ),
                            IconButton(
                              tooltip: 'Ketik Teks (Native Keyboard)',
                              icon: const Icon(Icons.keyboard_outlined, size: 20, color: Colors.white),
                              onPressed: _toggleNativeKeyboard,
                            ),
                            IconButton(
                              tooltip: 'Enter',
                              icon: const Icon(Icons.keyboard_return_outlined, size: 20, color: Colors.white),
                              onPressed: () => _sendInput(action: 'key', key: 'Enter'),
                            ),
                            IconButton(
                              tooltip: 'Esc',
                              icon: const Icon(Icons.cancel_outlined, size: 20, color: Colors.white),
                              onPressed: () => _sendInput(action: 'key', key: 'Escape'),
                            ),
                            IconButton(
                              tooltip: 'Fokus Monitor (Sembunyikan Toolbar)',
                              icon: const Icon(Icons.keyboard_arrow_down, size: 20, color: Colors.white70),
                              onPressed: () => setState(() => _showShortcuts = false),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            // Floating pill button to restore shortcuts when hidden
            if (!_showShortcuts)
              Positioned(
                bottom: 16,
                left: 16,
                child: SafeArea(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton.filledTonal(
                        tooltip: 'Buka Toolbar & Shortcut',
                        icon: const Icon(Icons.tune),
                        onPressed: () => setState(() => _showShortcuts = true),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: 'Buka/Tutup Keyboard HP',
                        icon: const Icon(Icons.keyboard),
                        onPressed: _toggleNativeKeyboard,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.black,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.isTab,
        backgroundColor: colors.surfaceContainerHighest,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Remote PC Screen', style: TextStyle(fontSize: 16)),
            Text(
              '$_currentMonitorLabel • $_resolution • $_fps FPS',
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          // Bitrate & Quality Profile selector
          PopupMenuButton<String>(
            tooltip: 'Profil Bitrate & Kualitas',
            icon: const Icon(Icons.speed_outlined, size: 20),
            initialValue: _profile,
            onSelected: (val) {
              setState(() {
                _profile = val;
                if (val == 'hemat') _resolution = '540p';
                if (val == 'seimbang') _resolution = '720p';
                if (val == 'tajam') _resolution = '1080p';
                if (val == 'ultra') _resolution = 'native';
              });
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'hemat',
                child: Text('Hemat (540p • 15 FPS • 800 Kbps)'),
              ),
              const PopupMenuItem(
                value: 'seimbang',
                child: Text('Seimbang (720p • 24 FPS • 2.5 Mbps)'),
              ),
              const PopupMenuItem(
                value: 'tajam',
                child: Text('Tajam (1080p • 30 FPS • 6.0 Mbps)'),
              ),
              const PopupMenuItem(
                value: 'ultra',
                child: Text('Ultra Native (Asli 1:1 • 30 FPS • Q95)'),
              ),
            ],
          ),
          // Resolution selector
          PopupMenuButton<String>(
            tooltip: 'Pilih Resolusi',
            icon: const Icon(Icons.settings_overscan_outlined, size: 20),
            initialValue: _resolution,
            onSelected: (val) {
              setState(() {
                _resolution = val;
              });
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: '540p',
                child: Text('540p (Hemat Kuota)'),
              ),
              const PopupMenuItem(
                value: '720p',
                child: Text('720p (Seimbang)'),
              ),
              const PopupMenuItem(
                value: '1080p',
                child: Text('1080p (Tajam)'),
              ),
              const PopupMenuItem(
                value: 'native',
                child: Text('Native Unscaled (Pixel Sempurna)'),
              ),
            ],
          ),
          // Monitor selector
          PopupMenuButton<String>(
            tooltip: 'Pilih Layar PC',
            icon: const Icon(Icons.monitor_outlined, size: 20),
            initialValue: _monitor,
            onSelected: (val) {
              setState(() {
                _monitor = val;
                _updateAspectRatio();
              });
            },
            itemBuilder: (ctx) {
              if (_monitors.isEmpty) {
                return const [
                  PopupMenuItem(
                    value: 'primary',
                    child: Text('Monitor 1 (Utama)'),
                  ),
                  PopupMenuItem(
                    value: 'monitor_2',
                    child: Text('Monitor 2'),
                  ),
                  PopupMenuItem(
                    value: 'all',
                    child: Text('Semua Layar / Dual Screen'),
                  ),
                ];
              }
              return _monitors.map((m) {
                final id = m['id']?.toString() ?? 'primary';
                final name = m['name']?.toString() ?? id;
                return PopupMenuItem(
                  value: id,
                  child: Text(name),
                );
              }).toList();
            },
          ),
          // Trackpad toggle
          IconButton(
            tooltip: _showTrackpad ? 'Tutup Trackpad' : 'Trackpad Melayang',
            icon: Icon(
              Icons.mouse,
              color: _showTrackpad ? colors.primary : null,
            ),
            onPressed: () {
              setState(() {
                _showTrackpad = !_showTrackpad;
              });
            },
          ),
          // Shortcut Bar / Focus Monitor toggle
          IconButton(
            tooltip: _showShortcuts ? 'Fokus Monitor (Sembunyikan Toolbar)' : 'Tampilkan Toolbar',
            icon: Icon(
              _showShortcuts ? Icons.subtitles : Icons.subtitles_off_outlined,
            ),
            onPressed: () {
              setState(() {
                _showShortcuts = !_showShortcuts;
              });
            },
          ),
          // Fullscreen toggle
          IconButton(
            tooltip: 'Layar Penuh (Fullscreen)',
            icon: const Icon(Icons.fullscreen),
            onPressed: _toggleFullscreen,
          ),
          // Play/Pause stream
          IconButton(
            tooltip: _isPlaying ? 'Jeda Stream' : 'Lanjutkan Stream',
            icon: Icon(
              _isPlaying ? Icons.pause_circle_outline : Icons.play_circle_outline,
            ),
            onPressed: () {
              setState(() {
                _isPlaying = !_isPlaying;
              });
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Center(
                  child: _error != null
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.error_outline, color: Colors.red, size: 48),
                            const SizedBox(height: 12),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: Text(
                                'Gagal memuat layar PC: $_error',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.tonal(
                              onPressed: () {
                                setState(() {
                                  _error = null;
                                  _isLoading = true;
                                });
                              },
                              child: const Text('Coba Lagi'),
                            ),
                          ],
                        )
                      : (_isLoading && _currentFrame == null)
                          ? const CircularProgressIndicator()
                          : screenStream,
                ),
              ),
              if (_showShortcuts) _buildShortcutBar(colors),
              // Bottom quick action toolbar
              if (_showShortcuts)
                Container(
                  color: colors.surfaceContainerHighest,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        tooltip: _showTrackpad ? 'Tutup Trackpad' : 'Trackpad Melayang',
                        icon: Icon(
                          Icons.mouse,
                          size: 20,
                          color: _showTrackpad ? colors.primary : null,
                        ),
                        onPressed: () => setState(() => _showTrackpad = !_showTrackpad),
                      ),
                      IconButton(
                        tooltip: 'Klik Kiri',
                        icon: const Icon(Icons.mouse_outlined, size: 20),
                        onPressed: () => _sendInput(action: 'click', button: 'left'),
                      ),
                      IconButton(
                        tooltip: 'Klik Kanan',
                        icon: const Icon(Icons.touch_app_outlined, size: 20),
                        onPressed: () => _sendInput(action: 'rclick', button: 'right'),
                      ),
                      IconButton(
                        tooltip: 'Scroll Naik',
                        icon: const Icon(Icons.arrow_upward_outlined, size: 20),
                        onPressed: () => _sendInput(action: 'scroll', delta: 120),
                      ),
                      IconButton(
                        tooltip: 'Scroll Turun',
                        icon: const Icon(Icons.arrow_downward_outlined, size: 20),
                        onPressed: () => _sendInput(action: 'scroll', delta: -120),
                      ),
                      IconButton(
                        tooltip: 'Ketik Teks (Native Keyboard)',
                        icon: const Icon(Icons.keyboard_outlined, size: 20),
                        onPressed: _toggleNativeKeyboard,
                      ),
                      IconButton(
                        tooltip: 'Enter',
                        icon: const Icon(Icons.keyboard_return_outlined, size: 20),
                        onPressed: () => _sendInput(action: 'key', key: 'Enter'),
                      ),
                      IconButton(
                        tooltip: 'Esc',
                        icon: const Icon(Icons.cancel_outlined, size: 20),
                        onPressed: () => _sendInput(action: 'key', key: 'Escape'),
                      ),
                      IconButton(
                        tooltip: 'Fokus Monitor (Sembunyikan Toolbar)',
                        icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                        onPressed: () => setState(() => _showShortcuts = false),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          // Floating Trackpad overlay
          if (_showTrackpad) _buildFloatingTrackpad(colors),
          // Hidden TextField for native Android IME soft keyboard
          _buildHiddenImeField(),
          // Floating pill button to restore shortcuts when hidden
          if (!_showShortcuts)
            Positioned(
              bottom: 16,
              left: 16,
              child: SafeArea(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton.filledTonal(
                      tooltip: 'Buka Toolbar & Shortcut',
                      icon: const Icon(Icons.tune),
                      onPressed: () => setState(() => _showShortcuts = true),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Buka/Tutup Keyboard HP',
                      icon: const Icon(Icons.keyboard),
                      onPressed: _toggleNativeKeyboard,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
