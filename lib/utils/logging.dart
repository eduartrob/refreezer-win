import 'dart:async';
import 'dart:collection';
import 'dart:developer';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

class LogQueueManager {
  final File logFile;
  final Queue<String> _logQueue = Queue<String>();
  bool _isWriting = false;

  LogQueueManager(this.logFile);

  void enqueue(String logEntry) {
    _logQueue.add(logEntry);
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isWriting) return;
    _isWriting = true;

    while (_logQueue.isNotEmpty) {
      String logEntry = _logQueue.removeFirst();
      log(logEntry);
      try {
        await logFile.writeAsString(logEntry, mode: FileMode.append);
      } catch (e) {
        log('Error writing to log file: $e');
      }
    }

    _isWriting = false;
  }
}

// Global reference so emergency writes work before Logger is set up
File? _activeLogFile;

Future<void> initializeLogging() async {
  final File logFile = await _resolveLogFile();
  _activeLogFile = logFile;

  if (!await logFile.exists()) {
    await logFile.create(recursive: true);
  }

  // Clear old session data and write header
  await logFile.writeAsString(
      '=== ReFreezer Log — ${DateTime.now()} ===\n'
      'Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n'
      'Executable: ${Platform.resolvedExecutable}\n'
      '============================================\n');

  Logger.root.level = Level.ALL;

  final logQueueManager = LogQueueManager(logFile);

  Logger.root.onRecord.listen((record) {
    final logMessage = _formatLogMessage(record);
    logQueueManager.enqueue(logMessage);
  });

  // Capture ALL uncaught Flutter framework errors
  FlutterError.onError = (FlutterErrorDetails details) {
    final msg = 'FLUTTER_ERROR: ${details.exceptionAsString()}\n'
        'Stack: ${details.stack}\n';
    logQueueManager.enqueue(msg);
    FlutterError.presentError(details);
  };

  // Capture ALL uncaught Dart async errors (Zone errors, plugin exceptions)
  PlatformDispatcher.instance.onError = (error, stack) {
    final msg = 'DART_UNCAUGHT_ERROR: $error\nStack: $stack\n';
    logQueueManager.enqueue(msg);
    return true; // Mark as handled so app doesn't crash
  };
}

/// Emergency log write — used before Logger is initialized (e.g. in main())
void emergencyLog(String message) {
  final timestamp = DateTime.now().toIso8601String();
  final entry = 'EMERGENCY [$timestamp]: $message\n';
  log(entry); // dart:developer console
  try {
    _activeLogFile?.writeAsStringSync(entry, mode: FileMode.append);
  } catch (_) {}
}

/// Returns a platform-appropriate log file path.
/// - Android: external storage (original behavior) with fallback
/// - Desktop: next to the executable so user can find it easily
Future<File> _resolveLogFile() async {
  if (Platform.isAndroid) {
    final dir = await getExternalStorageDirectory();
    if (dir != null) {
      return File(p.join(dir.path, 'refreezer.log'));
    }
    // Fallback to app documents if external storage not available
    final docs = await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, 'refreezer.log'));
  }

  // Desktop: place log file next to the .exe for easy access
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  return File(p.join(exeDir, 'refreezer.log'));
}

String _formatLogMessage(LogRecord record) {
  final buffer = StringBuffer();
  buffer.write('[${record.level.name}] ${record.time}: ${record.message}\n');

  if (record.error != null) {
    buffer.write('  Error: ${record.error}\n');
  }

  if (record.stackTrace != null) {
    buffer.write('  Stack: ${record.stackTrace}\n');
  }

  return buffer.toString();
}
