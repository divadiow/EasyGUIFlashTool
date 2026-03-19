/// Supported chip platforms for the flash tool.
///
/// Each variant carries its display name and knows how to derive its
/// firmware-file prefix (mirroring the C# `FormMain.getFirmwarePrefix`).

import '../flasher/base_flasher.dart';

enum ChipPlatform {
  bk7231t('BK7231T'),
  bk7231u('BK7231U'),
  bk7231n('BK7231N'),
  bk7231m('BK7231M'),
  bk7238('BK7238'),
  bk7236('BK7236'),
  bk7252('BK7252'),
  bk7252n('BK7252N'),
  bk7258('BK7258'),
  bl602('BL602'),
  bl702('BL702'),
  bl616('BL616'),
  w600('W600'),
  w800('W800'),
  ln882h('LN882H'),
  xr809('XR809'),
  rtl8710b('RTL8710B'),
  rtl87x0c('RTL87X0C'),
  esp32('ESP32'),
  esp32s3('ESP32-S3'),
  esp32c3('ESP32-C3');

  const ChipPlatform(this.displayName);

  /// Human-readable label shown in the UI dropdown.
  final String displayName;

  /// Firmware-file prefix used to match release assets on GitHub.
  ///
  /// Mirrors the C# `FormMain.getFirmwarePrefix(BKType)` logic:
  /// - QIO variants  → `Open<name>_QIO_`
  /// - UA  variants  → `Open<name>_UA_`
  /// - Everything else → `Open<name>_`
  String get firmwarePrefix {
    switch (this) {
      case ChipPlatform.bk7231n:
      case ChipPlatform.bk7231m:
      case ChipPlatform.bk7236:
      case ChipPlatform.bk7238:
      case ChipPlatform.bk7252n:
      case ChipPlatform.bk7258:
        return 'Open${displayName}_QIO_';
      case ChipPlatform.bk7231t:
      case ChipPlatform.bk7231u:
      case ChipPlatform.bk7252:
        return 'Open${displayName}_UA_';
      default:
        return 'Open${displayName}_';
    }
  }

  /// File extensions accepted for this platform.
  ///
  /// Mirrors the C# `FormMain.checkFirmwareForCurType` and
  /// `buttonBrowseFirmware_Click` logic.
  List<String> get allowedExtensions {
    switch (this) {
      case ChipPlatform.w600:
      case ChipPlatform.w800:
        return const ['.fls', '.bin', '.img'];
      case ChipPlatform.bk7231t:
      case ChipPlatform.bk7231u:
      case ChipPlatform.bk7231n:
      case ChipPlatform.bk7231m:
      case ChipPlatform.bk7238:
      case ChipPlatform.bk7236:
      case ChipPlatform.bk7252:
      case ChipPlatform.bk7252n:
      case ChipPlatform.bk7258:
        return const ['.bin', '.rbl'];
      default:
        return const ['.bin', '.rbl', '.img'];
    }
  }

  /// Union of every extension any platform might accept.
  /// Used by file-picker dialogs so the user can always browse any firmware.
  static const List<String> allExtensions = ['.bin', '.rbl', '.fls', '.img'];

  @override
  String toString() => displayName;
}

/// Extension to convert UI [ChipPlatform] to the flasher's [BKType] enum.
extension ChipPlatformFlasher on ChipPlatform {
  BKType? get bkType {
    switch (this) {
      case ChipPlatform.bk7231t: return BKType.bk7231t;
      case ChipPlatform.bk7231u: return BKType.bk7231u;
      case ChipPlatform.bk7231n: return BKType.bk7231n;
      case ChipPlatform.bk7231m: return BKType.bk7231m;
      case ChipPlatform.bk7238:  return BKType.bk7238;
      case ChipPlatform.bk7236:  return BKType.bk7236;
      case ChipPlatform.bk7252:  return BKType.bk7252;
      case ChipPlatform.bk7252n: return BKType.bk7252n;
      case ChipPlatform.bk7258:  return BKType.bk7258;
      case ChipPlatform.bl602:   return BKType.bl602;
      case ChipPlatform.bl702:   return BKType.bl702;
      case ChipPlatform.bl616:   return BKType.bl616;
      case ChipPlatform.esp32:   return BKType.esp32;
      case ChipPlatform.esp32s3: return BKType.esp32s3;
      case ChipPlatform.esp32c3: return BKType.esp32c3;
      case ChipPlatform.w800:    return BKType.w800;
      case ChipPlatform.w600:    return BKType.w600;
      case ChipPlatform.rtl87x0c: return BKType.rtl87x0c;
      default: return null;
    }
  }
}
