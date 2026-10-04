[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Version
)

$ErrorActionPreference = 'Stop'
$target = (Resolve-Path -LiteralPath $Path).Path
if ($Version -notmatch '^\d+\.\d+\.\d+\+\d+$') { throw 'Expected major.minor.patch+build.' }
if ((Get-AuthenticodeSignature -LiteralPath $target).Status -ne 'NotSigned') {
    throw 'Update the unsigned staged runner before code signing.'
}

# Only replaces the runner's VERSIONINFO resource (English US, as in Runner.rc).
# Icons, manifest and executable code are preserved by BeginUpdateResource(false).
# https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-updateresourcew
if (-not ('IdreamlPackaging.FileVersionResource' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

namespace IdreamlPackaging {
    public static class FileVersionResource {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr BeginUpdateResourceW(string file, bool deleteExisting);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool UpdateResourceW(IntPtr update, IntPtr type, IntPtr name,
            ushort language, byte[] data, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool EndUpdateResourceW(IntPtr update, bool discard);

        static void Align(BinaryWriter writer) {
            while (writer.BaseStream.Position % 4 != 0) writer.Write((byte)0);
        }

        static byte[] Block(string key, ushort type, byte[] value, params byte[][] children) {
            using (var stream = new MemoryStream())
            using (var writer = new BinaryWriter(stream)) {
                writer.Write((ushort)0);
                writer.Write(checked((ushort)(type == 1 ? value.Length / 2 : value.Length)));
                writer.Write(type);
                writer.Write(Encoding.Unicode.GetBytes(key + "\0"));
                Align(writer);
                writer.Write(value);
                foreach (var child in children) { Align(writer); writer.Write(child); }
                var size = checked((ushort)stream.Length);
                stream.Position = 0;
                writer.Write(size);
                return stream.ToArray();
            }
        }

        public static void Update(string path, string version) {
            var parts = version.Replace('+', '.').Split('.').Select(ushort.Parse).ToArray();
            var high = ((uint)parts[0] << 16) | parts[1];
            var low = ((uint)parts[2] << 16) | parts[3];
            byte[] fixedInfo;
            using (var stream = new MemoryStream())
            using (var writer = new BinaryWriter(stream)) {
                foreach (var word in new uint[] {
                    0xFEEF04BD, 0x10000, high, low, high, low,
                    0x3F, 0, 0x40004, 1, 0, 0, 0
                }) writer.Write(word);
                fixedInfo = stream.ToArray();
            }
            var strings = new Dictionary<string, string> {
                {"CompanyName", "com.idreaml"},
                {"FileDescription", "Idreaml Clip"},
                {"FileVersion", version},
                {"InternalName", "idreaml_clip"},
                {"LegalCopyright", "Copyright (C) 2026 com.idreaml. All rights reserved."},
                {"OriginalFilename", "idreaml_clip.exe"},
                {"ProductName", "Idreaml Clip"},
                {"ProductVersion", version}
            };
            var entries = strings.Select(pair => Block(pair.Key, 1,
                Encoding.Unicode.GetBytes(pair.Value + "\0"))).ToArray();
            var empty = new byte[0];
            var stringInfo = Block("StringFileInfo", 1, empty,
                Block("040904e4", 1, empty, entries));
            var varInfo = Block("VarFileInfo", 1, empty,
                Block("Translation", 0, new byte[] {0x09, 0x04, 0xE4, 0x04}));
            var data = Block("VS_VERSION_INFO", 0, fixedInfo, stringInfo, varInfo);
            var handle = BeginUpdateResourceW(path, false);
            if (handle == IntPtr.Zero) throw new Win32Exception();
            try {
                if (!UpdateResourceW(handle, new IntPtr(16), new IntPtr(1),
                    0x409, data, (uint)data.Length)) throw new Win32Exception();
                var committing = handle;
                handle = IntPtr.Zero;
                if (!EndUpdateResourceW(committing, false)) throw new Win32Exception();
            } finally {
                if (handle != IntPtr.Zero) EndUpdateResourceW(handle, true);
            }
        }
    }
}
'@
}
[IdreamlPackaging.FileVersionResource]::Update($target, $Version)
$actual = [Diagnostics.FileVersionInfo]::GetVersionInfo($target)
if ($actual.FileVersion -ne $Version -or $actual.ProductVersion -ne $Version) {
    throw "Failed to update runner version: $target"
}
