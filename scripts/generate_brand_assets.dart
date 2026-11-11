// Regenerate platform icons from the approved, transparent master artwork.
// Run directly, using the project's already resolved dependencies (no pub):
// dart --packages=.dart_tool/package_config.json scripts/generate_brand_assets.dart
// Add --check to verify the generated assets without writing any files.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

void main(List<String> arguments) {
  if (arguments.any((argument) => argument != '--check')) {
    stderr.writeln('Usage: generate_brand_assets.dart [--check]');
    exitCode = 64;
    return;
  }
  final checkOnly = arguments.contains('--check');
  final root = File.fromUri(Platform.script).parent.parent;
  File asset(String relative) => File('${root.path}/$relative');
  final master = asset('assets/brand/idreaml_logo.png').readAsBytesSync();
  final image = img.decodePng(master);
  if (image == null || image.width != image.height || image.numChannels != 4) {
    throw StateError('The brand master must be a square RGBA PNG.');
  }
  // Preserve the complete artwork and transparent padding. No cropping,
  // recoloring, added background, or separate tray-specific drawing is used.
  img.Image sized(int size) => img.copyResize(
    image,
    width: size,
    height: size,
    interpolation: img.Interpolation.average,
  );
  const iconSizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];
  final icon = img.IcoEncoder().encodeImages([
    for (final size in iconSizes) sized(size),
  ]);
  final outputs = <String, List<int>>{
    'windows/runner/resources/app_icon.ico': icon,
    'assets/tray_icon.ico': icon,
    'assets/tray_icon.png': img.encodePng(sized(128)),
    for (final size in [16, 32, 64, 128, 256, 512, 1024])
      'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png': img
          .encodePng(sized(size)),
  };
  var mismatches = 0;
  for (final output in outputs.entries) {
    final destination = asset(output.key);
    final expectedHash = sha256.convert(output.value).toString();
    if (checkOnly) {
      final matches =
          destination.existsSync() &&
          sha256.convert(destination.readAsBytesSync()).toString() ==
              expectedHash;
      if (!matches) mismatches++;
      stdout.writeln('${matches ? 'OK' : 'MISMATCH'} ${output.key}');
    } else {
      destination.parent.createSync(recursive: true);
      destination.writeAsBytesSync(output.value, flush: true);
      stdout.writeln('Generated ${output.key}');
    }
  }
  stdout.writeln('Master SHA-256: ${sha256.convert(master)}');
  stdout.writeln('ICO sizes: ${iconSizes.join(', ')}');
  if (mismatches != 0) exitCode = 1;
}
