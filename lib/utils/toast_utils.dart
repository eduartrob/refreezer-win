import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';

import '../utils/navigator_keys.dart';

/// Cross-platform toast/snackbar helper.
///
/// - Android: uses native Fluttertoast (original behavior)
/// - Desktop (Windows/Linux/macOS): uses SnackBar via ScaffoldMessenger
void showToast(String message, {BuildContext? context}) {
  if (Platform.isAndroid || Platform.isIOS) {
    Fluttertoast.showToast(
      msg: message,
      gravity: ToastGravity.BOTTOM,
      toastLength: Toast.LENGTH_SHORT,
    );
    return;
  }

  // Desktop: use SnackBar
  final ctx = context ?? mainNavigatorKey.currentContext;
  if (ctx == null) return;

  ScaffoldMessenger.of(ctx).showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.only(bottom: 16, left: 16, right: 16),
    ),
  );
}

/// Cross-platform clipboard + toast: copies [text] and notifies the user.
Future<void> copyToClipboard(String text, {BuildContext? context, String? message}) async {
  await Clipboard.setData(ClipboardData(text: text));
  showToast(message ?? 'Copied to clipboard', context: context);
}
