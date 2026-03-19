/// Command-line runner for EasyGUIFlashTool.
///
/// Ported from C# `CommandLineRunner.cs` in BK7231GUIFlashTool.
/// Allows flash operations without the Flutter GUI, driven entirely
/// from command-line arguments.
library;

import 'dart:io';
import 'dart:typed_data';

import '../flasher/base_flasher.dart';
import '../flasher/bk7231_flasher.dart';
import '../flasher/bl602_flasher.dart';
import '../flasher/esp32_flasher.dart';
import '../flasher/rtl87x0c_flasher.dart';
import '../models/chip_platform.dart';
import '../models/log_level.dart';
import '../serial/serial_io_mobile.dart' as io;

// ─── Operation enum ─────────────────────────────────────────────────────────

enum _CliOperation {
  none,
  read,
  write,
  customRead,
  customWrite,
  test,
  help,
}

// ─── Public API ─────────────────────────────────────────────────────────────

class CommandLineRunner {
  /// Returns true when CLI mode should be used (i.e. arguments were passed).
  static bool shouldRunCli(List<String> args) => args.isNotEmpty;

  /// Run the CLI. This method never returns — it calls [exit] at the end.
  static Future<void> run(List<String> args) async {
    // Ensure stdout/stderr are flushed on exit.
    var operation = _CliOperation.none;
    String? port;
    int baud = 921600;
    String? chipName;
    int ofs = -1;
    int len = -1;
    String outputName = 'cliBackup';
    String? writeFile;

    // ── Parse arguments (esptool-style + legacy aliases) ─────────────
    for (int i = 0; i < args.length; i++) {
      final arg = args[i].toLowerCase();
      switch (arg) {
        // --- Commands ---
        case 'fread':
        case '-read':
          operation = _CliOperation.read;
          break;
        case 'fwrite':
        case '-write':
          operation = _CliOperation.write;
          if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
            writeFile = args[++i];
          }
          break;
        case 'read_flash':
        case '-cread':
          operation = _CliOperation.customRead;
          break;
        case 'write_flash':
        case '-cwrite':
          operation = _CliOperation.customWrite;
          if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
            writeFile = args[++i];
          }
          break;
        case 'test':
        case '-test':
          operation = _CliOperation.test;
          break;

        // --- Options ---
        case '--port':
        case '-p':
        case '-port':
          if (i + 1 < args.length) port = args[++i];
          break;
        case '--baud':
        case '-b':
        case '-baud':
          if (i + 1 < args.length) baud = int.tryParse(args[++i]) ?? baud;
          break;
        case '--chip':
        case '-chip':
          if (i + 1 < args.length) chipName = args[++i];
          break;
        case '--addr':
        case '-ofs':
          if (i + 1 < args.length) ofs = _parseInt(args[++i]);
          break;
        case '--size':
        case '-len':
          if (i + 1 < args.length) len = _parseInt(args[++i]);
          break;
        case '--out':
        case '-out':
          if (i + 1 < args.length) outputName = args[++i];
          break;

        case '--help':
        case '-help':
        case '-h':
        case '/?':
          operation = _CliOperation.help;
          break;

        default:
          stderr.writeln('Unknown argument: ${args[i]}');
          break;
      }
    }

    // ── Help / no-op ─────────────────────────────────────────────────
    if (operation == _CliOperation.help || operation == _CliOperation.none) {
      _printHelp();
      exit(operation == _CliOperation.help ? 0 : 1);
    }

    // ── Validate required arguments ──────────────────────────────────
    if (port == null) {
      stdout.writeln('[AutoSelect] No port argument, attempting auto-selection...');
      port = _getFirstAvailablePort();
      if (port != null) {
        stdout.writeln('No port specified, auto-selected: $port');
        await Future.delayed(const Duration(milliseconds: 500));
      } else {
        stderr.writeln('Error: --port is required. Use --help for usage.');
        exit(1);
      }
    }

    if (chipName == null) {
      stderr.writeln('Error: --chip is required. Use --help for usage.');
      exit(1);
    }

    if ((operation == _CliOperation.write ||
            operation == _CliOperation.customWrite) &&
        (writeFile == null || writeFile.isEmpty)) {
      stderr.writeln('Error: File path is required for write operations.');
      exit(1);
    }

    if ((operation == _CliOperation.customRead ||
            operation == _CliOperation.customWrite ||
            operation == _CliOperation.test) &&
        (ofs < 0 || len <= 0)) {
      stderr.writeln(
          'Error: --addr and --size are required for read_flash/write_flash/test operations. Use --help for usage.');
      exit(1);
    }

    // ── Resolve chip type ────────────────────────────────────────────
    final platform = _resolveChipPlatform(chipName);
    if (platform == null) {
      stderr.writeln("Error: Unknown chip type '$chipName'. Available types:");
      for (final p in ChipPlatform.values) {
        stderr.write('  ${p.displayName}');
      }
      stderr.writeln();
      exit(1);
    }

    final bkType = platform.bkType;
    if (bkType == null) {
      stderr.writeln(
          'Error: ${platform.displayName} is not supported — '
          'flasher not yet implemented in EasyGUIFlashTool.');
      exit(1);
    }

    // ── Execute ──────────────────────────────────────────────────────
    final exitCode = await _executeOperation(
      operation: operation,
      port: port,
      baud: baud,
      chipType: bkType,
      ofs: ofs,
      len: len,
      outputName: outputName,
      writeFile: writeFile,
    );
    exit(exitCode);
  }

  // ════════════════════════════════════════════════════════════════════════
  //  OPERATION DISPATCHER
  // ════════════════════════════════════════════════════════════════════════

  static Future<int> _executeOperation({
    required _CliOperation operation,
    required String port,
    required int baud,
    required BKType chipType,
    required int ofs,
    required int len,
    required String outputName,
    String? writeFile,
  }) async {
    // Create transport and flasher
    final transport = io.createSerialTransport();
    await transport.init();

    // Configure port and baud
    if (transport is dynamic) {
      try {
        (transport as dynamic).setPort(port);
      } catch (_) {}
      try {
        (transport as dynamic).setInitialBaudRate(baud);
      } catch (_) {}
    }

    // Select the right flasher based on chip type
    final bool isBL = chipType == BKType.bl602 ||
        chipType == BKType.bl702 ||
        chipType == BKType.bl616;
    final bool isESP = chipType == BKType.esp32;
    final bool isRTL87X0C = chipType == BKType.rtl87x0c;

    final BaseFlasher flasher;
    if (isESP) {
      flasher = ESPFlasher(
        transport: transport,
        chipType: chipType,
        baudrate: baud,
      );
    } else if (isRTL87X0C) {
      flasher = RTL87X0CFlasher(
        transport: transport,
        chipType: chipType,
        baudrate: baud,
      );
    } else if (isBL) {
      flasher = BL602Flasher(
        transport: transport,
        chipType: chipType,
        baudrate: baud,
      );
    } else {
      flasher = BK7231Flasher(
        transport: transport,
        chipType: chipType,
        baudrate: baud,
      );
    }

    // Wire logging to console
    flasher.onLog = (msg, level) {
      final text = msg.trimRight();
      if (text.isEmpty) return;
      if (level == LogLevel.error) {
        stderr.writeln(text);
      } else {
        stdout.writeln(text);
      }
    };
    flasher.onProgress = (current, total) {
      if (total > 0) {
        final pct = (current * 100 / total).toInt();
        stdout.write('\r  Progress: $current/$total ($pct%)');
        if (current >= total) stdout.writeln();
      }
    };
    flasher.onState = (msg) {
      stdout.writeln('[State] $msg');
    };

    // Handle Ctrl+C
    ProcessSignal.sigint.watch().listen((_) {
      stdout.writeln('\nCancelling operation...');
      flasher.isCancelled = true;
    });

    try {
      switch (operation) {
        case _CliOperation.read:
          return await _doRead(flasher, chipType, outputName);
        case _CliOperation.write:
          return await _doWrite(flasher, chipType, writeFile!);
        case _CliOperation.customRead:
          return await _doCustomRead(flasher, ofs, len, outputName);
        case _CliOperation.customWrite:
          return await _doCustomWrite(flasher, ofs, writeFile!);
        case _CliOperation.test:
          return await _doTest(flasher, ofs, len);
        default:
          stderr.writeln('Error: Unknown operation.');
          return 1;
      }
    } catch (e) {
      stderr.writeln('\nError: $e');
      return 1;
    } finally {
      await flasher.closePort();
      flasher.dispose();
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  OPERATIONS
  // ════════════════════════════════════════════════════════════════════════

  static Future<int> _doRead(
      BaseFlasher flasher, BKType chipType, String outputName) async {
    stdout.writeln('Starting full flash read...');

    const flashSize = 0x200000;
    const sectorSize = BK7231Flasher.sectorSize;
    final sectors = flashSize ~/ sectorSize;

    await flasher.doRead(startSector: 0, sectors: sectors, fullRead: true);

    final result = flasher.getReadResult();
    if (result != null && result.isNotEmpty) {
      final filename = _buildOutputFilename(outputName, chipType);
      await _saveToBackups(filename, result);
      stdout.writeln('\nRead completed successfully. Saved to: backups/$filename');
      return 0;
    } else {
      stderr.writeln('\nRead failed or was cancelled.');
      return 1;
    }
  }

  static Future<int> _doWrite(BaseFlasher flasher, BKType chipType, String writeFile) async {
    final file = File(writeFile);
    if (!file.existsSync()) {
      stderr.writeln('Error: File not found: $writeFile');
      return 1;
    }

    stdout.writeln('Starting write from $writeFile...');
    var data = Uint8List.fromList(await file.readAsBytes());
    stdout.writeln('Firmware size: ${data.length} bytes');

    int startSector = 0;
    // can't touch bootloader of BK7231T
    if (chipType == BKType.bk7231t || chipType == BKType.bk7231u) {
      final fwUpper = writeFile.toUpperCase();
      if (fwUpper.contains('_QIO_')) {
        // QIO binary includes bootloader — skip bootloader portion of data
        startSector = BK7231Flasher.bootloaderSize;
        if (data.length > BK7231Flasher.bootloaderSize) {
          data = Uint8List.sublistView(data, BK7231Flasher.bootloaderSize);
          stdout.writeln('Using hack to write QIO — just skip bootloader...');
          stdout.writeln('... so bootloader will not be overwritten!');
        }
      } else {
        // UA binary has no bootloader — write it at the bootloader end offset
        startSector = BK7231Flasher.bootloaderSize;
        stdout.writeln('UA binary — writing at bootloader end offset '
            '0x${startSector.toRadixString(16).toUpperCase()}');
      }
    }

    await flasher.doWrite(startSector, data);

    stdout.writeln('\nWrite completed successfully.');
    return 0;
  }

  static Future<int> _doCustomRead(
      BaseFlasher flasher, int ofs, int len, String outputName) async {
    stdout.writeln(
        'Starting custom read: offset=0x${ofs.toRadixString(16)}, '
        'length=0x${len.toRadixString(16)}...');

    final sectors = len ~/ BK7231Flasher.sectorSize;
    await flasher.doRead(startSector: ofs, sectors: sectors);

    final result = flasher.getReadResult();
    if (result != null && result.isNotEmpty) {
      final filename =
          '${outputName}_custom_0x${ofs.toRadixString(16)}_0x${len.toRadixString(16)}.bin';
      await _saveToBackups(filename, result);
      stdout.writeln(
          '\nCustom read completed successfully. Saved to: backups/$filename');
      return 0;
    } else {
      stderr.writeln('\nCustom read failed or was cancelled.');
      return 1;
    }
  }

  static Future<int> _doCustomWrite(
      BaseFlasher flasher, int ofs, String writeFile) async {
    final file = File(writeFile);
    if (!file.existsSync()) {
      stderr.writeln('Error: File not found: $writeFile');
      return 1;
    }

    stdout.writeln(
        'Starting custom write: offset=0x${ofs.toRadixString(16)}, '
        'file=$writeFile...');
    final data = Uint8List.fromList(await file.readAsBytes());
    await flasher.doWrite(ofs, data);

    stdout.writeln('\nCustom write completed successfully.');
    return 0;
  }

  static Future<int> _doTest(BaseFlasher flasher, int ofs, int len) async {
    stdout.writeln(
        'Starting Read/Write/Verify test at offset '
        '0x${ofs.toRadixString(16)}, length 0x${len.toRadixString(16)}...');

    // Generate test pattern
    final testPattern = Uint8List(len);
    for (int i = 0; i < len; i++) {
      testPattern[i] = i % 256;
    }

    final sectors = len ~/ BK7231Flasher.sectorSize;

    stdout.writeln('Step 1/3: Writing pattern...');
    await flasher.doWrite(ofs, testPattern);

    stdout.writeln('\nStep 2/3: Reading back...');
    await flasher.doRead(startSector: ofs, sectors: sectors);

    stdout.writeln('\nStep 3/3: Verifying...');
    final readData = flasher.getReadResult();

    if (readData == null || readData.isEmpty) {
      stderr.writeln('Error: No read data available for verification.');
      return 1;
    }

    final compareLen =
        testPattern.length < readData.length ? testPattern.length : readData.length;
    bool match = true;
    int mismatchCount = 0;
    for (int i = 0; i < compareLen; i++) {
      if (testPattern[i] != readData[i]) {
        if (mismatchCount < 5) {
          stderr.writeln(
              '  Mismatch at 0x${i.toRadixString(16)}: '
              'expected 0x${testPattern[i].toRadixString(16).padLeft(2, '0')}, '
              'got 0x${readData[i].toRadixString(16).padLeft(2, '0')}');
        }
        match = false;
        mismatchCount++;
      }
    }

    if (!match) {
      stderr.writeln(
          'FAIL: Verification failed with $mismatchCount mismatched byte(s).');
      return 1;
    }

    if (testPattern.length != readData.length) {
      stdout.writeln(
          'WARNING: Data matches but lengths differ '
          '(pattern=${testPattern.length}, read=${readData.length}).');
    }

    stdout.writeln(
        'SUCCESS: Verification passed! Read data matches written pattern.');
    return 0;
  }

  // ════════════════════════════════════════════════════════════════════════
  //  HELPERS
  // ════════════════════════════════════════════════════════════════════════

  static String? _getFirstAvailablePort() {
    try {
      final transport = io.createSerialTransport();
      if (transport is dynamic) {
        final List<String> ports =
            (transport as dynamic).getAvailablePorts() as List<String>;
        stdout.writeln('[AutoSelect] Found ports: ${ports.join(', ')}');
        ports.sort();
        if (ports.isNotEmpty) {
          stdout.writeln('[AutoSelect] Selected ${ports.first}');
          transport.dispose();
          return ports.first;
        }
      }
      transport.dispose();
    } catch (e) {
      stderr.writeln('[AutoSelect] Error: $e');
    }
    return null;
  }

  static ChipPlatform? _resolveChipPlatform(String chipName) {
    final lower = chipName.toLowerCase();
    for (final p in ChipPlatform.values) {
      if (p.displayName.toLowerCase() == lower || p.name.toLowerCase() == lower) {
        return p;
      }
    }
    return null;
  }

  static int _parseInt(String input) {
    if (input.toLowerCase().startsWith('0x')) {
      return int.parse(input.substring(2), radix: 16);
    }
    return int.parse(input);
  }

  static String _buildOutputFilename(String outputName, BKType chipType) {
    final now = DateTime.now();
    final dateStr = '${now.year}-${now.day}-${now.month}-'
        '${now.hour.toString().padLeft(2, '0')}-'
        '${now.minute.toString().padLeft(2, '0')}-'
        '${now.second.toString().padLeft(2, '0')}';
    return '${outputName}_${chipType.displayName}_$dateStr.bin';
  }

  static Future<void> _saveToBackups(String filename, Uint8List data) async {
    final dir = Directory('backups');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final file = File('${dir.path}${Platform.pathSeparator}$filename');
    await file.writeAsBytes(data);
  }

  static void _printHelp() {
    stdout.writeln('EasyGUI Flash Tool - Command Line Mode');
    stdout.writeln();
    stdout.writeln('Usage: easy_gui_flash_tool.exe [options] <command> [command options]');
    stdout.writeln();
    stdout.writeln('Commands:');
    stdout.writeln('  read_flash             Read flash region (requires --addr and --size)');
    stdout.writeln('  write_flash <file.bin>  Write to flash region (requires --addr and --size)');
    stdout.writeln('  fread                  Full flash read (backup entire chip)');
    stdout.writeln('  fwrite <file.bin>      Full flash write (write entire firmware)');
    stdout.writeln('  test                   Write/read/verify test (requires --addr and --size)');
    stdout.writeln();
    stdout.writeln('Required Options:');
    stdout.writeln('  --port, -p <COM3>      Serial port (auto-selected if omitted)');
    stdout.writeln('  --chip <BK7231N>       Chip type');
    stdout.writeln();
    stdout.writeln('Optional:');
    stdout.writeln('  --baud, -b <921600>    Baud rate (default: 921600)');
    stdout.writeln('  --addr <0x11000>       Start address (hex or decimal, for read_flash/write_flash)');
    stdout.writeln('  --size <0x1000>        Length in bytes (hex or decimal, for read_flash/write_flash)');
    stdout.writeln('  --out <name>           Output name for backup (default: cliBackup)');
    stdout.writeln();
    stdout.writeln('Examples:');
    stdout.writeln('  easy_gui_flash_tool.exe --port COM3 --chip BK7231N fread --out mybackup');
    stdout.writeln('  easy_gui_flash_tool.exe --port COM3 --chip BK7231N fwrite firmware.bin');
    stdout.writeln('  easy_gui_flash_tool.exe --port COM3 --chip BK7231N read_flash --addr 0x11000 --size 0x1000');
    stdout.writeln('  easy_gui_flash_tool.exe --port COM3 --chip BK7231N write_flash data.bin --addr 0x0 --size 0x1000');
    stdout.writeln('  easy_gui_flash_tool.exe --port COM3 --chip BK7231N test --addr 0x11000 --size 0x1000');
    stdout.writeln();
    stdout.writeln('Legacy aliases (backward compatible):');
    stdout.writeln('  -read, -write, -cread, -cwrite, -test, -port, -baud, -chip, -ofs, -len, -out');
    stdout.writeln();
    stdout.writeln('Available chip types:');
    final chips = ChipPlatform.values
        .where((p) => p.bkType != null)
        .map((p) => p.displayName)
        .join(', ');
    stdout.writeln('  $chips');
    stdout.writeln();
    stdout.writeln('Note: Only BK-family chips are currently supported.');
  }
}
