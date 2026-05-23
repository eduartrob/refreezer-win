// Stub import for Android Auto on non-Android platforms.
// This file is never compiled on Android — it only satisfies
// the import when equalizer_flutter is unavailable.

import 'package:audio_service/audio_service.dart';

class AndroidAuto {
  static const String prefix = 'android_auto://';

  Future<void> playItem(String mediaId) async {}
  Future<List<MediaItem>> getScreen(String parentMediaId) async => [];
}
