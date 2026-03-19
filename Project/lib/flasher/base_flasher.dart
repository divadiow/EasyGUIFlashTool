/// Abstract base flasher ported from C# `BaseFlasher.cs`.
///
/// Provides logging, configuration, and the virtual interface for
/// chip-specific flasher implementations.
library;

import 'dart:typed_data';
import '../serial/serial_transport.dart';
import '../models/log_level.dart';

export '../models/log_level.dart';

// ─── Enums ──────────────────────────────────────────────────────────────────

/// Internal chip type used by the flasher protocol layer.
enum BKType {
  bk7231t, bk7231u, bk7231n, bk7231m,
  bk7238, bk7236, bk7252, bk7252n, bk7258,
  bl602, bl702, bl616,
  esp32, esp32s3, esp32c3,
  w800, w600, rtl87x0c,
  detect, invalid;

  /// Human-readable chip name matching C# BK7231GUIFlashTool style.
  /// Derives uppercase name automatically from the Dart enum name.
  String get displayName => name.toUpperCase();

  @override
  String toString() => displayName;
}

/// Write mode for combined read-and-write operations.
enum WriteMode {
  readAndWrite,
  onlyWrite,
  onlyOBKConfig,
  onlyErase,
}

// ─── Callbacks ──────────────────────────────────────────────────────────────

/// Callback for log messages.
typedef FlasherLogCallback = void Function(String message, LogLevel level);

/// Callback for progress updates.
typedef FlasherProgressCallback = void Function(int current, int total);

/// Callback for state changes (e.g. "Connecting…", "Writing sector 5…").
typedef FlasherStateCallback = void Function(String state);

// ─── Base class ─────────────────────────────────────────────────────────────

/// Base class for all chip flashers.
///
/// Subclasses override [doRead], [doWrite], [doErase] etc. to implement
/// the actual protocol.
class BaseFlasher {
  /// Serial transport (platform-agnostic).
  final SerialTransport transport;

  // ── Callbacks ──────────────────────────────────────────────────────────

  FlasherLogCallback? onLog;
  FlasherProgressCallback? onProgress;
  FlasherStateCallback? onState;

  // ── Configuration ──────────────────────────────────────────────────────

  BKType chipType;
  int baudrate;
  String? backupName;
  bool bSkipKeyCheck = false;
  bool bIgnoreCRCErr = false;
  bool bOverwriteBootloader = false;
  double cfgReadTimeOutMultForLoop = 1.0;
  int cfgReadReplyStyle = 0;

  /// Set by the UI to request cancellation.
  bool isCancelled = false;

  /// Source firmware file name, set by the UI before write operations.
  /// Used by flashers (e.g. WMFlasher) that need the extension to choose
  /// the correct write path (.fls vs .bin).
  String? sourceFileName;

  BaseFlasher({
    required this.transport,
    this.chipType = BKType.bk7231n,
    this.baudrate = 921600,
  });

  // ── Logging helpers (mirror C# addLog / addError / etc.) ───────────────

  void addLog(String s) => onLog?.call(s, LogLevel.info);
  void addLogLine(String s) => onLog?.call('$s\n', LogLevel.info);
  void addError(String s) => onLog?.call(s, LogLevel.error);
  void addErrorLine(String s) => onLog?.call('$s\n', LogLevel.error);
  void addSuccess(String s) => onLog?.call(s, LogLevel.success);
  void addWarning(String s) => onLog?.call(s, LogLevel.warning);
  void addWarningLine(String s) => onLog?.call('$s\n', LogLevel.warning);

  void setProgress(int cur, int max) => onProgress?.call(cur, max);
  void setState(String s) => onState?.call(s);

  // ── Utility ───────────────────────────────────────────────────────────

  String formatHex(int i) => '0x${i.toRadixString(16).toUpperCase()}';

  String hashToStr(Uint8List data) =>
      data.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join();

  // ── Virtual methods for subclasses ────────────────────────────────────

  /// Read [sectors] sectors starting at [startSector].
  Future<void> doRead({int startSector = 0, int sectors = 10, bool fullRead = false}) async {}

  /// Write [data] starting at [startSector].
  Future<void> doWrite(int startSector, Uint8List data) async {}

  /// Erase [sectors] sectors starting at [startSector].
  Future<bool> doErase({int startSector = 0, int sectors = 10, bool eraseAll = false}) async => false;

  /// Get the data from the last read.
  Uint8List? getReadResult() => null;

  /// Close the serial port.
  Future<void> closePort() async {
    await transport.disconnect();
  }

  /// Dispose of resources.
  void dispose() {
    // Subclasses may override.
  }
}
