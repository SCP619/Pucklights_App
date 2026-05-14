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
  String _serverUrl = 'http://127.0.0.1:8000';
  List<Map<String, dynamic>> _highlights = [];
  final Set<String> _favorites = {};

  String get _baseUrl => _serverUrl.replaceAll(RegExp(r'/+$'), '');

  @override
  void initState() {
    super.initState();

    SharedPreferences.getInstance().then((p) {
      final saved = p.getString('server_url');

      setState(() => _serverUrl = saved ?? '');

      if (saved == null || saved.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _showSettings());
      }
    });
  }

  void _onHighlightsReady(List<Map<String, dynamic>> h) {
    setState(() {
      _highlights = h;
      _tab = 1;
    });
  }

  void _toggleFavorite(String fn) {
    setState(() {
      _favorites.contains(fn)
          ? _favorites.remove(fn)
          : _favorites.add(fn);
    });
  }

  void _showSettings() {
    final ctrl = TextEditingController(text: _serverUrl);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        title: const Text(
          'Server URL',
          style: TextStyle(color: kWhite),
        ),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: kWhite),
          decoration: const InputDecoration(
            hintText: 'https://xxxx.trycloudflare.com',
            hintStyle: TextStyle(color: kGrey),
            helperText:
                'Cloudflare: https://xxxx.trycloudflare.com\nUSB only: http://10.0.2.2:8000',
            helperStyle: TextStyle(color: kGrey, fontSize: 11),
            helperMaxLines: 2,
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: kGrey),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: kOrange),
            ),
          ),
          keyboardType: TextInputType.url,
          autocorrect: false,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancel',
              style: TextStyle(color: kGrey),
            ),
          ),
          TextButton(
            onPressed: () async {
              final url = ctrl.text.trim();

              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('server_url', url);

              setState(() => _serverUrl = url);

              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text(
              'Save',
              style: TextStyle(color: kOrange),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final favHighlights = _highlights
        .where((h) => _favorites.contains(h['filename']))
        .toList();

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'PuckLights 🏒',
          style: TextStyle(
            color: kWhite,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: GestureDetector(
              onTap: _showSettings,
              child: const CircleAvatar(
                radius: 16,
                backgroundColor: kBtn,
                child: Icon(
                  Icons.person_outline,
                  color: kGrey,
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          UploadTab(
            baseUrl: _baseUrl,
            onHighlightsReady: _onHighlightsReady,
          ),
          HighlightsTab(
            baseUrl: _baseUrl,
            highlights: _highlights,
            favorites: _favorites,
            onToggleFavorite: _toggleFavorite,
          ),
          FavoritesTab(
            baseUrl: _baseUrl,
            highlights: favHighlights,
            favorites: _favorites,
            onToggleFavorite: _toggleFavorite,
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: kBtn, width: 1),
          ),
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
            BottomNavigationBarItem(
              icon: Icon(Icons.upload_rounded),
              label: 'Upload',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.play_circle_outline_rounded),
              label: 'Highlights',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.favorite_border_rounded),
              label: 'Favorites',
            ),
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

  const UploadTab({
    super.key,
    required this.baseUrl,
    required this.onHighlightsReady,
  });

  @override
  State<UploadTab> createState() => _UploadTabState();
}

class _UploadTabState extends State<UploadTab> {
  File? _file;

  bool _uploading = false;

  double _progress = 0;

  final TextEditingController _urlController = TextEditingController();

  Future<void> _pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _file = File(result.files.single.path!);
      });
    }
  }

  Future<void> _upload() async {
    if (_file == null) return;

    if (widget.baseUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Set a server URL first — tap the profile icon.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _uploading = true;
      _progress = 0;
    });

    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(minutes: 10),
          receiveTimeout: const Duration(seconds: 60),
        ),
      );

      final res = await dio.post(
        '${widget.baseUrl}/upload',
        data: FormData.fromMap({
          'file': await MultipartFile.fromFile(
            _file!.path,
            filename: 'hockey.mp4',
          ),
        }),
        onSendProgress: (s, t) {
          if (t > 0 && mounted) {
            setState(() => _progress = s / t);
          }
        },
      );

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ProcessingScreen(
            jobId: res.data['job_id'] as String,
            baseUrl: widget.baseUrl,
            onDone: (h) {
              widget.onHighlightsReady(h);
              Navigator.pop(context);
            },
          ),
        ),
      );
    } on DioException catch (e) {
      final msg =
          'Upload failed\ntype: ${e.type.name}\nstatus: ${e.response?.statusCode}\nerror: ${e.error}';

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 12),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 12),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
      }
    }
  }

  Future<void> _uploadFromUrl() async {
    final url = _urlController.text.trim();

    if (url.isEmpty) return;

    if (widget.baseUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Set a server URL first — tap the profile icon.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _uploading = true;
      _progress = 0;
    });

    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 10),
        ),
      );

      final res = await dio.post(
        '${widget.baseUrl}/upload-url',
        data: {
          'url': url,
        },
      );

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ProcessingScreen(
            jobId: res.data['job_id'] as String,
            baseUrl: widget.baseUrl,
            onDone: (h) {
              widget.onHighlightsReady(h);
              Navigator.pop(context);
            },
          ),
        ),
      );
    } on DioException catch (e) {
      final msg =
          'URL upload failed\ntype: ${e.type.name}\nstatus: ${e.response?.statusCode}\nerror: ${e.error}';

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 12),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('URL upload failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 12),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
      }
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Spacer(flex: 2),

          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              border: Border.all(
                color: kGrey.withValues(alpha: 0.5),
                width: 2,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(top: 10, child: _dots()),
                Positioned(bottom: 10, child: _dots()),
                const Icon(
                  Icons.play_arrow_rounded,
                  color: kWhite,
                  size: 38,
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),

          Text(
            _file == null
                ? 'Upload your video to create highlights'
                : _file!.path.split('/').last,
            style: const TextStyle(
              color: kGrey,
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),

          const SizedBox(height: 24),

          TextField(
            controller: _urlController,
            style: const TextStyle(color: kWhite),
            decoration: InputDecoration(
              hintText: 'Paste video URL...',
              hintStyle: const TextStyle(color: kGrey),
              filled: true,
              fillColor: kCard,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),

          const Spacer(flex: 2),

          if (_uploading) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                backgroundColor: kBtn,
                color: kOrange,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _progress > 0
                  ? 'Uploading… ${(_progress * 100).toStringAsFixed(0)}%'
                  : 'Processing...',
              style: const TextStyle(
                color: kGrey,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 20),
          ],

          _PillButton(
            label: 'Select from Gallery',
            onTap: _uploading ? null : _pick,
          ),

          const SizedBox(height: 14),

          _PillButton(
            label: 'Browse files',
            onTap: _uploading ? null : _pick,
          ),

          const SizedBox(height: 14),

          _PillButton(
            label: 'Upload from URL',
            onTap: _uploading ? null : _uploadFromUrl,
          ),

          if (_file != null && !_uploading) ...[
            const SizedBox(height: 14),

            _PillButton(
              label: 'Extract Highlights',
              onTap: _upload,
              color: kOrange,
              textColor: Colors.black,
            ),
          ],

          const Spacer(),
        ],
      ),
    );
  }

  Widget _dots() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        4,
        (_) => Container(
          width: 7,
          height: 7,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: kGrey.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
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
class HighlightsTab extends StatefulWidget {
  final String baseUrl;
  final List<Map<String, dynamic>> highlights;
  final Set<String> favorites;
  final void Function(String) onToggleFavorite;

  const HighlightsTab({super.key, required this.baseUrl, required this.highlights,
      required this.favorites, required this.onToggleFavorite});

  @override
  State<HighlightsTab> createState() => _HighlightsTabState();
}

class _HighlightsTabState extends State<HighlightsTab> {
  final Set<String> _selected = {};

  Future<void> _combine(BuildContext context) async {
    final filenames = _selected.isEmpty ? <String>[] : _selected.toList();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Combining videos…'), duration: Duration(seconds: 60)),
    );

    try {
      final jobId = _extractJobId(widget.highlights.first['url'] as String);

      final res = await Dio().post(
        '${widget.baseUrl}/combine/$jobId',
        data: {'job_id': jobId, 'filenames': filenames},
      );

      final url = res.data['url'] as String;
      final filename = res.data['filename'] as String;
      final fullUrl = url.startsWith('http') ? url : '${widget.baseUrl}$url';

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      // Open fullscreen player with save option
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => _FullscreenVideoPage(
          videoUrl: fullUrl,
          title: 'Full Highlight Reel',
          baseUrl: widget.baseUrl,
          filename: filename,
          allowSave: true,
        ),
      ));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Combine failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Extracts job_id from a highlight URL like /highlights/<job_id>/<file>
  String _extractJobId(String url) {
    final parts = url.split('/');
    // url format: /highlights/<job_id>/<filename>
    final idx = parts.indexOf('highlights');
    if (idx != -1 && idx + 1 < parts.length) return parts[idx + 1];
    // fallback: second segment
    return parts.length > 2 ? parts[2] : parts.last;
  }

  @override
  void didUpdateWidget(HighlightsTab old) {
    super.didUpdateWidget(old);
    if (old.highlights != widget.highlights) _selected.clear();
  }

  void _toggleSelect(String filename) =>
      setState(() => _selected.contains(filename) ? _selected.remove(filename) : _selected.add(filename));

  Future<void> _save(BuildContext context) async {
    final toSave = _selected.isEmpty
        ? widget.highlights
        : widget.highlights.where((h) => _selected.contains(h['filename'])).toList();

    if (Platform.isAndroid || Platform.isIOS) {
      await Permission.photos.request();
      if (Platform.isAndroid) await Permission.storage.request();
    }

    final dio = Dio();
    int saved = 0;

    Directory saveDir;
    if (Platform.isAndroid || Platform.isIOS) {
      saveDir = await getTemporaryDirectory();
    } else {
      final home = Platform.environment['HOME'] ?? '.';
      saveDir = Directory('$home/Videos');
      if (!saveDir.existsSync()) saveDir = Directory(home);
    }

    for (final h in toSave) {
      final url = (h['url'] as String).startsWith('http') ? h['url'] as String : '${widget.baseUrl}${h['url']}';
      final local = '${saveDir.path}/${h['filename']}';
      try {
        await dio.download(url, local);
        if (Platform.isAndroid || Platform.isIOS) await Gal.putVideo(local);
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
    if (widget.highlights.isEmpty) {
      return const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.play_circle_outline_rounded, size: 72, color: kGrey),
        SizedBox(height: 16),
        Text('No highlights yet', style: TextStyle(color: kGrey, fontSize: 16)),
        SizedBox(height: 8),
        Text('Upload a game video to extract highlights',
            style: TextStyle(color: Color(0xFF4A5C7A), fontSize: 13)),
      ]));
    }

    final btnLabel = _selected.isEmpty
        ? 'Save All to Gallery'
        : 'Save ${_selected.length} Selected';

    return Column(children: [
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          itemCount: widget.highlights.length,
          itemBuilder: (ctx, i) {
            final h   = widget.highlights[i];
            final url = (h['url'] as String).startsWith('http') ? h['url'] as String : '${widget.baseUrl}${h['url']}';
            final fn  = h['filename'] as String;
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _HighlightListCard(
                index: i, highlight: h, videoUrl: url,
                isFavorite: widget.favorites.contains(fn),
                isSelected: _selected.contains(fn),
                onToggleFavorite: () => widget.onToggleFavorite(fn),
                onToggleSelect:   () => _toggleSelect(fn),
              ),
            );
          },
        ),
      ),
      SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Row(children: [
            Expanded(
              child: _PillButton(
                label: btnLabel,
                onTap: () => _save(context),
                color: kOrange,
                textColor: Colors.black,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _PillButton(
                label: _selected.isEmpty
                    ? 'Combine All'
                    : 'Combine ${_selected.length}',
                onTap: () => _combine(context),
                color: kBtn,
              ),
            ),
          ]),
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
            isSelected: false,
            onToggleFavorite: () => onToggleFavorite(h['filename'] as String),
            onToggleSelect: () {},
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
  final bool isSelected;
  final VoidCallback onToggleFavorite;
  final VoidCallback onToggleSelect;

  const _HighlightListCard({required this.index, required this.highlight, required this.videoUrl,
      required this.isFavorite, required this.isSelected,
      required this.onToggleFavorite, required this.onToggleSelect});

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
      _controller = VideoController(
        _player!,
        configuration: const VideoControllerConfiguration(
          enableHardwareAcceleration: false,
        ),
      );
      _player!.stream.playing.listen((p) {
        if (mounted) setState(() => _playing = p);
      });
      setState(() => _init = true);
      await Future.delayed(const Duration(milliseconds: 300));
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
      // Checkbox
      SizedBox(
        width: 36,
        child: Checkbox(
          value: widget.isSelected,
          onChanged: (_) => widget.onToggleSelect(),
          activeColor: kOrange,
          checkColor: Colors.black,
          side: const BorderSide(color: kGrey, width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
      ),
      const SizedBox(width: 6),

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
                    ? Video(
                        controller: _controller!,
                        controls: NoVideoControls,
                        subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
                      )
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
// FULLSCREEN VIDEO PAGE
// ─────────────────────────────────────────────────────────────────────────────
class _FullscreenVideoPage extends StatefulWidget {
  final String videoUrl;
  final String title;
  final String? baseUrl;
  final String? filename;
  final bool allowSave;

  const _FullscreenVideoPage({
    required this.videoUrl,
    required this.title,
    this.baseUrl,
    this.filename,
    this.allowSave = false,
  });

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  late final Player _player;
  late final VideoController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: false,
      ),
    );
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _player.open(Media(widget.videoUrl));
    });
  }

  @override
  void dispose() { _player.dispose(); super.dispose(); }

  Future<void> _saveToGallery() async {
    if (_saving) return;
    setState(() => _saving = true);

    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await Permission.photos.request();
        if (Platform.isAndroid) await Permission.storage.request();
      }

      final tmpDir = await getTemporaryDirectory();
      final filename = widget.filename ?? 'highlight_reel_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final localPath = '${tmpDir.path}/$filename';

      await Dio().download(widget.videoUrl, localPath);

      if (Platform.isAndroid || Platform.isIOS) {
        await Gal.putVideo(localPath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Highlight reel saved to gallery!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        final home = Platform.environment['HOME'] ?? '.';
        final destDir = Directory('$home/Videos');
        if (!destDir.existsSync()) destDir.createSync(recursive: true);
        final dest = '${destDir.path}/$filename';
        File(localPath).copySync(dest);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ Saved to $dest'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

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
        actions: [
          if (widget.allowSave)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _saving
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2, color: kOrange,
                        ),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.download_rounded, color: kOrange),
                      tooltip: 'Save to gallery',
                      onPressed: _saveToGallery,
                    ),
            ),
        ],
      ),
      body: Center(
        child: Video(
          controller: _controller,
          controls: MaterialVideoControls,
          subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
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