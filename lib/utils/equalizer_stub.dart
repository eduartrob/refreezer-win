// Stub for equalizer_flutter on non-Android platforms.
// All methods are no-ops — the equalizer is Android-only.
class EqualizerFlutter {
  static Future<void> open(int sessionId) async {}
  static Future<void> setAudioSessionId(int sessionId) async {}
  static Future<void> removeAudioSessionId(int sessionId) async {}
}
