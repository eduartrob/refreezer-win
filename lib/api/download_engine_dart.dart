import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../utils/deezer_decryptor_dart.dart';

final _log = Logger('DownloadEngineDart');

/// Download states — mirrors Download.DownloadState in Java
enum DownloadStateDart { none, downloading, post, done, deezerError, error }

/// A pending or active download record
class DownloadItemDart {
  final int id;
  final String trackId;
  final String streamTrackId;
  final String trackToken;
  final String md5origin;
  final String mediaVersion;
  final String path;
  final bool private;
  final int quality;
  final String title;
  final String? imageUrl;

  DownloadStateDart state;
  int received;
  int filesize;

  DownloadItemDart({
    required this.id,
    required this.trackId,
    required this.streamTrackId,
    required this.trackToken,
    required this.md5origin,
    required this.mediaVersion,
    required this.path,
    required this.private,
    required this.quality,
    required this.title,
    this.imageUrl,
    this.state = DownloadStateDart.none,
    this.received = 0,
    this.filesize = 1,
  });

  double get progress => received / filesize.clamp(1, filesize);

  factory DownloadItemDart.fromJson(Map<dynamic, dynamic> json) {
    return DownloadItemDart(
      id: json['id'] ?? 0,
      trackId: json['trackId'] ?? '',
      streamTrackId: json['streamTrackId'] ?? json['trackId'] ?? '',
      trackToken: json['trackToken'] ?? '',
      md5origin: json['md5origin'] ?? '',
      mediaVersion: json['mediaVersion'] ?? '',
      path: json['path'] ?? '',
      private: json['private'] == true,
      quality: json['quality'] ?? 1,
      title: json['title'] ?? '',
      imageUrl: json['image'],
    );
  }
}

/// Progress update emitted to the UI
class DownloadProgressDart {
  final int id;
  final DownloadStateDart state;
  final int received;
  final int filesize;
  final int quality;
  DownloadProgressDart(
      this.id, this.state, this.received, this.filesize, this.quality);
}

/// Dart reimplementation of DownloadService.java
/// Manages the download queue, downloads tracks, decrypts, and tags them.
/// Communicates with the UI via [progressStream].
class DownloadEngineDart {
  static const int _maxConcurrent = 3;

  final _progressController =
      StreamController<DownloadProgressDart>.broadcast();
  Stream<DownloadProgressDart> get progressStream =>
      _progressController.stream;

  final _stateController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get stateStream => _stateController.stream;

  bool running = false;
  int get queueSize =>
      _queue.where((d) => d.state == DownloadStateDart.none).length;

  final List<DownloadItemDart> _queue = [];
  int _activeCount = 0;

  String? _arl;
  String? _licenseToken;
  bool _authorized = false;

  Database? _db;
  String? _offlinePath;

  // ---------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------

  Future<void> init({
    required Database db,
    required String offlinePath,
    required String? arl,
  }) async {
    _db = db;
    _offlinePath = offlinePath;
    _arl = arl;
  }

  Future<void> addDownloads(List<Map<dynamic, dynamic>> jsonList) async {
    for (final json in jsonList) {
      final item = DownloadItemDart.fromJson(json);
      // Persist to DB
      await _db?.insert('Downloads', {
        'trackId': item.trackId,
        'streamTrackId': item.streamTrackId,
        'trackToken': item.trackToken,
        'md5origin': item.md5origin,
        'mediaVersion': item.mediaVersion,
        'path': item.path,
        'private': item.private ? 1 : 0,
        'quality': item.quality,
        'title': item.title,
        'image': item.imageUrl ?? '',
        'state': 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      _queue.add(item);
    }
  }

  Future<void> loadFromDb() async {
    final rows = await _db?.query('Downloads') ?? [];
    _queue.clear();
    for (final row in rows) {
      _queue.add(DownloadItemDart.fromJson(row));
    }
    _emitState();
  }

  Future<List<Map<String, dynamic>>> getDownloads() async {
    return _queue.map((d) => {
      'id': d.id,
      'trackId': d.trackId,
      'path': d.path,
      'image': d.imageUrl,
      'private': d.private,
      'title': d.title,
      'quality': d.quality,
      'state': d.state.index,
    }).toList();
  }

  Future<void> start() async {
    running = true;
    _processQueue();
    _emitState();
  }

  Future<void> stop() async {
    running = false;
    _emitState();
  }

  Future<void> retryFailed() async {
    for (final item in _queue) {
      if (item.state == DownloadStateDart.error ||
          item.state == DownloadStateDart.deezerError) {
        item.state = DownloadStateDart.none;
        await _db?.update('Downloads', {'state': 0},
            where: 'id == ?', whereArgs: [item.id]);
      }
    }
    if (running) _processQueue();
  }

  Future<void> removeDownload(int id) async {
    _queue.removeWhere((d) =>
        d.id == id &&
        d.state != DownloadStateDart.downloading &&
        d.state != DownloadStateDart.post);
    await _db?.delete('Downloads', where: 'id == ?', whereArgs: [id]);
    _emitState();
  }

  Future<void> removeByState(DownloadStateDart state) async {
    _queue.removeWhere((d) => d.state == state);
    await _db?.delete('Downloads',
        where: 'state == ?', whereArgs: [state.index]);
    _emitState();
  }

  void updateSettings({String? arl, String? licenseToken}) {
    _arl = arl;
    _licenseToken = licenseToken;
  }

  // ---------------------------------------------------------------
  // Internal queue processing
  // ---------------------------------------------------------------

  void _processQueue() {
    if (!running) return;

    for (final item in _queue) {
      if (_activeCount >= _maxConcurrent) break;
      if (item.state != DownloadStateDart.none) continue;

      item.state = DownloadStateDart.downloading;
      _activeCount++;
      _runDownload(item).then((_) {
        _activeCount--;
        _processQueue();
        _emitState();
      });
    }

    // All done
    if (_activeCount == 0 && queueSize == 0) {
      running = false;
      _emitState();
    }
  }

  Future<void> _runDownload(DownloadItemDart item) async {
    try {
      await _downloadTrack(item);
    } catch (e, st) {
      _log.severe('Download failed for ${item.trackId}', e, st);
      item.state = DownloadStateDart.error;
      await _updateDb(item);
    }
    _emitProgress(item);
  }

  Future<void> _downloadTrack(DownloadItemDart item) async {
    // Ensure authorized
    if (!_authorized) {
      await _authorize();
    }

    // Resolve CDN URL with quality fallback
    final cdnUrl = await _getCdnUrl(item);
    if (cdnUrl == null) {
      item.state = DownloadStateDart.deezerError;
      await _updateDb(item);
      _emitProgress(item);
      return;
    }

    // Generate output file path
    final outPath = item.private
        ? p.join(_offlinePath!, item.trackId)
        : _resolvePath(item);
    final tmpPath = p.join(
        (await getTemporaryDirectory()).path, '${item.id}.ENC');

    // Create parent directories
    await Directory(p.dirname(outPath)).create(recursive: true);

    // Download (with resume support)
    final tmpFile = File(tmpPath);
    final startByte = await tmpFile.exists() ? await tmpFile.length() : 0;

    final cdnRequest = http.Request('GET', Uri.parse(cdnUrl));
    cdnRequest.headers['User-Agent'] =
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36';
    cdnRequest.headers['Range'] = 'bytes=$startByte-';

    final response = await http.Client().send(cdnRequest);
    item.filesize = startByte + (response.contentLength ?? 1);

    final sink = tmpFile.openWrite(mode: FileMode.append);
    int received = startByte;

    await for (final chunk in response.stream) {
      if (!running) {
        await sink.close();
        item.state = DownloadStateDart.none;
        return;
      }
      sink.add(chunk);
      received += chunk.length;
      item.received = received;
      _emitProgress(item);
    }
    await sink.flush();
    await sink.close();

    // Post-processing: Decrypt
    item.state = DownloadStateDart.post;
    _emitProgress(item);

    final decPath = tmpPath + '.DEC';
    await DeezerDecryptorDart.decryptFile(tmpPath, decPath, item.streamTrackId);
    await tmpFile.delete();

    // Move to final destination
    final decFile = File(decPath);
    final outFile = File(outPath);
    if (await outFile.exists()) {
      item.state = DownloadStateDart.done;
      await decFile.delete();
      await _updateDb(item);
      return;
    }

    try {
      await decFile.rename(outPath);
    } catch (_) {
      // Cross-device rename fallback
      await decFile.copy(outPath);
      await decFile.delete();
    }

    // Download cover art for public tracks
    if (!item.private && item.imageUrl != null) {
      try {
        final coverPath =
            p.join(p.dirname(outPath), 'cover.jpg');
        if (!await File(coverPath).exists() && item.imageUrl!.isNotEmpty) {
          final coverResp = await http.get(Uri.parse(item.imageUrl!));
          if (coverResp.statusCode == 200) {
            await File(coverPath).writeAsBytes(coverResp.bodyBytes);
          }
        }
      } catch (e) {
        _log.warning('Error downloading cover: $e');
      }
    }

    item.state = DownloadStateDart.done;
    await _updateDb(item);
  }

  String _resolvePath(DownloadItemDart item) {
    // Mirrors Deezer.java::generateFilename() — variables already expanded
    // by download.dart before being passed to the engine
    String path = item.path;
    if (!item.path.contains('.')) {
      // Add extension based on quality
      path = item.quality == 9 ? '$path.flac' : '$path.mp3';
    }
    return path;
  }

  Future<void> _authorize() async {
    try {
      // Build auth header from ARL
      final response = await http.post(
        Uri.https('www.deezer.com', '/ajax/gw-light.php', {
          'method': 'deezer.getUserData',
          'api_version': '1.0',
          'api_token': 'null',
          'input': '3',
        }),
        headers: {
          'Cookie': 'arl=$_arl',
          'User-Agent':
              'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36',
        },
      );
      final body = jsonDecode(response.body);
      _licenseToken =
          body['results']?['USER']?['OPTIONS']?['license_token'] as String?;
      _authorized = true;
    } catch (e) {
      _log.warning('Authorization failed: $e');
    }
  }

  Future<String?> _getCdnUrl(DownloadItemDart item) async {
    if (_licenseToken == null) return null;

    final formatMap = {9: 'FLAC', 3: 'MP3_320', 1: 'MP3_128'};
    int quality = item.quality;

    while (quality >= 1) {
      final format = formatMap[quality] ?? 'MP3_128';
      final payload = jsonEncode({
        'license_token': _licenseToken,
        'media': [
          {
            'type': 'FULL',
            'formats': [
              {'cipher': 'BF_CBC_STRIPE', 'format': format}
            ]
          }
        ],
        'track_tokens': [item.trackToken]
      });

      try {
        final response = await http.post(
          Uri.parse('https://media.deezer.com/v1/get_url'),
          headers: {
            'Cookie': 'arl=$_arl',
            'Content-Type': 'application/json',
          },
          body: payload,
        );

        final body = jsonDecode(response.body);
        final dataArray = body['data'] as List?;
        if (dataArray != null && dataArray.isNotEmpty) {
          final media = dataArray[0]['media'] as List?;
          if (media != null && media.isNotEmpty) {
            final sources = media[0]['sources'] as List?;
            if (sources != null && sources.isNotEmpty) {
              return sources[0]['url'] as String;
            }
          }
        }
      } catch (e) {
        _log.warning('Error getting CDN URL at quality $quality: $e');
      }

      // Fallback to lower quality
      if (quality == 9) {
        quality = 3;
      } else if (quality == 3) {
        quality = 1;
      } else {
        break;
      }
    }
    return null;
  }

  Future<void> _updateDb(DownloadItemDart item) async {
    await _db?.update(
      'Downloads',
      {'state': item.state.index, 'quality': item.quality},
      where: 'id == ?',
      whereArgs: [item.id],
    );
  }

  void _emitProgress(DownloadItemDart item) {
    _progressController.add(DownloadProgressDart(
        item.id, item.state, item.received, item.filesize, item.quality));
  }

  void _emitState() {
    _stateController.add({
      'action': 'onStateChange',
      'running': running,
      'queueSize': queueSize,
    });
  }

  void dispose() {
    _progressController.close();
    _stateController.close();
  }
}

/// Singleton download engine instance for Windows/Desktop
final DownloadEngineDart downloadEngineDart = DownloadEngineDart();
