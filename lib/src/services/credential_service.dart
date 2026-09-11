import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart';

abstract interface class CredentialStore {
  Future<String?> readToken();
  Future<void> writeToken(String token);
  Future<void> deleteToken();
}

/// Stores the Git token as a Windows DPAPI-protected blob. The encrypted data
/// can only be opened by the same Windows account on the same computer.
class SecureCredentialService implements CredentialStore {
  SecureCredentialService({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;

  Future<File> _tokenFile() async {
    final root = await _supportDirectory();
    return File(
      p.join(root.path, 'idreaml_clip', 'credentials', 'git_token.dpapi'),
    );
  }

  @override
  Future<String?> readToken() async {
    final file = await _tokenFile();
    if (!await file.exists()) return null;
    _requireWindows();
    return utf8.decode(_unprotect(await file.readAsBytes()));
  }

  @override
  Future<void> writeToken(String token) async {
    _requireWindows();
    final file = await _tokenFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(_protect(utf8.encode(token)), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  @override
  Future<void> deleteToken() async {
    final file = await _tokenFile();
    if (await file.exists()) await file.delete();
  }

  List<int> _protect(List<int> value) => _withBlobs(value, (input, output) {
    final success = CryptProtectData(
      input,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      0x1,
      output,
    );
    if (success == 0) {
      throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
    }
  });

  List<int> _unprotect(List<int> value) => _withBlobs(value, (input, output) {
    final success = CryptUnprotectData(
      input,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      0x1,
      output,
    );
    if (success == 0) {
      throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
    }
  });

  List<int> _withBlobs(
    List<int> value,
    void Function(
      Pointer<CRYPT_INTEGER_BLOB> input,
      Pointer<CRYPT_INTEGER_BLOB> output,
    )
    operation,
  ) {
    final input = calloc<CRYPT_INTEGER_BLOB>();
    final inputBytes = calloc<Uint8>(value.length);
    final output = calloc<CRYPT_INTEGER_BLOB>();
    try {
      inputBytes.asTypedList(value.length).setAll(0, value);
      input.ref
        ..cbData = value.length
        ..pbData = inputBytes;
      operation(input, output);
      return output.ref.pbData.asTypedList(output.ref.cbData).toList();
    } finally {
      if (output.ref.pbData != nullptr) LocalFree(output.ref.pbData);
      calloc.free(output);
      calloc.free(inputBytes);
      calloc.free(input);
    }
  }

  void _requireWindows() {
    if (!Platform.isWindows) {
      throw UnsupportedError('当前安全凭证实现仅支持 Windows。');
    }
  }
}
