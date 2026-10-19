import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:idreaml_clip/src/models/clipboard_content.dart';
import 'package:idreaml_clip/src/services/restoring_quick_paste_target.dart';
import 'package:idreaml_clip/src/services/windows_clipboard_service.dart';
import 'package:win32/win32.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Windows clipboard write sequence', skip: !Platform.isWindows, () {
    late WindowsClipboardService clipboard;

    setUpAll(() {
      // Each test file runs in its own tester process. Windows gives an unnamed
      // station the logon session's noninteractive name. Verify isolation from
      // the user's station before any clipboard write; never switch desktops.
      final user32 = DynamicLibrary.open('user32.dll');
      final setStation = user32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'SetProcessWindowStation',
          );
      final closeStation = user32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'CloseWindowStation',
          );
      final original = GetProcessWindowStation();
      final isolated = CreateWindowStation(
        nullptr,
        0,
        MAXIMUM_ALLOWED,
        nullptr,
      );
      expect(
        isolated,
        isNot(0),
        reason: 'CreateWindowStation: ${GetLastError()}',
      );
      var switched = false;
      clipboard = WindowsClipboardService();
      addTearDown(() {
        clipboard.dispose();
        if (switched) expect(setStation(original), isNot(0));
        expect(closeStation(isolated), isNot(0));
      });
      String stationName(int station) => using((arena) {
        final name = arena<Uint16>(256);
        expect(
          GetUserObjectInformation(station, UOI_NAME, name, 512, nullptr),
          isNot(0),
        );
        return name.cast<Utf16>().toDartString();
      });
      expect(stationName(isolated), isNot(stationName(original)));
      using((arena) {
        // USEROBJECTFLAGS is BOOL fInherit, BOOL fReserved, DWORD dwFlags.
        final flags = arena<Uint32>(3);
        expect(
          GetUserObjectInformation(
            isolated,
            UOI_FLAGS,
            flags,
            3 * sizeOf<Uint32>(),
            nullptr,
          ),
          isNot(0),
        );
        expect(flags[2] & 1, 0, reason: 'WSF_VISIBLE must not be set');
      });
      expect(setStation(isolated), isNot(0));
      switched = true;
    });

    final contents = {
      'text': const ClipboardContent.text('自动粘贴回归测试'),
      'image': ClipboardContent.image(
        img.encodePng(img.Image(width: 2, height: 2)),
        'image/png',
      ),
    };
    for (final entry in contents.entries) {
      test('${entry.key}: committed sequence allows quick paste', () async {
        await clipboard.write(entry.value);
        final committed = clipboard.lastWriteSequence;
        expect(committed, isNotNull);
        expect(committed, clipboard.sequence);

        final restoration = _PasteRestoration();
        expect(
          await RestoringQuickPasteTarget(restoration)
              .paste(clipboardSequence: committed),
          isTrue,
        );
        expect(restoration.pastes, 1);
      });

      test('${entry.key}: a subsequent write still cancels paste', () async {
        await clipboard.write(entry.value);
        final committed = clipboard.lastWriteSequence;
        await clipboard.write(const ClipboardContent.text('newer clipboard'));
        expect(clipboard.sequence, isNot(committed));

        final restoration = _PasteRestoration();
        expect(
          await RestoringQuickPasteTarget(restoration)
              .paste(clipboardSequence: committed),
          isFalse,
        );
        expect(restoration.pastes, 0);
      });
    }
  });
}

// Exercise the real sequence guard without sending input to any application.
class _PasteRestoration implements QuickPasteRestoration {
  int pastes = 0;
  @override
  bool get valid => true;
  @override
  bool get canActivate => true;
  @override
  bool get foreground => true;
  @override
  bool get focused => true;
  @override
  bool get keysReleased => true;
  @override
  int get clipboardSequence => GetClipboardSequenceNumber();
  @override
  void activate() {}
  @override
  Future<bool> restoreFocus() async => true;
  @override
  bool sendPaste() {
    pastes++;
    return true;
  }
}
