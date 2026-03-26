import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const HockeyHighlightsApp());

// ─────────────────────────────────────────────────────────────────────────────
// App root
// ─────────────────────────────────────────────────────────────────────────────

class HockeyHighlightsApp extends StatelessWidget {
  const HockeyHighlightsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hockey Highlights',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF003087),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HOME SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _ipController = TextEditingController();
  final _picker = ImagePicker();

  File? _selectedVideo;
  bool _isUploading = false;
  double _uploadProgress = 0;

  @override
  void initState() {
    super.initState();
    _loadSavedIp();
  }

  Future<void> _loadSavedIp() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _ipController.text = prefs.getString('server_ip') ?? '192.168.1.100');
  }

  Future<void> _saveIp() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_ip', _ipController.text.trim());
  }

  String get _baseUrl => 'http://${_ipController.text.trim()}:8000';

  Future<void> _pickVideo() async {
    final picked = await _picker.pickVideo(source: ImageSource.gallery);
    if (picked != null) setState(() => _selectedVideo = File(picked.path));
  }

  Future<void> _uploadAndProcess() async {
    if (_selectedVideo == null) return;
    await _saveIp();
    setState(() { _isUploading = true; _uploadProgress = 0; });

    try {
      final dio = Dio();
      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(
          _selectedVideo!.path,
          filename: 'hockey_video.mp4',
        ),
      });

      final response = await dio.post(
        '$_baseUrl/upload',
        data: formData,
        onSendProgress: (sent, total) {
          if (total > 0 && mounted) setState(() => _uploadProgress = sent / total);
        },
      );

      if (!mounted) return;
      final jobId = response.data['job_id'] as String;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ProcessingScreen(jobId: jobId, baseUrl: _baseUrl),
        ),
      );
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: ${e.message}'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  @override
  void dispose() { _ipController.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Hockey Highlights'), centerTitle: true),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

            // Server IP
            const Text('Backend Server IP',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                hintText: '192.168.1.100',
                prefixIcon: Icon(Icons.wifi),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 32),

            // Video picker
            GestureDetector(
              onTap: _isUploading ? null : _pickVideo,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 220,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _selectedVideo != null ? cs.primary : cs.outlineVariant,
                    width: _selectedVideo != null ? 2 : 1,
                  ),
                ),
                child: Center(
                  child: _selectedVideo == null
                      ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.video_library_rounded, size: 64, color: cs.primary),
                          const SizedBox(height: 12),
                          Text('Tap to select hockey video',
                              style: TextStyle(color: cs.onSurfaceVariant)),
                        ])
                      : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          const Icon(Icons.check_circle_rounded,
                              size: 48, color: Colors.greenAccent),
                          const SizedBox(height: 12),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              _selectedVideo!.path.split('/').last,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 2,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text('Tap to change',
                              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
                        ]),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Upload progress bar
            if (_isUploading) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: _uploadProgress, minHeight: 8),
              ),
              const SizedBox(height: 8),
              Text('Uploading… ${(_uploadProgress * 100).toStringAsFixed(0)}%',
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
            ],

            // Action button
            FilledButton.icon(
              onPressed: (_selectedVideo != null && !_isUploading) ? _uploadAndProcess : null,
              icon: _isUploading
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.sports_hockey),
              label: Text(_isUploading ? 'Uploading…' : 'Extract Highlights'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PROCESSING SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class ProcessingScreen extends StatefulWidget {
  final String jobId;
  final String baseUrl;
  const ProcessingScreen({super.key, required this.jobId, required this.baseUrl});

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

      if (_status == 'completed') {
        _timer?.cancel();
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => HighlightsScreen(
                jobId: widget.jobId,
                baseUrl: widget.baseUrl,
                highlights: _highlights,
              ),
            ),
          );
        }
      } else if (_status == 'failed') {
        _timer?.cancel();
      }
    } on DioException { /* keep polling on transient errors */ }
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Processing…')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(36),
          child: _error != null ? _buildError() : _buildProgress(),
        ),
      ),
    );
  }

  Widget _buildError() => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const Icon(Icons.error_rounded, color: Colors.redAccent, size: 64),
      const SizedBox(height: 16),
      Text('Processing failed:\n$_error', textAlign: TextAlign.center),
      const SizedBox(height: 24),
      OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Go Back')),
    ],
  );

  Widget _buildProgress() => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      SizedBox(
        width: 140, height: 140,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: _progress > 0 ? _progress / 100 : null,
              strokeWidth: 10,
            ),
            if (_progress > 0)
              Text('${_progress.toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
      const SizedBox(height: 32),
      Text(
        _status == 'queued' ? 'Waiting to start…' : 'Analysing video for goals…',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      Text('This may take several minutes for long videos.',
          style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
      if (_highlights.isNotEmpty) ...[
        const SizedBox(height: 32),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.celebration_rounded, color: Colors.amber, size: 28),
              const SizedBox(width: 12),
              Text(
                '${_highlights.length} goal${_highlights.length != 1 ? "s" : ""} found so far!',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ]),
          ),
        ),
      ],
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// HIGHLIGHTS SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class HighlightsScreen extends StatefulWidget {
  final String jobId;
  final String baseUrl;
  final List<Map<String, dynamic>> highlights;

  const HighlightsScreen({
    super.key,
    required this.jobId,
    required this.baseUrl,
    required this.highlights,
  });

  @override
  State<HighlightsScreen> createState() => _HighlightsScreenState();
}

class _HighlightsScreenState extends State<HighlightsScreen> {
  late List<Map<String, dynamic>> _highlights;
  final Set<int> _selected = {};
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _highlights = List.from(widget.highlights);
    _selected.addAll(List.generate(_highlights.length, (i) => i)); // all selected by default
  }

  String _videoUrl(String filename) =>
      '${widget.baseUrl}/highlights/${widget.jobId}/$filename';

  bool get _allSelected => _selected.length == _highlights.length;

  void _toggleSelectAll() => setState(() {
    _allSelected
        ? _selected.clear()
        : _selected.addAll(List.generate(_highlights.length, (i) => i));
  });

  Future<void> _saveSelected() async {
    if (_selected.isEmpty) return;
    setState(() => _isSaving = true);

    await Permission.photos.request();
    if (Platform.isAndroid) await Permission.storage.request();

    final dio    = Dio();
    final tmpDir = await getTemporaryDirectory();
    int saved    = 0;

    for (final idx in List<int>.from(_selected)) {
      final filename  = _highlights[idx]['filename'] as String;
      final localPath = '${tmpDir.path}/$filename';
      try {
        await dio.download(_videoUrl(filename), localPath);
        await Gal.putVideo(localPath);
        saved++;
      } catch (e) {
        debugPrint('Save failed for $filename: $e');
      }
    }

    setState(() => _isSaving = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Saved $saved clip${saved != 1 ? "s" : ""} to your gallery'),
      backgroundColor: Colors.green,
    ));
  }

  Future<void> _discardUnselected() async {
    final toDiscard = [
      for (int i = 0; i < _highlights.length; i++) if (!_selected.contains(i)) i
    ];

    if (toDiscard.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All highlights are selected — nothing to discard')));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard Highlights'),
        content: Text(
            'Permanently delete ${toDiscard.length} unselected clip${toDiscard.length != 1 ? "s" : ""}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final dio = Dio();
    for (final idx in toDiscard.reversed) {
      final filename = _highlights[idx]['filename'] as String;
      try {
        await dio.delete('${widget.baseUrl}/highlights/${widget.jobId}/$filename');
      } catch (e) {
        debugPrint('Delete failed for $filename: $e');
      }
    }

    setState(() {
      final remaining   = <Map<String, dynamic>>[];
      final newSelected = <int>{};
      for (int i = 0; i < _highlights.length; i++) {
        if (_selected.contains(i)) {
          newSelected.add(remaining.length);
          remaining.add(_highlights[i]);
        }
      }
      _highlights = remaining;
      _selected..clear()..addAll(newSelected);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_highlights.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Highlights')),
        body: const Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.sports_hockey, size: 72, color: Colors.white30),
            SizedBox(height: 16),
            Text('No goals detected in this video',
                style: TextStyle(color: Colors.white54)),
          ]),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
            '${_highlights.length} Goal${_highlights.length != 1 ? "s" : ""} Found'),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _toggleSelectAll,
            child: Text(_allSelected ? 'Deselect All' : 'Select All'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Highlights grid
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 9 / 16,
              ),
              itemCount: _highlights.length,
              itemBuilder: (ctx, idx) => _HighlightCard(
                index: idx,
                highlight: _highlights[idx],
                videoUrl: _videoUrl(_highlights[idx]['filename'] as String),
                isSelected: _selected.contains(idx),
                onToggle: (sel) => setState(
                    () => sel ? _selected.add(idx) : _selected.remove(idx)),
              ),
            ),
          ),

          // Bottom action bar
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isSaving ? null : _discardUnselected,
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                      label: const Text('Discard Unselected',
                          style: TextStyle(color: Colors.redAccent)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: (_selected.isNotEmpty && !_isSaving) ? _saveSelected : null,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.download_rounded),
                      label: Text(_isSaving
                          ? 'Saving…'
                          : 'Save ${_selected.length} Selected'),
                    ),
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

// ─────────────────────────────────────────────────────────────────────────────
// HIGHLIGHT CARD  – inline video preview + checkbox
// ─────────────────────────────────────────────────────────────────────────────

class _HighlightCard extends StatefulWidget {
  final int index;
  final Map<String, dynamic> highlight;
  final String videoUrl;
  final bool isSelected;
  final ValueChanged<bool> onToggle;

  const _HighlightCard({
    required this.index,
    required this.highlight,
    required this.videoUrl,
    required this.isSelected,
    required this.onToggle,
  });

  @override
  State<_HighlightCard> createState() => _HighlightCardState();
}

class _HighlightCardState extends State<_HighlightCard> {
  VideoPlayerController? _ctrl;
  bool _initialized = false;
  bool _isPlaying   = false;

  Future<void> _togglePlay() async {
    if (_ctrl == null) {
      _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl))
        ..addListener(() {
          if (mounted) setState(() => _isPlaying = _ctrl!.value.isPlaying);
        });
      await _ctrl!.initialize();
      if (!mounted) return;
      setState(() => _initialized = true);
      await _ctrl!.play();
    } else {
      _ctrl!.value.isPlaying ? await _ctrl!.pause() : await _ctrl!.play();
    }
  }

  @override
  void dispose() { _ctrl?.dispose(); super.dispose(); }

  String _formatTs(dynamic ts) {
    if (ts == null) return '';
    final s = (ts as num).toInt();
    return '${s ~/ 60}m ${s % 60}s';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _togglePlay,
      child: Stack(
        fit: StackFit.expand,
        children: [

          // Video player or placeholder
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: _initialized && _ctrl != null
                ? VideoPlayer(_ctrl!)
                : Container(
                    color: Colors.grey[850],
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.sports_hockey, size: 40, color: Colors.white38),
                      const SizedBox(height: 8),
                      Text('Goal ${widget.index + 1}',
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(_formatTs(widget.highlight['timestamp']),
                          style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ]),
                  ),
          ),

          // Play overlay
          if (!_isPlaying)
            Center(
              child: Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 32),
              ),
            ),

          // Goal label (top-left)
          Positioned(
            top: 8, left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: Colors.black54, borderRadius: BorderRadius.circular(6)),
              child: Text('Goal ${widget.index + 1}',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ),

          // Checkbox (top-right)
          Positioned(
            top: 8, right: 8,
            child: GestureDetector(
              onTap: () => widget.onToggle(!widget.isSelected),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 28, height: 28,
                decoration: BoxDecoration(
                  color: widget.isSelected ? Colors.blueAccent : Colors.black54,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: widget.isSelected
                    ? const Icon(Icons.check, color: Colors.white, size: 18)
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
