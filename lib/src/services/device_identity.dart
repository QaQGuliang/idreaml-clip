import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

String? readMachineId() {
  if (!Platform.isWindows) return null;
  try {
    final firmwareTable = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Uint32 Function(Uint32, Uint32, Pointer<Uint8>, Uint32),
          int Function(int, int, Pointer<Uint8>, int)
        >('GetSystemFirmwareTable');
    const rsmb = 0x52534d42;
    final length = firmwareTable(rsmb, 0, nullptr, 0);
    if (length < 8 || length > 1024 * 1024) return null;
    return using((arena) {
      final buffer = arena<Uint8>(length);
      if (firmwareTable(rsmb, 0, buffer, length) != length) return null;
      return machineIdFromSmbios(buffer.asTypedList(length));
    });
  } catch (_) {
    return null;
  }
}

String? machineIdFromSmbios(List<int> raw) {
  // RawSMBIOSData starts with an eight-byte header. Each structure has a
  // formatted section followed by a double-NUL-terminated string section.
  var offset = 8;
  while (offset + 4 <= raw.length) {
    final type = raw[offset];
    final size = raw[offset + 1];
    if (size < 4 || offset + size > raw.length || type == 127) return null;
    if (type == 1 && size >= 24) {
      final uuid = raw.sublist(offset + 8, offset + 24);
      if (uuid.every((byte) => byte == 0) ||
          uuid.every((byte) => byte == 255)) {
        return null;
      }
      return sha256.convert([
        ...utf8.encode('idreaml-clip:windows:smbios:'),
        ...uuid,
      ]).toString();
    }
    offset += size;
    while (offset + 1 < raw.length &&
        (raw[offset] != 0 || raw[offset + 1] != 0)) {
      offset++;
    }
    offset += 2;
  }
  return null;
}

String? validMachineId(String? value) =>
    value != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(value) ? value : null;
