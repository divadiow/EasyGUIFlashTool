import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'base_flasher.dart';
import 'xmodem.dart';

class RTL87X0CFlasher extends BaseFlasher {
  static const int verifyWindowSize = 256 * 1024;
  static const int writeWindowRetryLimit = 3;
  static const int hashRetryLimit = 3;
  static const int commandRetryLimit = 3;
  static const int fallbackBaudRate = 115200;
  static const int readStubAddress = 0x10035000;
  static const int readStubParametersAddress = 0x10038000;
  static const List<String> _usedCommands = <String>[
    'ping', 'disc', 'ucfg', 'DW', 'DB', 'EW',
    'EB', 'WDTRST', 'hashq', 'fwd', 'fwdram',
  ];

  int? _flashMode;
  bool _flashConfigured = false;
  int? _flashHashOffset;
  bool _isInFallbackMode = false;
  int _flashSizeMB = 2;
  int _currentBaud = fallbackBaudRate;
  int? _funcPtr;
  String _funcName = '';

  final List<int> _rxBuffer = [];
  StreamSubscription<Uint8List>? _rxSub;
  Uint8List? _readResult;

  RTL87X0CFlasher({
    required super.transport,
    super.chipType = BKType.detect,
    super.baudrate = 1500000,
  }) {
    if (chipType == BKType.detect) {
      chipType = BKType.rtl87x0c;
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  PUBLIC API  (overrides from BaseFlasher)
  // ════════════════════════════════════════════════════════════════════════

  @override
  Future<void> doRead({int startSector = 0, int sectors = 10, bool fullRead = false}) async {
    try {
      int amount = sectors * 4096;
      setProgress(0, amount);
      setState('Reading');
      addLogLine('Starting read...');
      addLog('Read parms: start ${formatHex(startSector * 4096)} '
          '(sector $startSector), len ${formatHex(amount)} ($sectors sectors)\n');

      if (!await _doGenericSetup()) return;

      if (fullRead) {
        await _readFlashId();
        if (isCancelled) {
          addLogLine('Read cancelled by user.');
          setState('Cancelled');
          await closePort();
          return;
        }
        amount = _flashSizeMB * 1024 * 1024;
        sectors = amount ~/ 4096;
      }

      _readResult = await _readFlash(startSector * 4096, amount);
      if (_readResult == null) {
        setState('Read error');
      } else {
        setState('Read done');
        addLogLine('Read complete!');
      }
      await _changeBaud(fallbackBaudRate);
    } catch (e) {
      addError('Exception caught: $e\n');
      setState('Read error');
    } finally {
      await closePort();
    }
  }

  @override
  Future<void> doWrite(int startSector, Uint8List data) async {
    try {
      int size = data.length;
      setProgress(0, size);
      addLog('\nStarting write!\n');
      addLog('Write parms: start ${formatHex(startSector * 4096)} '
          '(sector $startSector), len ${formatHex(size)}\n');

      if (!await _doGenericSetup()) return;

      if (!await _changeBaud(baudrate)) {
        await closePort();
        return;
      }

      int writeOffset = startSector * 4096;
      addLog('Write Flash data ${formatHex(writeOffset)} to ${formatHex(writeOffset + size)}\n');

      if (!await _writeFlashWindows(data, writeOffset)) {
        addLog('Error: Write Flash!\n');
        await _changeBaud(fallbackBaudRate);
        await closePort();
        return;
      }

      addLog('Write done!\n');
      setProgress(size, size);
      addSuccess('Flash complete!\n');
      setState('Flash complete!');
      await _changeBaud(115200);

    } catch (e) {
      addError('Exception caught: $e\n');
      setState('Write error');
    } finally {
      await closePort();
    }
  }

  @override
  Future<bool> doErase({int startSector = 0, int sectors = 10, bool eraseAll = false}) async {
    try {
      if (!await _doGenericSetup()) return false;
      await _flashInit(configure: false);

      bool result = false;
      if (eraseAll) {
        addLogLine('Chip erase: ceras 0 $_flashMode');
        setState('Erasing chip...');
        result = await _runWithRecovery('Chip erase', 1, () => _sendEraseCommand('ceras 0 $_flashMode'));
      } else {
        addErrorLine('Sector erase is not implemented in this build.');
        setState('Erase failed!');
        await closePort();
        return false;
      }

      if (result) {
        setState('Erase complete!');
      } else {
        setState('Erase failed!');
      }
      await closePort();
      return result;
    } catch (e) {
      addErrorLine('Erase failed: $e');
      setState('Erase failed!');
      await closePort();
      return false;
    }
  }

  @override
  Uint8List? getReadResult() => _readResult;

  @override
  Future<void> closePort() async {
    _rxSub?.cancel();
    _rxSub = null;
    _flashMode = null;
    _flashConfigured = false;
    _flashHashOffset = null;
    _isInFallbackMode = false;
    _currentBaud = fallbackBaudRate;
    _funcPtr = null;
    _funcName = '';
    await transport.disconnect();
  }

  @override
  void dispose() {
    _rxSub?.cancel();
  }

  // ════════════════════════════════════════════════════════════════════════
  //  SERIAL I/O
  // ════════════════════════════════════════════════════════════════════════

  Future<bool> _openPort() async {
    try {
      final ok = await transport.connect();
      if (!ok) return false;
      _rxBuffer.clear();
      _rxSub?.cancel();
      _rxSub = transport.stream.listen((data) {
        _rxBuffer.addAll(data);
      });
      return true;
    } catch (e) {
      addError('Serial port exception: $e\n');
      return false;
    }
  }

  void _flush() {
    _rxBuffer.clear();
  }

  Future<Uint8List?> _readExactly(int count, {int timeoutMs = 200}) async {
    final buf = Uint8List(count);
    int offset = 0;
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (offset < count && !isCancelled && DateTime.now().isBefore(deadline)) {
      if (_rxBuffer.isNotEmpty) {
        int toCopy = min(count - offset, _rxBuffer.length);
        for(int i = 0; i < toCopy; i++) {
          buf[offset + i] = _rxBuffer.removeAt(0);
        }
        offset += toCopy;
      }
      if (offset >= count) break;
      await Future.delayed(const Duration(milliseconds: 2));
    }
    if (isCancelled || offset < count) return null;
    return buf;
  }

  Future<String> _readWithTimeout(int waitMs) async {
    final sb = StringBuffer();
    final deadline = DateTime.now().add(Duration(milliseconds: waitMs));
    while (DateTime.now().isBefore(deadline) && !isCancelled) {
      if (_rxBuffer.isNotEmpty) {
        sb.write(String.fromCharCodes(_rxBuffer));
        _rxBuffer.clear();
      }
      await Future.delayed(const Duration(milliseconds: 5));
    }
    return sb.toString();
  }

  Future<String> _readLine(int timeoutMs) async {
    final sb = <int>[];
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline) && !isCancelled) {
      while (_rxBuffer.isNotEmpty) {
        int b = _rxBuffer.removeAt(0);
        if (b == 10) { // \n
          String line = utf8.decode(sb, allowMalformed: true);
          return line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
        }
        sb.add(b);
      }
      await Future.delayed(const Duration(milliseconds: 1));
    }
    throw TimeoutException('ReadLine timeout');
  }

  Future<bool> _waitForTxIdle(int timeoutMs) async {
    await Future.delayed(Duration(milliseconds: timeoutMs));
    return true; // We assume TX finishes since Dart serial doesn't expose BytesToWrite
  }

  Future<void> _command(String cmd) async {
    // Wait slightly to let any dangling OS buffer bytes arrive before flushing
    await Future.delayed(const Duration(milliseconds: 15));
    _flush();
    final bytes = utf8.encode('$cmd\n');
    await transport.write(Uint8List.fromList(bytes));
    if (_isInFallbackMode) {
      await _readExactly(bytes.length + 1, timeoutMs: 100);
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  PROTOCOL IMPLEMENTATION
  // ════════════════════════════════════════════════════════════════════════

  Future<bool> _runWithRecovery(String label, int attempts, Future<bool> Function() action) async {
    for (int attempt = 1; attempt <= attempts; attempt++) {
      if (isCancelled) throw Exception('Cancelled');
      try {
        if (await action()) {
          if (attempt > 1) addLogLine('$label recovered on attempt $attempt/$attempts');
          return true;
        }
      } catch (e) {
        if (attempt >= attempts) {
          addErrorLine('$label failed after $attempts attempts: $e');
          return false;
        }
        addWarningLine('$label retrying attempt ${attempt + 1}/$attempts: $e');
      }
      _flush();
      try { await _link(); } catch(_) {}
      await Future.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  Future<Uint8List?> _runWithRecoveryBytes(String label, int attempts, Future<Uint8List?> Function() action) async {
    Exception? last;
    for (int attempt = 1; attempt <= attempts; attempt++) {
      if (isCancelled) throw Exception('Cancelled');
      try {
        var result = await action();
        if (result != null) {
          if (attempt > 1) addLogLine('$label recovered on attempt $attempt/$attempts');
          return result;
        }
        last = Exception('No data returned');
      } catch (e) { last = e is Exception ? e : Exception(e.toString()); }
      
      if (attempt < attempts) {
        addWarningLine('$label retrying attempt ${attempt + 1}/$attempts: $last');
        _flush();
        try { await _link(); } catch(_) {}
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    if (last != null) addErrorLine('$label failed after $attempts attempts: $last');
    return null;
  }

  Future<bool> _tryPingLink(int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline) && !isCancelled) {
      await _command('ping');
      try {
        var acc = await _readWithTimeout(500);
        if (acc.contains('ping')) {
          var extra = await _readWithTimeout(20);
          if (!extra.contains(r'$8710c') && !acc.contains(r'$8710c')) {
            return true;
          }
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 10));
    }
    return false;
  }

  Future<bool> _linkFallback() async {
    await _command('Rtk8710C');
    var resp = await _readWithTimeout(100);
    if (resp.contains(r'$8710c>') || resp.contains('Command NOT found.')) {
      _isInFallbackMode = true;
      var chipVer = (await _registerRead(0x400001F0) >> 4) & 0xF;
      if (chipVer > 2) {
        await _memoryBoot(0);
      } else {
        await _memoryBoot(0x1443C);
      }
      _isInFallbackMode = false;
    }
    return true;
  }

  Future<bool> _link() async {
    if (await _tryPingLink(400)) return true;
    await _linkFallback();
    if (await _tryPingLink(10000)) return true;
    addErrorLine('Ping response is incorrect');
    addErrorLine('Link failed!');
    return false;
  }

  Future<void> _wdtDisableRaw() async {
    try {
      var wdtCmd = utf8.encode('EW 40002800 7EFFFFFF\n');
      await transport.write(Uint8List.fromList(wdtCmd));
      await Future.delayed(const Duration(milliseconds: 50));
      _flush();
    } catch (_) {}
  }

  Future<bool> _tryChangeBaudOnce(int fromBaud, int toBaud, int txIdleMs, int oldReadMs, int newReadMs) async {
    await transport.setBaudRate(fromBaud);
    _currentBaud = fromBaud;
    _flush();
    if (!await _link()) return false;
    await _wdtDisableRaw();
    await _command('ucfg $toBaud 0 0');
    await _waitForTxIdle(txIdleMs);
    var oldSide = await _readWithTimeout(oldReadMs);
    await transport.setBaudRate(toBaud);
    _currentBaud = toBaud;
    await Future.delayed(const Duration(milliseconds: 20));
    var newSide = await _readWithTimeout(newReadMs);
    if (oldSide.contains('OK') || newSide.contains('OK')) {
      _flush();
      return await _link();
    }
    _flush();
    if (await _link()) {
      addLogLine('Baud change completed without explicit OK response');
      return true;
    }
    await transport.setBaudRate(fromBaud);
    _currentBaud = fromBaud;
    _flush();
    return false;
  }

  Future<bool> _changeBaud(int baud) async {
    if (baud == _currentBaud) {
      return await _link();
    }
    addLogLine('Setting baud rate to $baud');
    final originalBaud = _currentBaud;
    if (await _tryChangeBaudOnce(originalBaud, baud, 150, 40, 250)) return true;
    if (await _tryChangeBaudOnce(originalBaud, baud, 300, 75, 450)) return true;
    addErrorLine('Baud change failed');
    return false;
  }

  Future<bool> _dumpWords(int start, int count, List<int> words) async {
    int bytesRead = 0;
    int expectedBytes = count * 4;
    await _command('DW ${start.toRadixString(16).toUpperCase()} $count');
    int timeoutMs = max(1500, count * 118000 ~/ _currentBaud + 500);
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    
    while (bytesRead < expectedBytes && DateTime.now().isBefore(deadline) && !isCancelled) {
      try {
        String line = await _readLine(200);
        var parts = line.split(' ').where((x) => x.isNotEmpty).toList();
        if (parts.isEmpty || parts[0] == '\r') continue;
        
        String addrStr = parts[0].replaceAll(':', '').replaceAll('\r', '').replaceAll('\n', '');
        int? addr = int.tryParse(addrStr, radix: 16);
        if (addr == null) continue;
        if (addr != start + bytesRead) throw Exception('Unexpected word dump address');
        if (parts.length < 5) throw Exception('Incomplete word dump line');

        for (int i = 1; i < 5 && bytesRead < expectedBytes; i++) {
          int? value = int.tryParse(parts[i].trim(), radix: 16);
          if (value == null) throw Exception('Invalid word dump data');
          words.add(value);
          bytesRead += 4;
        }
      } on TimeoutException { continue; }
    }
    return bytesRead == expectedBytes && words.length == count;
  }

  Future<Uint8List?> _dumpBytes(int start, int count) async {
    final data = <int>[];
    await _command('DB ${start.toRadixString(16).toUpperCase()} $count');
    final timeoutMs = max(1500, count * 37000 ~/ _currentBaud + 500);
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));

    while (data.length < count &&
        DateTime.now().isBefore(deadline) &&
        !isCancelled) {
      try {
        final line = await _readLine(200);
        final parts = line.split(' ').where((x) => x.isNotEmpty).toList();
        if (parts.isEmpty || parts[0] == '[Addr]' || parts[0] == '\r') {
          continue;
        }

        final address = int.tryParse(
            parts[0].replaceAll(':', '').replaceAll('\r', ''),
            radix: 16);
        if (address == null) continue;
        if (address != start + data.length) {
          throw Exception('Unexpected byte dump address');
        }
        if (parts.length < 17) {
          throw Exception('Incomplete byte dump line');
        }

        for (int i = 1; i < 17 && data.length < count; i++) {
          final value = int.tryParse(parts[i].trim(), radix: 16);
          if (value == null) {
            throw Exception('Invalid byte dump data');
          }
          data.add(value);
        }
      } on TimeoutException {
        continue;
      }
    }

    return data.length == count ? Uint8List.fromList(data) : null;
  }

  Future<int> _registerRead(int addr) async {
    int start = addr & ~0xF;
    List<int> words = [];
    if (!await _dumpWords(start, 4, words) || words.length != 4) {
      throw Exception('Register read failed at ${formatHex(addr)}');
    }
    int index = (addr - start) >> 2;
    return words[index];
  }

  Future<void> _registerWrite(int addr, int value) async {
    await _command('EW ${addr.toRadixString(16).toUpperCase()} ${value.toRadixString(16).toUpperCase()}');
    var response = await _readWithTimeout(120);
    if (response.contains('ERR')) {
      throw Exception('Register write failed at ${formatHex(addr)}');
    }
  }

  Future<bool> _memoryBoot(int addr) async {
    addr |= 1;
    if (_funcPtr == null) {
      final commands = await _registerRead(0x1002F054);
      for (int entry = commands; entry < commands + 8 * 12; entry += 12) {
        final namePtr = await _registerRead(entry);
        if (namePtr == 0) break;
        final nameBytes = await _dumpBytes(namePtr, 16);
        if (nameBytes == null) continue;
        final nul = nameBytes.indexOf(0);
        final name = ascii.decode(
            nameBytes.sublist(0, nul < 0 ? nameBytes.length : nul),
            allowInvalid: true);
        if (name.isEmpty || _usedCommands.contains(name)) continue;
        _funcPtr = entry + 4;
        _funcName = name;
        break;
      }
    }
    if (_funcPtr == null) {
      throw Exception('Memory boot function was not found');
    }
    await _registerWrite(_funcPtr!, addr);
    addLogLine(
        "Jump to 0x${_funcPtr!.toRadixString(16).toUpperCase()} using '$_funcName'");
    await _command(_funcName);
    return true;
  }

  Future<Uint8List?> _flashReadHashCore(int offset, int length) async {
    if (_flashHashOffset != offset) {
      if (!await _runWithRecovery('Hash offset set', commandRetryLimit, () => _flashTransmit(null, offset))) return null;
    }
    int timeoutMs = max(5000, (length / 1500.0 * 10.0 * 1000).toInt() + 250);
    await _command('hashq $length 0 $_flashMode');
    
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    List<int> collected = [];
    bool foundHashs = false;
    while (DateTime.now().isBefore(deadline) && !isCancelled) {
      if (_rxBuffer.isNotEmpty) {
        collected.add(_rxBuffer.removeAt(0));
        if (!foundHashs && collected.length >= 6) {
          String tail = String.fromCharCodes(collected.sublist(collected.length - 6));
          if (tail == 'hashs ') {
            foundHashs = true;
            collected.clear(); // collect exactly 32 bytes next
          }
        } else if (foundHashs && collected.length == 32) {
          return Uint8List.fromList(collected);
        }
      } else {
        await Future.delayed(const Duration(milliseconds: 2));
      }
    }
    throw Exception('Hash response timed out or invalid');
  }

  Future<Uint8List?> _flashReadHash(int offset, int length) async {
    return _runWithRecoveryBytes('Hash read', hashRetryLimit, () => _flashReadHashCore(offset, length));
  }

  Future<bool> _verifyFlashWindow(Uint8List expected, int offset) async {
    final expectedDigest = sha256.convert(expected);
    final expectedHash = expectedDigest.bytes;
    final actualHash = await _flashReadHash(offset, expected.length);
    if (actualHash == null) return false;
    for (int i = 0; i < 32; i++) {
      if (expectedHash[i] != actualHash[i]) {
        final actualDigest = actualHash
            .map((value) => value.toRadixString(16).padLeft(2, '0'))
            .join();
        addWarningLine(
            'Verify hash mismatch: expected $expectedDigest, got $actualDigest');
        addWarningLine('Falling back to byte-exact stub readback...');
        final readback = await _readFlashWithStub(offset, expected.length);
        if (readback == null || readback.length != expected.length) {
          return false;
        }
        for (int j = 0; j < expected.length; j++) {
          if (readback[j] != expected[j]) return false;
        }
        addLogLine('Stub readback matched despite the stale device hash.');
        return true;
      }
    }
    return true;
  }

  Future<bool> _flashTransmit(Uint8List? data, int offset) async {
    await _flashInit(configure: false);
    await _command('fwd 0 $_flashMode ${offset.toRadixString(16)}');
    _flashHashOffset = offset;
    
    if (data == null) {
      // Expect NAK
      final deadline = DateTime.now().add(const Duration(milliseconds: 3000));
      while(DateTime.now().isBefore(deadline)) {
        if (_rxBuffer.isNotEmpty) {
          int resp = _rxBuffer.removeAt(0);
          if (resp != 0x15) throw Exception('expected NAK, got $resp');
          await transport.write(Uint8List.fromList([0x18])); // CAN
          _flush();
          var canResp = await _readExactly(3, timeoutMs: 3000);
          if (canResp == null || canResp[0] != 24 || canResp[1] != 69 || canResp[2] != 82) { // 24 = ^X, 'E', 'R'
             throw Exception('expected CAN');
          }
          return await _link();
        }
        await Future.delayed(const Duration(milliseconds: 10));
      }
      throw Exception('Timeout waiting for NAK in fwd (null)');
    }
    
    var xm = XmodemSender(transport);
    xm.onPacketSent = (sentBytes, total, seq, off) {
      // progress here if needed
    };
    int res = await xm.send(data);
    if (res != data.length) return false;
    
    await Future.delayed(const Duration(milliseconds: 50));
    return await _link();
  }

  Future<bool> _ramTransmit(Uint8List data, int offset) async {
    await _command('fwdram ${offset.toRadixString(16)}');
    final sender = XmodemSender(transport);
    final sent = await sender.send(data);
    if (sent != data.length) return false;
    await Future.delayed(const Duration(milliseconds: 50));
    return await _link();
  }

  Future<bool> _writeWindow(Uint8List window, int offset, int progressBase, int progressTotal) async {
    for (int attempt = 1; attempt <= writeWindowRetryLimit; attempt++) {
      if (isCancelled) return false;
      if (attempt == 1) {
        addLogLine('Writing ${window.length ~/ 1024}KiB to ${formatHex(offset)}');
      } else {
        addLogLine('Retrying write ${formatHex(offset)} (attempt $attempt/$writeWindowRetryLimit)');
      }
      
      if (!await _runWithRecovery('Flash write', commandRetryLimit, () => _flashTransmit(window, offset))) {
        if (attempt == writeWindowRetryLimit) return false;
        continue;
      }
      
      addLogLine('Verifying ${formatHex(offset)} len ${formatHex(window.length)}...');
      if (await _verifyFlashWindow(window, offset)) {
        addLogLine('Write verified OK at ${formatHex(offset)}');
        return true;
      }
      addWarningLine('Write verify failed at ${formatHex(offset)}');
      
      if (attempt == 2 && baudrate > fallbackBaudRate) {
        await _changeBaud(fallbackBaudRate);
      }
      _flush();
      try { await _link(); } catch (_) {}
    }
    return false;
  }

  Future<bool> _writeFlashWindows(Uint8List data, int offset) async {
    int done = 0;
    while (done < data.length) {
      if (isCancelled) return false;
      int windowLen = min(verifyWindowSize, data.length - done);
      var window = data.sublist(done, done + windowLen);
      if (!await _writeWindow(window, offset + done, done, data.length)) {
        addErrorLine('Write window failed at ${formatHex(offset + done)}');
        return false;
      }
      done += windowLen;
      setProgress(done, data.length);
    }
    return true;
  }

  Future<void> _flashInit({bool configure = true}) async {
    if (_flashMode == null) {
      _flashMode = ((await _registerRead(0x40000038)) >> 5) & 3;
      addLogLine('Flash pin detected: $_flashMode');
    }
    if (!_flashConfigured) {
      await _registerWrite(0x40002800, 0x7EFFFFFF);
      _flashConfigured = true;
    }
    if (configure && _flashHashOffset == null) {
      await _flashReadHash(0, 0);
    }
  }

  Future<bool> _doGenericSetup() async {
    addLog('Flasher type: RTL87X0C\n');
    if (!await _openPort()) return false;
    addLog('Port ready!\n');
    try {
      await transport.setBaudRate(115200);
      _currentBaud = fallbackBaudRate;
      await Future.delayed(const Duration(milliseconds: 50));
    } catch (_) {} // ignore unsupported ops
    if (!await _link()) {
      setState('Link failed!');
      await closePort();
      return false;
    }
    return true;
  }

  Future<void> _readFlashId() async {
    await _flashInit();
    await _command('EB 0x40020060 0x9F');
    await _command('EW 0x40020004 3');
    await _command('EW 0x40020008 1');
    await _command('EW 0x40020008 0');
    await Future.delayed(const Duration(milliseconds: 10));
    _flush();
    final bytes = await _dumpBytes(0x40020060, 16);
    if (bytes == null || bytes.length < 5) {
      throw Exception('Failed to read flash ID from register dump');
    }
    _flashSizeMB = (1 << (bytes[1] - 0x11)) ~/ 8;
    addLogLine(
        'Flash ID: 0x${bytes[0].toRadixString(16).padLeft(2, '0')}'
        '${bytes[4].toRadixString(16).padLeft(2, '0')}'
        '${bytes[1].toRadixString(16).padLeft(2, '0')}');
    addLogLine('${_flashSizeMB}MB flash size detected');
  }

  Future<Uint8List?> _readFlash(int addr, int amount) async {
    await _flashInit();
    if (!await _changeBaud(baudrate)) {
      await closePort();
      return null;
    }

    final result = await _readFlashWithStub(addr, amount);
    if (result == null || result.length != amount) {
      throw Exception('Z2 XMODEM read failed');
    }

    addLogLine('Getting full hash...');
    final readHash = sha256.convert(result).bytes;
    final expectedHash = await _flashReadHash(addr, amount);
    bool hashesMatch = expectedHash != null && expectedHash.length == readHash.length;
    for (int i = 0; hashesMatch && i < readHash.length; i++) {
      hashesMatch = readHash[i] == expectedHash![i];
    }
    if (!hashesMatch) {
      throw Exception('Flash read SHA-256 mismatch');
    }

    addSuccess('Hash matches ${sha256.convert(result)}!');
    return result;
  }

  Future<Uint8List?> _readFlashWithStub(int addr, int amount) async {
    addLogLine('Uploading Z2 XMODEM read stub...');
    await _registerWrite(readStubParametersAddress, addr);
    await _registerWrite(readStubParametersAddress + 4, amount);
    await _registerWrite(readStubParametersAddress + 8, 0);

    final asset = await rootBundle.load(
        'assets/floaders/Z2_XModem_Stub.bin');
    final stub = asset.buffer.asUint8List(
        asset.offsetInBytes, asset.lengthInBytes);
    if (!await _ramTransmit(stub, readStubAddress)) {
      throw Exception('Z2 read stub upload failed');
    }
    if (!await _memoryBoot(readStubAddress)) {
      throw Exception('Z2 read stub did not start');
    }
    await Future.delayed(const Duration(milliseconds: 5));

    final receiver = XmodemReceiver(transport);
    receiver.isCancelled = () => isCancelled;
    receiver.onPacketReceived = (received, total, block) {
      setProgress(received, total);
    };
    final result = await receiver.receive(amount);
    _flush();
    return result;
  }

  Future<bool> _sendEraseCommand(String cmd) async {
    await _command(cmd);
    var deadline = DateTime.now().add(const Duration(seconds: 60));
    var buf = Uint8List(2);
    int got = 0;
    while(got < 2 && DateTime.now().isBefore(deadline) && !isCancelled) {
      if (_rxBuffer.isNotEmpty) {
        buf[got++] = _rxBuffer.removeAt(0);
      } else {
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }
    if (got < 2) throw Exception('Erase timed out waiting for ACK after 60 seconds');
    if (buf[0] != 0x4F || buf[1] != 0x4B) { // 'O', 'K'
      throw Exception('Unexpected erase ACK: $buf');
    }
    addLogLine('Erase ACK: OK');
    return true;
  }

}
