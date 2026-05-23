import 'dart:io';

/// Cross-platform helpers for platform detection and path resolution.
class PlatformUtils {
  /// True on Windows, Linux, macOS
  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// True on Android or iOS
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  /// Default music folder for downloads based on platform.
  /// Returns a platform-appropriate path that doesn't require special permissions.
  static String get defaultDownloadPath {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'] ?? 'C:\\Users\\User';
      return '$userProfile\\Music\\ReFreezer';
    } else if (Platform.isLinux || Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '/home/user';
      return '$home/Music/ReFreezer';
    }
    // Android: returned by path_provider
    return '';
  }

  /// True when the current context needs mouse/keyboard UX adaptations
  static bool get needsDesktopUI => isDesktop;
}
