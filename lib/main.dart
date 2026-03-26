import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Design tokens ────────────────────────────────────────────────────────────
const Color kBg      = Color(0xFF0A1628);
const Color kCard    = Color(0xFF152035);
const Color kBtn     = Color(0xFF1C2D4A);
const Color kOrange  = Color(0xFFF59E0B);
const Color kWhite   = Colors.white;
const Color kGrey    = Color(0xFF8899B0);
const double kRadius = 32;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const PuckLightsApp());
}

class PuckLightsApp extends StatelessWidget {
  const PuckLightsApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PuckLights',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kOrange, surface: kBg),
        useMaterial3: true,
      ),
      home: const MainShell(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main shell with bottom nav
// ─────────────────────────────────────────────────────────────────────────────
class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tab = 0;
  String _serverIp = '192.168.1.100';
  List<Map<String, dynamic>> _highlights = [];
  final Set<String> _favorites = {};

  String get _baseUrl => 'http://$_serverIp:8000';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      setState(() => _serverIp = p.getString('server_ip') ?? '192.168.1.100');
    });
  }

  void _onHighlightsReady(List<Map<String, dynamic>> h) =>
      setState(() { _highlights = h; _tab = 1; });

  void _toggleFavorite(String fn) => setState(() {
    _favorites.contains(fn) ? _favorites.remove(fn) : _favorites.add(fn);
  });

  void _showSettings() {
    final ctrl = TextEditingController(text: _serverIp);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        title: const Text('Server IP', style: TextStyle(color: kWhite)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: kWhite),
          decoration: const InputDecoration(
            hintText: '192.168.1.100',
            hintStyle: TextStyle(color: kGrey),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: kGrey)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: kOrange)),
          ),
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: kGrey))),
          TextButton(
            onPressed: () async {
              final ip = ctrl.text.trim();
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('server_ip', ip);
              setState(() => _serverIp = ip);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save', style: TextStyle(color: kOrange)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final favHighlights = _highlights.where((h) => _favorites.contains(h['filename'])).toList();

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        centerTitle: true,
        title: const Text('PuckLights 🏒',
            style: TextStyle(color: kWhite, fontWeight: FontWeight.bold, fontSize: 20)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: GestureDetector(
              onTap: _showSettings,
              child: const CircleAvatar(
                radius: 16,
                backgroundColor: kBtn,
                child: Icon(Icons.person_outline, color: kGrey, size: 20),
              ),
            ),
          ),
        ],
      ),
      body: IndexedStack(index: _tab, children: [
        UploadTab(baseUrl: _baseUrl, onHighlightsReady: _onHighlightsReady),
        HighlightsTab(baseUrl: _baseUrl, highlights: _highlights,
            favorites: _favorites, onToggleFavorite: _toggleFavorite),
        FavoritesTab(baseUrl: _baseUrl, highlights: favHighlights,
            favorites: _favorites, onToggleFavorite: _toggleFavorite),
      ]),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: kBtn, width: 1)),
        ),
        child: BottomNavigationBar(
          currentIndex: _tab,
          onTap: (i) => setState(() => _tab = i),
          backgroundColor: kBg,
          selectedItemColor: kOrange,
          unselectedItemColor: kGrey,
          selectedFontSize: 12,
          unselectedFontSize: 12,
          type: BottomNavigationBarType.fixed,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.upload_rounded), label: 'Upload'),
            BottomNavigationBarItem(icon: Icon(Icons.play_circle_outline_rounded), label: 'Highlights'),
            BottomNavigationBarItem(icon: Icon(Icons.favorite_border_rounded), label: 'Favorites'),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// UPLOAD TAB
// ─────────────────────────────────────────────────────────────────────────────
class UploadTab extends StatefulWidget {
  final String baseUrl;
  final void Function(List<Map<String, dynamic>>) onHighlightsReady;
  const UploadTab({super.key, required this.baseUrl, required this.onHighlightsReady});
  @override
  State<UploadTab> createState() => _UploadTabState();
}

class _UploadTabState extends State<UploadTab> {
  File? _file;
  bool _uploading = false;
  double _progress = 0;

  Future<void> _pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );
    if (result != null && result.files.single.path != null) {
      setState(() => _file = File(result.files.single.path!));
    }
  }

  Future<void> _upload() async {
    if (_file == null) return;
    setState(() { _uploading = true; _progress = 0; });
    try {
      final res = await Dio().post(
        '${widget.baseUrl}/upload',
        data: FormData.fromMap({
          'file': await MultipartFile.fromFile(_file!.path, filename: 'hockey.mp4'),
        }),
        onSendProgress: (s, t) {
          if (t > 0 && mounted) setState(() => _progress = s / t);
        },
      );
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => ProcessingScreen(
          jobId: res.data['job_id'] as String,
          baseUrl: widget.baseUrl,
          onDone: (h) { widget.onHighlightsReady(h); Navigator.pop(context); },
        ),
      ));
    } on DioException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: ${e.message}'), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(children: [
        const Spacer(flex: 2),

        // Film icon
        Container(
          width: 96, height: 96,
          decoration: BoxDecoration(
            border: Border.all(color: kGrey.withValues(alpha: 0.5), width: 2),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Stack(alignment: Alignment.center, children: [
            Positioned(top: 10, child: _dots()),
            Positioned(bottom: 10, child: _dots()),
            const Icon(Icons.play_arrow_rounded, color: kWhite, size: 38),
          ]),
        ),
        const SizedBox(height: 18),
        Text(
          _file == null ? 'Upload your video to create highlights' : _file!.path.split('/').last,
          style: const TextStyle(color: kGrey, fontSize: 14),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),

        const Spacer(flex: 2),

        if (_uploading) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: _progress, backgroundColor: kBtn, color: kOrange, minHeight: 6),
          ),
          const SizedBox(height: 8),
          Text('Uploading… ${(_progress * 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: kGrey, fontSize: 13)),
          const SizedBox(height: 20),
        ],

        _PillButton(label: 'Select from Gallery', onTap: _uploading ? null : _pick),
        const SizedBox(height: 14),
        _PillButton(label: 'Browse files', onTap: _uploading ? null : _pick),

        if (_file != null && !_uploading) ...[
          const SizedBox(height: 14),
          _PillButton(label: 'Extract Highlights', onTap: _upload, color: kOrange, textColor: Colors.black),
        ],

        const Spacer(),
      ]),
    );
  }

  Widget _dots() => Row(
    mainAxisSize: MainAxisSize.min,
    children: List.generate(4, (_) => Container(
      width: 7, height: 7,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(color: kGrey.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(2)),
    )),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// PROCESSING SCREEN
// ─────────────────────────────────────────────────────────────────────────────
class ProcessingScreen extends StatefulWidget {
  final String jobId, baseUrl;
  final void Function(List<Map<String, dynamic>>) onDone;
  const ProcessingScreen({super.key, required this.jobId, required this.baseUrl, required this.onDone});
  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  Timer? _timer;
  double _progress = 0;
  String _status = 'queued';
  List<Map<String, dynamic>> _highlights = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  Future<void> _poll() async {
    try {
      final res = await Dio().get('${widget.baseUrl}/status/${widget.jobId}');
      final data = res.data as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _status     = data['status'] as String;
        _progress   = (data['progress'] as num).toDouble();
        _highlights = List<Map<String, dynamic>>.from(data['highlights'] as List);
        _error      = data['error'] as String?;
      });
      if (_status == 'completed') { _timer?.cancel(); widget.onDone(_highlights); }
      else if (_status == 'failed') _timer?.cancel();
    } on DioException { /* keep polling */ }
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg, elevation: 0, centerTitle: true,
        title: const Text('PuckLights 🏒',
            style: TextStyle(color: kWhite, fontWeight: FontWeight.bold, fontSize: 20)),
        leading: IconButton(icon: const Icon(Icons.close, color: kGrey), onPressed: () => Navigator.pop(context)),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: _error != null
              ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.error_rounded, color: Colors.redAccent, size: 64),
                  const SizedBox(height: 16),
                  Text('Failed:\n$_error', textAlign: TextAlign.center, style: const TextStyle(color: kGrey)),
                  const SizedBox(height: 24),
                  _PillButton(label: 'Go Back', onTap: () => Navigator.pop(context)),
                ])
              : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  SizedBox(
                    width: 150, height: 150,
                    child: Stack(alignment: Alignment.center, children: [
                      CircularProgressIndicator(
                        value: _progress > 0 ? _progress / 100 : null,
                        strokeWidth: 8, backgroundColor: kBtn, color: kOrange,
                      ),
                      if (_progress > 0)
                        Text('${_progress.toStringAsFixed(0)}%',
                            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: kWhite)),
                    ]),
                  ),
                  const SizedBox(height: 36),
                  Text(_status == 'queued' ? 'Queued…' : 'Analysing video for goals…',
                      style: const TextStyle(color: kWhite, fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const Text('This may take several minutes.',
                      style: TextStyle(color: kGrey, fontSize: 13), textAlign: TextAlign.center),
                  if (_highlights.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      decoration: BoxDecoration(color: kBtn, borderRadius: BorderRadius.circular(16)),
                      child: Text('🎬  ${_highlights.length} highlight${_highlights.length != 1 ? "s" : ""} created!',
                          style: const TextStyle(color: kWhite, fontWeight: FontWeight.w600, fontSize: 16)),
                    ),
                  ],
                ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HIGHLIGHTS TAB
// ─────────────────────────────────────────────────────────────────────────────
class HighlightsTab extends StatelessWidget {
  final String baseUrl;
  final List<Map<String, dynamic>> highlights;
  final Set<String> favorites;
  final void Function(String) onToggleFavorite;

  const HighlightsTab({super.key, required this.baseUrl, required this.highlights,
      required this.favorites, required this.onToggleFavorite});

  Future<void> _saveAll(BuildContext context) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await Permission.photos.request();
      if (Platform.isAndroid) await Permission.storage.request();
    }

    final dio = Dio();
    int saved = 0;

    // On Linux/desktop, save to ~/Videos; on mobile save to gallery via Gal.
    Directory saveDir;
    if (Platform.isAndroid || Platform.isIOS) {
      saveDir = await getTemporaryDirectory();
    } else {
      final home = Platform.environment['HOME'] ?? '.';
      saveDir = Directory('$home/Videos');
      if (!saveDir.existsSync()) saveDir = Directory(home);
    }

    for (final h in highlights) {
      final url = (h['url'] as String).startsWith('http') ? h['url'] as String : '$baseUrl${h['url']}';
      final local = '${saveDir.path}/${h['filename']}';
      try {
        await dio.download(url, local);
        if (Platform.isAndroid || Platform.isIOS) {
          await Gal.putVideo(local);
        }
        saved++;
      } catch (e) { debugPrint('Save error: $e'); }
    }

    if (context.mounted) {
      final dest = (Platform.isAndroid || Platform.isIOS) ? 'gallery' : saveDir.path;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved $saved highlight(s) to $dest'), backgroundColor: Colors.green));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (highlights.isEmpty) {
      return const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.play_circle_outline_rounded, size: 72, color: kGrey),
        SizedBox(height: 16),
        Text('No highlights yet', style: TextStyle(color: kGrey, fontSize: 16)),
        SizedBox(height: 8),
        Text('Upload a game video to extract goals',
            style: TextStyle(color: Color(0xFF4A5C7A), fontSize: 13)),
      ]));
    }

    return Column(children: [
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          itemCount: highlights.length,
          itemBuilder: (ctx, i) {
            final h   = highlights[i];
            final url = (h['url'] as String).startsWith('http') ? h['url'] as String : '$baseUrl${h['url']}';
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _HighlightListCard(
                index: i, highlight: h, videoUrl: url,
                isFavorite: favorites.contains(h['filename'] as String),
                onToggleFavorite: () => onToggleFavorite(h['filename'] as String),
              ),
            );
          },
        ),
      ),
      SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: _PillButton(label: 'Save All to Gallery', onTap: () => _saveAll(context),
              color: kOrange, textColor: Colors.black),
        ),
      ),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FAVORITES TAB
// ─────────────────────────────────────────────────────────────────────────────
class FavoritesTab extends StatelessWidget {
  final String baseUrl;
  final List<Map<String, dynamic>> highlights;
  final Set<String> favorites;
  final void Function(String) onToggleFavorite;

  const FavoritesTab({super.key, required this.baseUrl, required this.highlights,
      required this.favorites, required this.onToggleFavorite});

  @override
  Widget build(BuildContext context) {
    if (highlights.isEmpty) {
      return const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.favorite_border_rounded, size: 72, color: kGrey),
        SizedBox(height: 16),
        Text('No favorites yet', style: TextStyle(color: kGrey, fontSize: 16)),
        SizedBox(height: 8),
        Text('Tap the ♡ on a highlight to save it here',
            style: TextStyle(color: Color(0xFF4A5C7A), fontSize: 13)),
      ]));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: highlights.length,
      itemBuilder: (ctx, i) {
        final h   = highlights[i];
        final url = (h['url'] as String).startsWith('http') ? h['url'] as String : '$baseUrl${h['url']}';
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: _HighlightListCard(
            index: i, highlight: h, videoUrl: url,
            isFavorite: favorites.contains(h['filename'] as String),
            onToggleFavorite: () => onToggleFavorite(h['filename'] as String),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HIGHLIGHT LIST CARD  – landscape card left, heart icon right
// ─────────────────────────────────────────────────────────────────────────────
class _HighlightListCard extends StatefulWidget {
  final int index;
  final Map<String, dynamic> highlight;
  final String videoUrl;
  final bool isFavorite;
  final VoidCallback onToggleFavorite;

  const _HighlightListCard({required this.index, required this.highlight, required this.videoUrl,
      required this.isFavorite, required this.onToggleFavorite});

  @override
  State<_HighlightListCard> createState() => _HighlightListCardState();
}

class _HighlightListCardState extends State<_HighlightListCard> {
  Player? _player;
  VideoController? _controller;
  bool _init = false;
  bool _playing = false;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  Future<void> _onTap() async {
    if (_isMobile) {
      _openFullscreen();
    } else {
      await _toggleInline();
    }
  }

  Future<void> _toggleInline() async {
    if (_player == null) {
      _player = Player();
      _controller = VideoController(_player!);
      _player!.stream.playing.listen((p) {
        if (mounted) setState(() => _playing = p);
      });
      setState(() => _init = true);
      await _player!.open(Media(widget.videoUrl));
    } else {
      await _player!.playOrPause();
    }
  }

  void _openFullscreen() {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => _FullscreenVideoPage(
        videoUrl: widget.videoUrl,
        title: 'Highlight ${widget.index + 1}',
      ),
    ));
  }

  @override
  void dispose() { _player?.dispose(); super.dispose(); }

  String _ts(dynamic t) {
    if (t == null) return '';
    final s = (t as num).toInt();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      // Card (~65% width)
      Expanded(
        flex: 13,
        child: GestureDetector(
          onTap: _onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(fit: StackFit.expand, children: [
                _init && _controller != null
                    ? Video(controller: _controller!, controls: NoVideoControls)
                    : Container(
                        color: kCard,
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          const Icon(Icons.sports_hockey, color: kGrey, size: 26),
                          const SizedBox(height: 6),
                          Text('Highlight ${widget.index + 1}',
                              style: const TextStyle(color: kWhite, fontWeight: FontWeight.bold, fontSize: 13)),
                          if (widget.highlight['timestamp'] != null) ...[
                            const SizedBox(height: 2),
                            Text(_ts(widget.highlight['timestamp']),
                                style: const TextStyle(color: kGrey, fontSize: 11)),
                          ],
                        ]),
                      ),
                // Play / pause overlay
                if (!_playing)
                  Center(child: Container(
                    width: 38, height: 38,
                    decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                    child: Icon(
                      _isMobile ? Icons.open_in_full_rounded : Icons.play_arrow_rounded,
                      color: kWhite, size: 24,
                    ),
                  )),
              ]),
            ),
          ),
        ),
      ),

      const Spacer(flex: 1),

      // Heart
      GestureDetector(
        onTap: widget.onToggleFavorite,
        child: Icon(
          widget.isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          color: widget.isFavorite ? kOrange : kGrey,
          size: 26,
        ),
      ),
      const SizedBox(width: 4),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FULLSCREEN VIDEO PAGE  (mobile only)
// ─────────────────────────────────────────────────────────────────────────────
class _FullscreenVideoPage extends StatefulWidget {
  final String videoUrl, title;
  const _FullscreenVideoPage({required this.videoUrl, required this.title});
  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  late final Player _player;
  late final VideoController _controller;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _player.open(Media(widget.videoUrl));
  }

  @override
  void dispose() { _player.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: kWhite),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(widget.title, style: const TextStyle(color: kWhite, fontSize: 16)),
      ),
      body: Center(
        child: Video(
          controller: _controller,
          controls: MaterialVideoControls,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pill button
// ─────────────────────────────────────────────────────────────────────────────
class _PillButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final Color color;
  final Color textColor;

  const _PillButton({required this.label, required this.onTap,
      this.color = kBtn, this.textColor = kWhite});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: Material(
        color: onTap == null ? kBtn.withValues(alpha: 0.4) : color,
        borderRadius: BorderRadius.circular(kRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadius),
          onTap: onTap,
          child: Center(child: Text(label,
              style: TextStyle(color: onTap == null ? kGrey : textColor,
                  fontSize: 16, fontWeight: FontWeight.w600))),
        ),
      ),
    );
  }
}
