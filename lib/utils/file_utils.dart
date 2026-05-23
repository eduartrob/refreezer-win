import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class FileUtils {
  // On desktop (Windows/Linux/macOS) storage permissions are not required.
  // The guards below allow the Android code to remain intact while the desktop
  // path always returns `true`.

  static Future<bool> checkExternalStoragePermissions(
      Future<bool> Function() showDialogCallback) async {
    // Desktop: no permission system, always granted
    if (!Platform.isAndroid) return true;

    PermissionStatus status = PermissionStatus.denied;
    bool permissionGranted = false;
    final DeviceInfoPlugin deviceInfoPlugin = DeviceInfoPlugin();
    final AndroidDeviceInfo info = await deviceInfoPlugin.androidInfo;

    // Starting at compileSdkVersion 30, storage permissions changed
    if ((info.version.sdkInt) < 30) {
      status = await Permission.storage.request();
    } else {
      status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) {
        if (await showDialogCallback()) {
          status = await Permission.manageExternalStorage.request();
        } else {
          return false;
        }
      }
    }

    if (status.isGranted || status.isLimited) {
      permissionGranted = true;
    } else if (status.isPermanentlyDenied && await showDialogCallback()) {
      permissionGranted = await openAppSettings();
    }

    return permissionGranted;
  }

  static Future<bool> checkStoragePermission() async {
    // Desktop: always granted
    if (!Platform.isAndroid) return true;

    bool permissionGranted = false;
    DeviceInfoPlugin deviceInfoPlugin = DeviceInfoPlugin();
    AndroidDeviceInfo android = await deviceInfoPlugin.androidInfo;
    if (android.version.sdkInt < 30) {
      if (await Permission.storage.request().isGranted) {
        permissionGranted = true;
      } else if (await Permission.storage.request().isPermanentlyDenied) {
        permissionGranted = await openAppSettings();
      } else if (await Permission.storage.request().isDenied) {
        permissionGranted = false;
      }
    } else {
      // From sdk version 33 (android 13) and up, storage permissions are implicitly granted for own files
      permissionGranted = true;
    }
    return permissionGranted;
  }
}

