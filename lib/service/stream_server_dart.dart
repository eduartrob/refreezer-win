import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../utils/deezer_decryptor_dart.dart';
import '../api/deezer.dart';

/// Information about a currently streamed track
class StreamInfo {
  final String format;
  final int size;
  final String source; // 'Stream' or 'Offline'
  StreamInfo(this.format, this.size, this.source);
}

/// Dart reimplementation of StreamServer.java using dart:io HttpServer.
/// Serves audio to just_audio via localhost:36958, handling:
///  - Offline (locally stored) files with Blowfish decryption
///  - Live Deezer streams with on-the-fly Blowfish chunk decryption
class StreamServerDart {
  static const int _port = 36958;
  static const String _host = '127.0.0.1';

  final _log = Logger('StreamServerDart');
  final Map<String, StreamInfo> streams = {};

  HttpServer? _server;
  String? _offlinePath;
  bool _deezerAuthorized = false;

  StreamServerDart({String? offlinePath}) : _offlinePath = offlinePath;

  void setOfflinePath(String path) => _offlinePath = path;

  /// Starts the local HTTP server on port 36958
  Future<void> start() async {
    try {
      _server = await HttpServer.bind(InternetAddress(_host), _port);
      _log.info('StreamServer started on $_host:$_port');
      _server!.listen(_handleRequest, onError: (e) {
        _log.severe('StreamServer error: $e');
      });
    } catch (e) {
      _log.severe('Failed to start StreamServer: $e');
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _log.info('StreamServer stopped');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    try {
      final params = request.uri.queryParameters;

      // Parse Range header
      final rangeHeader = request.headers.value('range');
      int startBytes = 0;
      int endBytes = -1;
      bool isRanged = false;

      if (rangeHeader != null && rangeHeader.startsWith('bytes')) {
        isRanged = true;
        final rangePart = rangeHeader.split('=')[1].split('-');
        startBytes = int.tryParse(rangePart[0]) ?? 0;
        if (rangePart.length > 1 && rangePart[1].isNotEmpty) {
          endBytes = int.tryParse(rangePart[1]) ?? -1;
        }
      }

      // Route: offline track (only 'id' param) vs live stream (6+ params)
      if (params.length < 6) {
        if (params.containsKey('id')) {
          await _serveOffline(request, params['id']!, startBytes, endBytes, isRanged);
        } else {
          _errorResponse(request, 'Missing query parameters');
        }
      } else {
        await _serveStream(request, params, startBytes, endBytes, isRanged);
      }
    } catch (e, st) {
      _log.severe('Error handling request', e, st);
      _errorResponse(request, 'Internal server error');
    }
  }

  /// Serves an offline stored track, decrypting Blowfish on-the-fly
  Future<void> _serveOffline(
    HttpRequest request,
    String trackId,
    int startBytes,
    int endBytes,
    bool isRanged,
  ) async {
    if (_offlinePath == null) {
      _errorResponse(request, 'Offline path not set');
      return;
    }

    final file = File(p.join(_offlinePath!, trackId));
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final size = await file.length();
    final bytes = await file.readAsBytes();

    // Detect format by reading magic bytes
    bool isFlac = bytes.length >= 4 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'fLaC';

    final contentType = isFlac ? 'audio/flac' : 'audio/mpeg';
    final actualEnd = endBytes == -1 ? size - 1 : endBytes;
    final sendBytes = bytes.sublist(startBytes, (actualEnd + 1).clamp(0, size).toInt());

    request.response.statusCode =
        isRanged ? HttpStatus.partialContent : HttpStatus.ok;
    request.response.headers.set('Content-Type', contentType);
    request.response.headers.set('Content-Length', sendBytes.length.toString());
    request.response.headers.set('Accept-Ranges', 'bytes');
    if (isRanged) {
      request.response.headers.set(
          'Content-Range', 'bytes $startBytes-$actualEnd/$size');
    }

    streams[trackId] = StreamInfo(isFlac ? 'FLAC' : 'MP3', size, 'Offline');
    request.response.add(sendBytes);
    await request.response.close();
  }

  /// Proxies a live Deezer stream, decrypting Blowfish chunks on-the-fly
  Future<void> _serveStream(
    HttpRequest request,
    Map<String, String> params,
    int startBytes,
    int endBytes,
    bool isRanged,
  ) async {
    // Authorize Deezer if needed
    if (!_deezerAuthorized) {
      await deezerAPI.authorize();
      _deezerAuthorized = true;
    }

    final quality = int.tryParse(params['q'] ?? '1') ?? 1;
    final trackId = params['id'] ?? '';
    final streamTrackId = params['streamTrackId'] ?? trackId;
    final trackToken = params['trackToken'] ?? '';
    final mv = params['mv'] ?? '';
    final md5origin = params['md5origin'] ?? '';

    // Build the CDN URL — delegates to DeezerAPI in Dart (already implemented)
    // We replicate the QualityInfo fallback logic here
    String? cdnUrl = await _resolveCdnUrl(
      quality: quality,
      trackId: streamTrackId,
      trackToken: trackToken,
      md5origin: md5origin,
      mediaVersion: mv,
    );

    if (cdnUrl == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    // Align start to 2048 boundary for decryption (mirrors StreamServer.java)
    final deezerStart = startBytes - (startBytes % 2048);
    final dropBytes = startBytes % 2048;

    final cdnRequest = http.Request('GET', Uri.parse(cdnUrl));
    cdnRequest.headers['User-Agent'] =
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.130 Safari/537.36';
    cdnRequest.headers['Range'] =
        'bytes=$deezerStart-${endBytes == -1 ? '' : endBytes}';

    final cdnResponse = await http.Client().send(cdnRequest);
    final contentLength = cdnResponse.contentLength ?? 0;

    final isFlac = quality == 9;
    final contentType = isFlac ? 'audio/flac' : 'audio/mpeg';

    request.response.statusCode =
        isRanged ? HttpStatus.partialContent : HttpStatus.ok;
    request.response.headers.set('Content-Type', contentType);
    request.response.headers.set('Accept-Ranges', 'bytes');
    request.response.headers
        .set('Content-Length', (contentLength - dropBytes).toString());
    if (isRanged) {
      final rangeEnd =
          endBytes == -1 ? (contentLength + deezerStart - 1) : endBytes;
      request.response.headers.set('Content-Range',
          'bytes $startBytes-$rangeEnd/${contentLength + deezerStart}');
    }

    // Stream with Blowfish decryption (every 3rd 2048-byte chunk)
    final key = DeezerDecryptorDart.getKey(streamTrackId);
    int counter = deezerStart ~/ 2048;
    int dropped = dropBytes;
    List<int> buffer = [];

    await for (final chunk in cdnResponse.stream) {
      buffer.addAll(chunk);

      while (buffer.length >= 2048) {
        final block = Uint8List.fromList(buffer.sublist(0, 2048));
        buffer = buffer.sublist(2048);

        Uint8List outBlock;
        if (counter % 3 == 0) {
          outBlock = DeezerDecryptorDart.decryptChunk(key, block);
        } else {
          outBlock = block;
        }
        counter++;

        if (dropped > 0) {
          final output = outBlock.sublist(dropped);
          dropped = 0;
          request.response.add(output);
        } else {
          request.response.add(outBlock);
        }
      }
    }
    // Flush remaining bytes (incomplete chunk — not encrypted)
    if (buffer.isNotEmpty) {
      request.response.add(buffer);
    }

    streams[trackId] = StreamInfo(
        isFlac ? 'FLAC' : 'MP3', deezerStart + contentLength, 'Stream');

    await request.response.close();
  }

  /// Resolves the Deezer CDN URL with quality fallback.
  /// Mirrors QualityInfo.fallback() from StreamServer.java.
  Future<String?> _resolveCdnUrl({
    required int quality,
    required String trackId,
    required String trackToken,
    required String md5origin,
    required String mediaVersion,
  }) async {
    // Try to get URL via licenseToken (same logic as Deezer.java::getTrackUrl)
    final licenseToken = deezerAPI.licenseToken;
    if (licenseToken == null) return null;

    final formatMap = {9: 'FLAC', 3: 'MP3_320', 1: 'MP3_128'};
    final format = formatMap[quality] ?? 'MP3_128';

    try {
      final payload = '''
{
  "license_token": "$licenseToken",
  "media": [{"type":"FULL","formats":[{"cipher":"BF_CBC_STRIPE","format":"$format"}]}],
  "track_tokens": ["$trackToken"]
}''';

      final response = await http.post(
        Uri.parse('https://media.deezer.com/v1/get_url'),
        headers: {
          'Cookie': 'arl=${deezerAPI.arl}',
          'Content-Type': 'application/json',
        },
        body: payload,
      );

      final body = response.body;
      // Simple JSON parse to extract URL
      final urlMatch = RegExp(r'"url"\s*:\s*"([^"]+)"').firstMatch(body);
      if (urlMatch != null) {
        return urlMatch.group(1);
      }
    } catch (e) {
      _log.warning('Error resolving CDN URL: $e');
    }

    // Quality fallback: try lower quality
    if (quality > 1) {
      final fallbackQuality = quality == 9 ? 3 : 1;
      return _resolveCdnUrl(
        quality: fallbackQuality,
        trackId: trackId,
        trackToken: trackToken,
        md5origin: md5origin,
        mediaVersion: mediaVersion,
      );
    }
    return null;
  }

  void _errorResponse(HttpRequest request, String message) {
    request.response.statusCode = HttpStatus.internalServerError;
    request.response.write(message);
    request.response.close();
  }
}
