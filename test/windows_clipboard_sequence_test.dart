import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:idreaml_clip/src/models/clipboard_content.dart';
import 'package:idreaml_clip/src/services/restoring_quick_paste_target.dart';
import 'package:idreaml_clip/src/services/windows_clipboard_service.dart';
import 'package:idreaml_clip/src/services/windows_quick_paste_service.dart';
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
      test(
        '${entry.key}: worker reads the content and its locked sequence',
        () async {
          await clipboard.write(entry.value);
          final received = await clipboard.read();
          expect(received.single.content, entry.value.content);
          expect(received.single.type, entry.value.type);
          expect(clipboard.lastReadSequence, clipboard.sequence);
        },
      );

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

    test(
      'read-only Edit declines text, image paste is left to the app',
      () async {
        final edit = using(
          (arena) => CreateWindowEx(
            0,
            'Edit'.toNativeUtf16(allocator: arena),
            nullptr,
            WS_CHILD | ES_READONLY,
            0,
            0,
            80,
            24,
            HWND_MESSAGE,
            0,
            0,
            nullptr,
          ),
        );
        expect(edit, isNot(0));
        addTearDown(() => DestroyWindow(edit));
        await clipboard.write(contents['text']!);
        expect(pasteTextIntoWindowsEdit(edit), isFalse);
        SendMessage(edit, EM_SETREADONLY, 0, 0);
        await clipboard.write(contents['image']!);
        expect(pasteTextIntoWindowsEdit(edit), isNull);
        expect(GetWindowTextLength(edit), 0);
      },
    );

    for (final fixture in [
      (className: 'Edit', dll: null, multiline: false),
      (className: 'Edit', dll: null, multiline: true),
      (className: 'RichEdit20W', dll: 'Riched20.dll', multiline: true),
      (className: 'RICHEDIT50W', dll: 'Msftedit.dll', multiline: true),
    ]) {
      test('WM_PASTE replaces selection in ${fixture.className} '
          '(multiline=${fixture.multiline})', () async {
        final text = fixture.multiline ? '第一行🌙\r\n第二行' : '中文🌙';
        await clipboard.write(ClipboardContent.text(text));
        using((arena) {
          final ole = OleInitialize(nullptr);
          final dll = fixture.dll;
          final module = dll == null
              ? 0
              : LoadLibrary(dll.toNativeUtf16(allocator: arena));
          var edit = 0;
          try {
            if (dll != null) expect(module, isNot(0));
            edit = CreateWindowEx(
              0,
              fixture.className.toNativeUtf16(allocator: arena),
              'A[old]Z'.toNativeUtf16(allocator: arena),
              WS_CHILD | (fixture.multiline ? ES_MULTILINE : 0),
              0,
              0,
              200,
              100,
              HWND_MESSAGE,
              0,
              0,
              nullptr,
            );
            expect(edit, isNot(0), reason: 'CreateWindowEx: ${GetLastError()}');
            SendMessage(edit, EM_SETSEL, 1, 6);
            expect(pasteTextIntoWindowsEdit(edit), isTrue);
            final buffer = arena<Uint16>(128).cast<Utf16>();
            final length = GetWindowText(edit, buffer, 128);
            // Different rich edit versions expose CR or CRLF through WM_GETTEXT.
            final actual = buffer
                .toDartString(length: length)
                .replaceAll(RegExp(r'\r\n?'), '\n');
            expect(actual, 'A${text.replaceAll('\r\n', '\n')}Z');
          } finally {
            if (edit != 0) DestroyWindow(edit);
            if (module != 0) FreeLibrary(module);
            if (SUCCEEDED(ole)) OleUninitialize();
          }
        });
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
