import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'blowfish.dart';

/// Dart port of DeezerDecryptor.java
/// Handles Blowfish-CBC decryption of Deezer audio streams.
/// Every 3rd 2048-byte chunk is encrypted; the rest are plain.
class DeezerDecryptorDart {
  static const int _chunkSize = 2048;
  // Secret key used to derive the per-track blowfish key
  static const String _secret = 'g4el58wc0zvf9na1';

  /// Derives the Blowfish decryption key for a given trackId.
  /// Mirrors DeezerDecryptor.java::getKey()
  static Uint8List getKey(String trackId) {
    final md5hex = md5.convert(utf8.encode(trackId)).toString();
    final keyBytes = List<int>.generate(16, (i) {
      return md5hex.codeUnitAt(i) ^
          md5hex.codeUnitAt(i + 16) ^
          _secret.codeUnitAt(i);
    });
    return Uint8List.fromList(keyBytes);
  }

  /// Decrypts a Deezer chunk (2048 bytes) using Blowfish-CBC.
  /// IV is 8 zero bytes, matching the Java implementation.
  static Uint8List decryptChunk(Uint8List key, Uint8List chunk) {
    final blowfish = Blowfish(key);
    final iv = Uint8List(8); // IV = 0x0000000000000000
    return blowfish.decrypt(chunk, iv);
  }

  /// Decrypts a fully downloaded Deezer file from [inputPath] to [outputPath].
  /// Every 3rd 2048-byte chunk is decrypted; others pass through unchanged.
  static Future<void> decryptFile(
      String inputPath, String outputPath, String trackId) async {
    final key = getKey(trackId);
    final inputBytes = await File(inputPath).readAsBytes();
    final sink = File(outputPath).openWrite();

    int counter = 0;
    int offset = 0;

    while (offset < inputBytes.length) {
      final end = (offset + _chunkSize).clamp(0, inputBytes.length).toInt();
      final chunk = inputBytes.sublist(offset, end);

      if (counter % 3 == 0 && chunk.length == _chunkSize) {
        sink.add(decryptChunk(key, Uint8List.fromList(chunk)));
      } else {
        sink.add(chunk);
      }

      counter++;
      offset += _chunkSize;
    }

    await sink.flush();
    await sink.close();
  }

  /// Decrypts a single 2048-byte chunk for streaming use (StreamServerDart).
  static Uint8List decryptChunkById(String trackId, Uint8List data) {
    return decryptChunk(getKey(trackId), data);
  }
}
