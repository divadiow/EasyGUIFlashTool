import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'dart:io' show Platform;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/serial_provider.dart';
import '../services/firmware_storage.dart';
import '../services/file_saver.dart';
import '../widgets/download_dialog.dart';
import '../models/chip_platform.dart';
import '../constants.dart';
import '../flasher/bk7231_flasher.dart';
import '../flasher/bl602_flasher.dart';
import '../flasher/esp32_flasher.dart';
import '../flasher/wm_flasher.dart';
import '../flasher/rtl87x0c_flasher.dart';
import '../flasher/base_flasher.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../services/file_opener.dart';
import '../widgets/linkified_text.dart';

class FlashToolScreen extends StatefulWidget {
  const FlashToolScreen({super.key});

  @override
  State<FlashToolScreen> createState() => _FlashToolScreenState();
}

class _FlashToolScreenState extends State<FlashToolScreen> {
  final ScrollController _logScrollController = ScrollController();
  String _statusMessage = '';
  final TextEditingController _customBaudController = TextEditingController();

  final List<int> _commonBaudRates = kCommonBaudRates;
  bool _useCustomBaud = false;

  // --- GUI-layer state (not in provider) ---
  final List<({String text, LogLevel level})> _logLines = [];
  double _progress = 0.0;
  ChipPlatform _selectedPlatform = ChipPlatform.bk7231t;
  String _selectedFirmware = '(none)';
  String? _customFirmwarePath;
  bool _isDragOver = false;
  bool _flasherRunning = false;
  bool _hasError = false;
  static const String _buildDate = String.fromEnvironment('BUILD_DATE', defaultValue: 'dev');

  // Firmware storage service (shared singleton)
  final FirmwareStorage _storage = FirmwareStorage();

  // Dynamic firmware list loaded from disk
  List<String> _availableFirmwares = ['(none)'];

  @override
  void initState() {
    super.initState();
    _restoreSettings();
  }

  Future<void> _restoreSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. Restore Platform
    final savedPlatformName = prefs.getString('ui_platform');
    if (savedPlatformName != null) {
      try {
        // Match enum by name, e.g. "bk7231t"
        final p = ChipPlatform.values.firstWhere((e) => e.name == savedPlatformName);
        if (mounted) {
          setState(() => _selectedPlatform = p);
        }
      } catch (_) {
        // Saved platform invalid or changed, ignore
      }
    }

    // 2. Refresh firmware list for the selected platform
    await _refreshFirmwareList();

    // 3. Restore Firmware Selection
    final savedFirmware = prefs.getString('ui_firmware');
    if (savedFirmware != null && mounted) {
      // Only select if it's still available in the list
      if (_availableFirmwares.contains(savedFirmware)) {
        setState(() => _selectedFirmware = savedFirmware);
      }
    }
  }

  Future<void> _saveUiSetting(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  @override
  void dispose() {
    _logScrollController.dispose();
    _customBaudController.dispose();
    super.dispose();
  }

  /// Reload the firmware dropdown from disk (or in-memory on web).
  Future<void> _refreshFirmwareList() async {
    final prefix = _selectedPlatform.firmwarePrefix;
    final files = await _storage.listFiles(kFirmwareStorageSubdir, prefix: prefix);
    if (mounted) {
      setState(() {
        _availableFirmwares = ['(none)', ...files];
        // Keep current selection if still valid, else reset
        if (!_availableFirmwares.contains(_selectedFirmware)) {
          _selectedFirmware = '(none)';
        }
      });
    }
    
    // Auto-select last downloaded logic (fallback if no stored UI setting was effectively used)
    // We check if current selection is none AND custom is null
    if (_selectedFirmware == '(none)' && _customFirmwarePath == null) {
      final last = await _storage.getLastSaved('firmwares');
      if (last != null && _availableFirmwares.contains(last) && mounted) {
        setState(() => _selectedFirmware = last);
      }
    }
  }

  void _addLog(String message, [LogLevel level = LogLevel.info]) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    setState(() {
      _logLines.add((text: '[$ts] $message', level: level));
    });
    _scrollLogToBottom();
  }

  /// Common preamble logged at the start of every flasher action.
  void _logOperationStart(String opName, {bool logFirmware = true}) {
    final provider = context.read<SerialProvider>();
    final now = DateTime.now();
    final weekday = const ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'][now.weekday - 1];
    final date = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    _addLog('=== $weekday, $date ===');
    final osName = kIsWeb ? 'Web' : Platform.operatingSystem[0].toUpperCase() + Platform.operatingSystem.substring(1);
    _addLog('=== $osName, flasher built on $_buildDate ===');
    _addLog('=== Starting $opName on port ${provider.selectedPort ?? "?"} ===');
    _addLog('Platform: $_selectedPlatform');
    if (logFirmware) _addLog('Firmware: ${_customFirmwarePath ?? _selectedFirmware}');
  }

  void _scrollLogToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  bool _isDesktop() {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDesktop = _isDesktop();

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: isDesktop ? MainAxisSize.max : MainAxisSize.min,
      children: [
        // Top controls: flow inline, wrap when narrow
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _buildConnectionSection(),
            _buildPlatformSection(),
            _buildFirmwareSection(),
          ],
        ),
        const SizedBox(height: 16),

        // Divider
        Divider(color: colorScheme.outlineVariant),
        const SizedBox(height: 12),

        // Action buttons
        _buildActionButtons(),
        const SizedBox(height: 16),

        // Progress bar
        _buildProgressBar(),
        const SizedBox(height: 16),

        // Log field — on desktop use Expanded; on mobile give a min height
        // so the log box is always usable even if the page scrolls.
        if (isDesktop)
          Expanded(child: _buildLogField())
        else
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 300),
            child: SizedBox(
              height: MediaQuery.of(context).size.height * 0.45,
              child: _buildLogField(),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Build: $_buildDate',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            textAlign: TextAlign.center,
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.developer_board, color: colorScheme.primary),
            const SizedBox(width: 10),
            const Text('EasyGUI Flash Tool'),
          ],
        ),
        actions: const [],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: isDesktop
            ? content
            : SingleChildScrollView(child: content),
      ),
    );
  }

  // ─── Section 1: COM Port + Baud + Open/Close + Connection State ───

  Widget _buildConnectionSection() {
    return Consumer<SerialProvider>(
      builder: (context, provider, _) {
        return IgnorePointer(
          ignoring: _flasherRunning,
          child: AnimatedOpacity(
            opacity: _flasherRunning ? 0.4 : 1.0,
            duration: const Duration(milliseconds: 250),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // Port dropdown
                  if (_isDesktop()) _buildPortSelector(provider),

                  // Baud rate
                  _buildBaudRateSelector(provider),

                  // Open / Close button
                  _buildConnectionButton(provider),

                  // Connection state indicator
                  _buildStatusChip(provider),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPortSelector(SerialProvider provider) {
    final ports = provider.getAvailablePorts();

    if (ports.isEmpty) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Chip(
            avatar: Icon(Icons.usb_off, size: 18),
            label: Text('No ports'),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: provider.refreshPorts,
            tooltip: 'Refresh ports',
          ),
        ],
      );
    }

    // If the saved port is missing from the available list, sync the
    // provider to the first available port so connect() uses it.
    // Use a post-frame callback to avoid setState-during-build.
    final effectivePort =
        (provider.selectedPort != null && ports.contains(provider.selectedPort))
            ? provider.selectedPort!
            : ports.first;
    if (effectivePort != provider.selectedPort) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        provider.setPort(effectivePort);
      });
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.usb, size: 20),
        const SizedBox(width: 6),
        DropdownMenu<String>(
          initialSelection: effectivePort,
          hintText: 'Select Port',
          requestFocusOnTap: false,
          enabled: !provider.isConnected,
          inputDecorationTheme: const InputDecorationTheme(
            border: InputBorder.none,
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 8),
          ),
          dropdownMenuEntries: ports.map((port) {
            return DropdownMenuEntry(value: port, label: port);
          }).toList(),
          onSelected: provider.isConnected
              ? null
              : (value) {
                  if (value != null) provider.setPort(value);
                },
        ),
        IconButton(
          icon: const Icon(Icons.refresh, size: 20),
          onPressed: provider.isConnected ? null : provider.refreshPorts,
          tooltip: 'Refresh ports',
        ),
      ],
    );
  }

  Widget _buildBaudRateSelector(SerialProvider provider) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.speed, size: 20),
        const SizedBox(width: 6),
        if (!_useCustomBaud)
          DropdownMenu<int>(
            initialSelection: _commonBaudRates.contains(provider.baudRate)
                ? provider.baudRate
                : _commonBaudRates[4], // default 115200
            requestFocusOnTap: false,
            enabled: !provider.isConnected,
            inputDecorationTheme: const InputDecorationTheme(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8),
            ),
            dropdownMenuEntries: _commonBaudRates.map((rate) {
              return DropdownMenuEntry(value: rate, label: '$rate');
            }).toList(),
            onSelected: provider.isConnected
                ? null
                : (value) {
                    if (value != null) provider.setBaudRate(value);
                  },
          )
        else
          SizedBox(
            width: 100,
            child: TextField(
              controller: _customBaudController,
              enabled: !provider.isConnected,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Custom',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              onSubmitted: (value) {
                final baud = int.tryParse(value);
                if (baud != null && baud > 0) provider.setBaudRate(baud);
              },
            ),
          ),
        const SizedBox(width: 4),
        IconButton(
          icon: Icon(_useCustomBaud ? Icons.list : Icons.edit, size: 20),
          onPressed: provider.isConnected
              ? null
              : () {
                  setState(() {
                    _useCustomBaud = !_useCustomBaud;
                    if (_useCustomBaud) {
                      _customBaudController.text = provider.baudRate.toString();
                    }
                  });
                },
          tooltip: _useCustomBaud ? 'Use preset' : 'Custom baud',
        ),
      ],
    );
  }

  Widget _buildConnectionButton(SerialProvider provider) {
    final isOpen = provider.isConnected;
    return ElevatedButton.icon(
      onPressed: () async {
        if (isOpen) {
          await provider.disconnect();
          _addLog('Port closed.');
        } else {
          if (_useCustomBaud) {
            final baud = int.tryParse(_customBaudController.text);
            if (baud != null && baud > 0) provider.setBaudRate(baud);
          }
          final ok = await provider.connect();
          if (ok) {
            _addLog('Port opened at ${provider.baudRate} baud.');
          } else {
            _addLog('ERROR: Failed to open port.');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Failed to open port. Check permissions.'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }
        }
      },
      icon: Icon(isOpen ? Icons.link_off : Icons.link, size: 18),
      label: Text(isOpen ? 'Close' : 'Open'),
      style: ElevatedButton.styleFrom(
        backgroundColor: isOpen ? Colors.red.shade700 : Colors.green.shade700,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    );
  }

  Widget _buildStatusChip(SerialProvider provider) {
    final connected = provider.isConnected;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: connected
            ? Colors.green.withOpacity(0.15)
            : Colors.grey.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: connected ? Colors.green : Colors.grey,
          width: 1.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? Colors.green : Colors.grey,
              boxShadow: connected
                  ? [BoxShadow(color: Colors.green.withOpacity(0.5), blurRadius: 6)]
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            connected ? 'Connected' : 'Disconnected',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: connected ? Colors.green.shade300 : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Section 2: Platform Selection ───

  Widget _buildPlatformSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.memory, size: 20),
          const SizedBox(width: 10),
          const Text('Platform:', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          DropdownMenu<ChipPlatform>(
            initialSelection: _selectedPlatform,
            requestFocusOnTap: false,
            inputDecorationTheme: const InputDecorationTheme(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8),
            ),
            dropdownMenuEntries: ChipPlatform.values.map((p) {
              return DropdownMenuEntry(value: p, label: p.displayName);
            }).toList(),
            onSelected: (value) {
              if (value != null) {
                setState(() => _selectedPlatform = value);
                _saveUiSetting('ui_platform', value.name);
                _addLog('Platform changed to ${value.displayName}');
                _refreshFirmwareList();
              }
            },
          ),
        ],
      ),
    );
  }

  // ─── Section 3: Firmware Selection (with drag & drop) ───

  Widget _buildFirmwareSection() {
    return DropTarget(
      onDragEntered: (_) => setState(() => _isDragOver = true),
      onDragExited: (_) => setState(() => _isDragOver = false),
      onDragDone: (details) async {
        setState(() => _isDragOver = false);
        if (details.files.isEmpty) return;
        final droppedFile = details.files.first;
        final fileName = droppedFile.name;
        final lower = fileName.toLowerCase();
        final allowed = _selectedPlatform.allowedExtensions;
        if (!allowed.any((ext) => lower.endsWith(ext))) {
          final proceed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Unexpected file type'),
              content: Text(
                '"$fileName" is not a ${allowed.join("/")} file.\n'
                'Do you want to use it anyway?',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
                TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
              ],
            ),
          );
          if (proceed != true) {
            _addLog('Dropped file "$fileName" skipped by user.');
            return;
          }
        }
        _addLog('Reading dropped file: $fileName ...');
        try {
          final bytes = await droppedFile.readAsBytes();
          _addLog('Dropped file size: ${bytes.length} bytes');
          await _storage.saveFile(kFirmwareStorageSubdir, fileName, bytes);
          _addLog('Saved dropped firmware: $fileName');
          await _selectFirmwareAfterSave(fileName);
        } catch (e) {
          _addLog('ERROR reading dropped file: $e');
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _isDragOver
              ? Colors.deepOrange.withOpacity(0.15)
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: _isDragOver
              ? Border.all(color: Colors.deepOrange, width: 2)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isDragOver ? Icons.file_download : Icons.sd_storage,
                      size: 20,
                      color: _isDragOver ? Colors.deepOrange : null,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _isDragOver ? 'Drop file here' : 'Firmware:',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: _isDragOver ? Colors.deepOrange : null,
                      ),
                    ),
                  ],
                ),
                if (!_isDragOver) ...[
                  DropdownMenu<String>(
                    initialSelection: _selectedFirmware,
                    requestFocusOnTap: false,
                    inputDecorationTheme: const InputDecorationTheme(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8),
                    ),
                    dropdownMenuEntries: _availableFirmwares.map((f) {
                      return DropdownMenuEntry(value: f, label: f);
                    }).toList(),
                    onSelected: (value) {
                      if (value != null) {
                        setState(() {
                          _selectedFirmware = value;
                          _customFirmwarePath = null;
                        });
                        _saveUiSetting('ui_firmware', value);
                        _addLog('Firmware selected: $value');
                      }
                    },
                  ),
                  if (_customFirmwarePath != null)
                    Tooltip(
                      message: _customFirmwarePath!,
                      child: Chip(
                        label: Text(
                          _customFirmwarePath!,
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () {
                          setState(() => _customFirmwarePath = null);
                          _addLog('Custom firmware cleared.');
                        },
                      ),
                    ),
                  ElevatedButton.icon(
                    onPressed: () async {
                      try {
                        final result = await pickFirmwareFile();
                        if (result == null) return;
                        final fileName = result.name;
                        final bytes = result.bytes;
                        if (bytes.isEmpty) {
                          _addLog('ERROR: File "$fileName" is empty.');
                          return;
                        }
                        _addLog('Opened file: $fileName (${bytes.length} bytes)');
                        await _storage.saveFile(kFirmwareStorageSubdir, fileName, bytes);
                        _addLog('Saved firmware: $fileName');
                        await _selectFirmwareAfterSave(fileName);
                      } catch (e) {
                        _addLog('ERROR opening file: $e');
                      }
                    },
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Open'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: () async {
                      final result = await DownloadDialog.show(
                        context,
                        platform: _selectedPlatform,
                        storage: _storage,
                      );
                      if (result != null) {
                        _addLog('Downloaded: ${result.fileName}');
                        await _selectFirmwareAfterSave(result.fileName);
                      }
                    },
                    icon: const Icon(Icons.cloud_download, size: 18),
                    label: const Text('Download'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 1),
            Text(
              'You can also drag and drop a ${_selectedPlatform.allowedExtensions.join("/")} file here.',
              style: TextStyle(
                fontSize: 10,
                fontStyle: FontStyle.italic,
                height: 1.0,
                color: _isDragOver
                    ? Colors.deepOrange.withOpacity(0.8)
                    : Colors.grey.shade500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Action Buttons ───

  // ── Firmware helpers ────────────────────────────────────────────────

  /// Refresh list and auto-select the given firmware after a save/download.
  Future<void> _selectFirmwareAfterSave(String fileName) async {
    await _refreshFirmwareList();
    if (mounted && _availableFirmwares.contains(fileName)) {
      setState(() {
        _selectedFirmware = fileName;
        _customFirmwarePath = null;
      });
      _saveUiSetting('ui_firmware', fileName);
    }
  }

  /// Load the currently-selected firmware from storage.
  /// Returns null (and logs an error) if nothing is selected or the file is empty.
  Future<Uint8List?> _loadSelectedFirmware() async {
    if (_selectedFirmware == '(none)' && _customFirmwarePath == null) {
      _addLog('ERROR: No firmware selected. Please select or download a firmware first.');
      return null;
    }
    final fwName = _customFirmwarePath ?? _selectedFirmware;
    _addLog('Loading firmware: $fwName ...');
    final data = await _storage.readFile(kFirmwareStorageSubdir, fwName);
    if (data == null || data.isEmpty) {
      _addLog('ERROR: Could not read firmware file "$fwName".');
      return null;
    }
    _addLog('Firmware loaded: ${data.length} bytes');
    return data;
  }

  // ── Flasher integration helpers ──────────────────────────────────────

  BaseFlasher? _currentFlasher;

  void _createFlasher() {
    final provider = context.read<SerialProvider>();
    final bkType = _selectedPlatform.bkType;
    if (bkType == null) {
      _addLog('ERROR: ${_selectedPlatform.displayName} is not supported — flasher not available.');
      return;
    }

    final bool isBL = bkType == BKType.bl602 ||
        bkType == BKType.bl702 ||
        bkType == BKType.bl616;
    final bool isESP = bkType == BKType.esp32 ||
        bkType == BKType.esp32s3 ||
        bkType == BKType.esp32c3;
    final bool isWM = bkType == BKType.w800 || bkType == BKType.w600;
    final bool isRTL87X0C = bkType == BKType.rtl87x0c;

    if (isESP) {
      _currentFlasher = ESPFlasher(
        transport: provider.transport,
        chipType: bkType,
        baudrate: provider.baudRate,
      );
    } else if (isBL) {
      _currentFlasher = BL602Flasher(
        transport: provider.transport,
        chipType: bkType,
        baudrate: provider.baudRate,
      );
    } else if (isWM) {
      _currentFlasher = WMFlasher(
        transport: provider.transport,
        chipType: bkType,
        baudrate: provider.baudRate,
      );
    } else if (isRTL87X0C) {
      _currentFlasher = RTL87X0CFlasher(
        transport: provider.transport,
        chipType: bkType,
        baudrate: provider.baudRate,
      );
    } else {
      _currentFlasher = BK7231Flasher(
        transport: provider.transport,
        chipType: bkType,
        baudrate: provider.baudRate,
      );
    }
    // Wire logging callbacks
    _currentFlasher!.onLog = (msg, level) {
      if (mounted) {
        _addLog(msg.trimRight(), level);
        if (level == LogLevel.error && !_hasError) {
          setState(() => _hasError = true);
        }
      }
    };
    _currentFlasher!.onProgress = (current, total) {
      if (mounted) setState(() => _progress = total > 0 ? current / total : 0);
    };
    _currentFlasher!.onState = (msg) {
      if (mounted) setState(() => _statusMessage = msg);
    };
  }

  Future<void> _stopOperation() async {
    if (_currentFlasher != null) {
      _addLog('Stopping operation...');
      _currentFlasher!.isCancelled = true;
      // We don't close the port here immediately to allow the loop to exit gracefully
      // but if needed we could force it. The finally block in the runner will close it.
    }
  }

  Future<bool> _ensurePortOpen() async {
    final provider = context.read<SerialProvider>();
    if (provider.isConnected) return true;

    _addLog('Port not open. Attempting to open ${provider.selectedPort ?? "(no port selected)"} at ${provider.baudRate} baud...');
    // This usually triggers permission prompt on supported platforms
    final ok = await provider.connect();
    if (!ok) {
      _addLog('ERROR: Failed to open port ${provider.selectedPort ?? "(none)"}. Operation aborted.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please allow port permission to continue.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
    return ok;
  }

  /// Common wrapper: guard checks, flasher creation, state management, cleanup.
  Future<void> _runFlasherOperation(String name, Future<void> Function() body) async {
    if (_flasherRunning) {
      _addLog('A flasher operation is already running.');
      return;
    }
    
    if (!await _ensurePortOpen()) return;

    _createFlasher();
    if (_currentFlasher == null) return;
    
    setState(() {
      _flasherRunning = true;
      _progress = 0;
      _hasError = false;
    });

    try {
      await body();
    } catch (e) {
      _addLog('Exception during $name: $e');
    } finally {
      await _cleanupFlasher();
    }
  }

  // ── Core read helper (used by read-only and backup-and-flash) ──────

  /// Reads the full flash content, saves it to a file, and returns true
  /// on success. Must be called inside a [_runFlasherOperation] body.
  Future<bool> _doReadAndSave({bool fullRead = false}) async {
    await _currentFlasher!.doRead(
        startSector: 0, sectors: 0x200000 ~/ 0x1000, fullRead: fullRead);
    final result = _currentFlasher!.getReadResult();
    if (result != null) {
      _addLog('Read complete: ${result.length} bytes');
      final filename = _buildReadResultFilename();
      await saveFile(filename, result);
      _addLog('Backup saved: $filename');
      return true;
    }
    if (_currentFlasher!.isCancelled) {
      _addLog('Read cancelled by user.');
    } else {
      _addLog('Read failed — no data returned. Check log above for errors.');
    }
    return false;
  }

  // ── Core write helper (used by write and backup-and-flash) ────────

  /// Writes [firmwareData] to the flash, respecting BK7231T/U bootloader
  /// protection. Must be called inside a [_runFlasherOperation] body.
  Future<void> _doWriteFirmware(Uint8List firmwareData) async {
    int startSector = 0;
    final bkType = _selectedPlatform.bkType;
    // can't touch bootloader of BK7231T
    if (bkType == BKType.bk7231t || bkType == BKType.bk7231u) {
      final fwName = (_customFirmwarePath ?? _selectedFirmware).toUpperCase();
      if (fwName.contains('_QIO_')) {
        // QIO binary includes bootloader — skip bootloader portion of data
        // and write starting after the bootloader
        startSector = BK7231Flasher.bootloaderSize;
        if (firmwareData.length > BK7231Flasher.bootloaderSize) {
          firmwareData = Uint8List.sublistView(
              firmwareData, BK7231Flasher.bootloaderSize);
          _addLog('Using hack to write QIO — just skip bootloader...');
          _addLog('... so bootloader will not be overwritten!');
        }
      } else {
        // UA binary has no bootloader — write it at the bootloader end offset
        startSector = BK7231Flasher.bootloaderSize;
        _addLog('UA binary detected — writing at bootloader end offset '
            '${_currentFlasher!.formatHex(startSector)}');
      }
    }
    _currentFlasher!.sourceFileName = _customFirmwarePath ?? _selectedFirmware;
    await _currentFlasher!.doWrite(startSector, firmwareData);
    _addLog('Write operation finished.');
  }

  // ── Public flasher operations ─────────────────────────────────────

  Future<void> _runFlasherRead({bool fullRead = false}) async {
    await _runFlasherOperation('read', () async {
      await _doReadAndSave(fullRead: fullRead);
    });
  }

  /// Build a filename for read results matching the BK7231GUIFlashTool scheme:
  /// `readResult_{ChipType}_{QIO|UA}_{yyyy-dd-M-HH-mm-ss}.bin`
  ///
  /// EasyGUIFlashTool always reads from offset 0x0 (full flash), so we always
  /// use QIO. The original C# tool uses UA only when reading from 0x11000
  /// (skipping the bootloader).
  String _buildReadResultFilename() {
    final chipName = _selectedPlatform.displayName;
    final typeStr = 'QIO';
    final now = DateTime.now();
    // Match C# DateTime.Now.ToString("yyyy-dd-M-HH-mm-ss")
    final dateStr = '${now.year}-${now.day}-${now.month}-'
        '${now.hour.toString().padLeft(2, '0')}-'
        '${now.minute.toString().padLeft(2, '0')}-'
        '${now.second.toString().padLeft(2, '0')}';
    return 'readResult_${chipName}_${typeStr}_$dateStr.bin';
  }

  Future<void> _runFlasherErase() async {
    await _runFlasherOperation('erase', () async {
      // can't touch bootloader of BK7231T
      final bkType = _selectedPlatform.bkType;
      final int startOfs;
      if (bkType == BKType.bk7231t || bkType == BKType.bk7231u) {
        startOfs = BK7231Flasher.bootloaderSize;
        _addLog('BK7231T/U mode — erase will skip bootloader (start at ${_currentFlasher!.formatHex(startOfs)})');
      } else {
        startOfs = BK7231Flasher.bootloaderSize;
      }
      final sectors = (0x200000 - startOfs) ~/ 0x1000;
      final ok = await _currentFlasher!.doErase(startSector: startOfs, sectors: sectors, eraseAll: true);
      _addLog(ok ? 'Erase complete!' : 'Erase failed or was cancelled.');
    });
  }

  Future<void> _runFlasherWrite() async {
    final firmwareData = await _loadSelectedFirmware();
    if (firmwareData == null) return;

    await _runFlasherOperation('write', () async {
      await _doWriteFirmware(firmwareData);
    });
  }

  Future<void> _runFlasherBackupAndFlash() async {
    final firmwareData = await _loadSelectedFirmware();
    if (firmwareData == null) return;

    await _runFlasherOperation('backup & flash', () async {
      _addLog('=== Step 1/2: Backup (read) ===');
      final ok = await _doReadAndSave(fullRead: true);
      if (!ok) {
        _addLog('Aborting flash — backup failed.');
        return;
      }

      _addLog('=== Step 2/2: Flash (write) ===');
      await _doWriteFirmware(firmwareData);
    });
  }

  Future<void> _runFlasherVerify() async {
    final firmwareData = await _loadSelectedFirmware();
    if (firmwareData == null) return;

    // Round up to sector boundary (4K = 0x1000)
    final sectors = (firmwareData.length + 0xFFF) ~/ 0x1000;
    _addLog('Will read $sectors sectors (${sectors * 0x1000} bytes) from device for verification...');

    await _runFlasherOperation('verify', () async {
      await _currentFlasher!.doRead(startSector: 0, sectors: sectors);
      final readData = _currentFlasher!.getReadResult();
      if (readData == null) {
        _addLog('Read failed or was cancelled — verify aborted.');
        return;
      }

      // Compare only up to firmware file length
      bool match = true;
      int mismatchOffset = -1;
      for (int i = 0; i < firmwareData.length; i++) {
        if (i >= readData.length || readData[i] != firmwareData[i]) {
          match = false;
          mismatchOffset = i;
          break;
        }
      }

      if (match) {
        _addLog('VERIFY OK — flash contents match firmware file (${firmwareData.length} bytes).');
      } else {
        final hex = '0x${mismatchOffset.toRadixString(16).toUpperCase()}';
        final expected = mismatchOffset < firmwareData.length
            ? '0x${firmwareData[mismatchOffset].toRadixString(16).toUpperCase().padLeft(2, '0')}'
            : 'N/A';
        final actual = mismatchOffset < readData.length
            ? '0x${readData[mismatchOffset].toRadixString(16).toUpperCase().padLeft(2, '0')}'
            : 'N/A';
        _addLog('VERIFY FAILED — first mismatch at offset $hex (expected $expected, got $actual).');
      }
    });
  }
  
  Future<void> _cleanupFlasher() async {
    if (_currentFlasher != null) {
      await _currentFlasher!.closePort();
      _currentFlasher!.dispose();
      _currentFlasher = null;
    }
    
    // Sync SerialProvider state because Flasher closed the underlying transport
    if (mounted) {
      final provider = context.read<SerialProvider>();
      if (provider.isConnected) {
        await provider.disconnect();
      }
      
      setState(() {
        _flasherRunning = false;
        if (!_hasError) _statusMessage = '';
      });
    }
  }

  Widget _buildActionButtons() {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        _buildActionButton(
          icon: Icons.sync,
          label: 'Backup & Flash',
          color: Colors.deepOrange,
          onPressed: _flasherRunning
              ? null
              : () {
                  _logOperationStart('Backup & Flash');
                  _runFlasherBackupAndFlash();
                },
        ),
        _buildActionButton(
          icon: Icons.download,
          label: 'Backup (Read) Only',
          color: Colors.blue,
          onPressed: _flasherRunning
              ? null
              : () {
                  _logOperationStart('Backup (Read)', logFirmware: false);
                  _runFlasherRead(fullRead: true);
                },
        ),
        _buildActionButton(
          icon: Icons.upload,
          label: 'Write Firmware',
          color: Colors.teal,
          onPressed: _flasherRunning
              ? null
              : () {
                  _logOperationStart('Firmware Write');
                  _runFlasherWrite();
                },
        ),
        _buildActionButton(
          icon: Icons.verified,
          label: 'Verify',
          color: Colors.indigo,
          onPressed: _flasherRunning
              ? null
              : () {
                  _logOperationStart('Verify');
                  _runFlasherVerify();
                },
        ),
        _buildActionButton(
          icon: Icons.delete_forever,
          label: 'Erase',
          color: Colors.red.shade700,
          onPressed: _flasherRunning
              ? null
              : () {
                  _logOperationStart('Erase', logFirmware: false);
                  _runFlasherErase();
                },
        ),
        if (_flasherRunning)
          _buildActionButton(
            icon: Icons.stop_circle,
            label: 'STOP',
            color: Colors.red.shade900,
            onPressed: _stopOperation,
          ),
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        disabledBackgroundColor: color.withOpacity(0.3),
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white.withOpacity(0.5),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: onPressed != null ? 3 : 0,
      ),
    );
  }

  // ─── Progress Bar ───

  Widget _buildProgressBar() {
    final pct = (_progress * 100).toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _statusMessage.isNotEmpty ? _statusMessage : 'Progress:', 
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  fontFamily: 'monospace',
                  color: _hasError ? Colors.red.shade300 : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text('$pct%', style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: _hasError ? Colors.red.shade300 : null,
            )),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: _progress,
            minHeight: 14,
            backgroundColor: Colors.grey.shade800,
            valueColor: AlwaysStoppedAnimation<Color>(
              _hasError ? Colors.red : (_progress >= 1.0 ? Colors.green : Colors.deepOrange),
            ),
          ),
        ),
      ],
    );
  }

  // ─── Log Field ───

  Widget _buildLogField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Log toolbar
        Row(
          children: [
            const Icon(Icons.terminal, size: 16, color: Colors.grey),
            const SizedBox(width: 6),
            const Text('Log', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              onPressed: _logLines.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: _logLines.map((e) => e.text).join('\n')));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Log copied to clipboard'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
              tooltip: 'Copy log to clipboard',
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: const Icon(Icons.save_alt, size: 18),
              onPressed: _logLines.isEmpty
                  ? null
                  : () {
                      // Placeholder — will integrate file save / download later
                      _addLog('Save log... (placeholder)');
                    },
              tooltip: 'Save log to file',
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep, size: 18),
              onPressed: _logLines.isEmpty
                  ? null
                  : () => setState(() => _logLines.clear()),
              tooltip: 'Clear log',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Log body
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade700),
            ),
            child: _logLines.isEmpty
                ? const Center(
                    child: Text(
                      'Log output will appear here.',
                      style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
                    ),
                  )
                : ListView.builder(
                    controller: _logScrollController,
                    padding: const EdgeInsets.all(10),
                    itemCount: _logLines.length,
                    itemBuilder: (context, index) {
                      final entry = _logLines[index];
                      Color color;
                      switch (entry.level) {
                        case LogLevel.error:
                          color = Colors.red;
                        case LogLevel.warning:
                          color = Colors.orange;
                        case LogLevel.success:
                          color = Colors.green;
                        case LogLevel.info:
                          color = Colors.greenAccent;
                      }
                      return LinkifiedText(
                        entry.text,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: color,
                          height: 1.5,
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
