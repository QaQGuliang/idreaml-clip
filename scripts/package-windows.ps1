[CmdletBinding()]
param(
    [string]$Flutter = 'flutter',
    [string]$OutputDirectory = 'dist/windows',
    [string]$RuntimeDirectory = "$env:WINDIR/System32",
    # Optional fallback: reuse an already validated native runner and plugins,
    # while compiling the current Dart code and assets in release mode.
    [string]$PrebuiltNativeDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-X64Binary([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw "Not a Windows binary: $Path"
    }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($peOffset -lt 0 -or $peOffset + 6 -gt $bytes.Length -or
        [BitConverter]::ToUInt32($bytes, $peOffset) -ne 0x4550 -or
        [BitConverter]::ToUInt16($bytes, $peOffset + 4) -ne 0x8664) {
        throw "Expected an x86-64 binary: $Path"
    }
}

function Invoke-Flutter([string[]]$Arguments) {
    & $script:flutterPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Flutter failed (exit $LASTEXITCODE)." }
}

Push-Location $projectRoot
try {
    $script:flutterPath = (Get-Command $Flutter -ErrorAction Stop).Source
    $sdkRoot = Split-Path (Split-Path $script:flutterPath -Parent) -Parent
    $versionMatch = [regex]::Match((Get-Content pubspec.yaml -Raw), '(?m)^version:\s*(\S+)')
    if (-not $versionMatch.Success) { throw 'pubspec.yaml must specify a version.' }
    $version = $versionMatch.Groups[1].Value
    $releaseInfo = Get-Content (Join-Path $projectRoot 'assets/release-info.json') -Raw | ConvertFrom-Json
    if ("$($releaseInfo.version)+$($releaseInfo.build)" -ne $version) {
        throw 'Release notes version does not match pubspec.yaml.'
    }
    $packageName = "Idreaml-Clip-$version-windows-x64"
    $outputRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot $OutputDirectory))
    $stage = Join-Path $outputRoot $packageName
    $archive = "$stage.zip"
    if ((Test-Path -LiteralPath $stage) -or (Test-Path -LiteralPath $archive)) {
        throw "Output already exists. Choose a new -OutputDirectory: $stage"
    }

    $nativeMode = 'full-native-build'
    if ($PrebuiltNativeDirectory) {
        $nativeRoot = (Resolve-Path -LiteralPath $PrebuiltNativeDirectory).Path
        Assert-X64Binary (Join-Path $nativeRoot 'idreaml_clip.exe')
        Write-Warning 'Reusing prebuilt native binaries. Dart AOT and assets will be rebuilt.'
        $nativeMode = 'prebuilt-native-with-fresh-dart-aot'
        $bundle = Join-Path $projectRoot 'build/windows-release-bundle'
        Invoke-Flutter -Arguments @('assemble', '--no-version-check', "--output=$bundle",
            '-dTargetPlatform=windows-x64', '-dTrackWidgetCreation=false',
            '-dBuildMode=release', '-dTargetFile=lib/main.dart',
            '-dTreeShakeIcons=true', '-dDartObfuscation=false',
            'release_bundle_windows-x64_assets')
    } else {
        # Flutter selects the Windows target from the host architecture.
        if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
            throw 'Full native packaging requires an x86-64 Windows build host.'
        }
        Invoke-Flutter -Arguments @('build', 'windows', '--release')
        $nativeRoot = Join-Path $projectRoot 'build/windows/x64/runner/Release'
    }

    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $nativeRoot 'idreaml_clip.exe') -Destination $stage
    if ($PrebuiltNativeDirectory) {
        & (Join-Path $PSScriptRoot 'set-windows-file-version.ps1') `
            -Path (Join-Path $stage 'idreaml_clip.exe') -Version $version
    }
    Get-ChildItem -LiteralPath $nativeRoot -Filter '*.dll' -File |
        Copy-Item -Destination $stage
    if ($PrebuiltNativeDirectory) {
        $data = Join-Path $stage 'data'
        New-Item -ItemType Directory -Path $data | Out-Null
        Copy-Item -LiteralPath (Join-Path $bundle 'windows/app.so') -Destination $data
        Copy-Item -LiteralPath (Join-Path $bundle 'flutter_assets') -Destination $data -Recurse
        Copy-Item -LiteralPath (Join-Path $sdkRoot 'bin/cache/artifacts/engine/windows-x64/icudtl.dat') -Destination $data
        Copy-Item -LiteralPath (Join-Path $sdkRoot 'bin/cache/artifacts/engine/windows-x64-release/flutter_windows.dll') -Destination $stage -Force
        Copy-Item -LiteralPath (Join-Path $bundle 'flutter_assets/NativeAssetsManifest.json') -Destination (Join-Path $stage 'native_assets.json')
    } else {
        Copy-Item -LiteralPath (Join-Path $nativeRoot 'data') -Destination $stage -Recurse
        $nativeManifest = Join-Path $nativeRoot 'native_assets.json'
        if (Test-Path -LiteralPath $nativeManifest) {
            Copy-Item -LiteralPath $nativeManifest -Destination $stage
        }
    }

    # Flutter's application-local deployment layout. These are redistributable
    # C++ runtime files, not arbitrary Windows system DLLs.
    foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        $source = Join-Path $RuntimeDirectory $name
        Assert-X64Binary $source
        $signature = Get-AuthenticodeSignature -LiteralPath $source
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
            throw "The Microsoft runtime signature is invalid: $source"
        }
        Copy-Item -LiteralPath $source -Destination $stage -Force
    }
    Get-ChildItem -LiteralPath $stage -File | Where-Object { $_.Extension -in '.exe', '.dll' } |
        ForEach-Object { Assert-X64Binary $_.FullName }
    foreach ($required in @('data/app.so', 'data/icudtl.dat',
        'data/flutter_assets/AssetManifest.bin', 'data/flutter_assets/NOTICES.Z',
        'data/flutter_assets/assets/tray_icon.ico', 'libgit2.dll', 'libssh2.dll',
        'libcrypto-3-x64.dll', 'libssl-3-x64.dll',
        'data/flutter_assets/packages/git2dart_binaries/assets/certs/cacert.pem')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $required))) {
            throw "Missing required release file: $required"
        }
    }

    Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows-package-readme.txt') -Destination (Join-Path $stage 'README.txt')
    $releaseNotes = @("Idreaml Clip $($releaseInfo.version)", $releaseInfo.date, '', '更新内容')
    $releaseNotes += @($releaseInfo.changes | ForEach-Object { "- $_" })
    if ($releaseInfo.knownIssues.Count) {
        $releaseNotes += @('', '待解决')
        $releaseNotes += @($releaseInfo.knownIssues | ForEach-Object { "- $_" })
    }
    $releaseNotes | Set-Content -LiteralPath (Join-Path $stage 'RELEASE-NOTES.txt') -Encoding UTF8
    $sdkVersion = Get-Content (Join-Path $sdkRoot 'bin/cache/flutter.version.json') -Raw | ConvertFrom-Json
    $fileHashes = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    [ordered]@{
        product = 'Idreaml Clip'
        version = $version
        releaseNotes = $releaseInfo
        platform = 'windows-x64'
        buildMode = 'release'
        nativeBuild = $nativeMode
        flutterVersion = $sdkVersion.flutterVersion
        dartVersion = $sdkVersion.dartSdkVersion
        builtAtUtc = [DateTime]::UtcNow.ToString('o')
        files = $fileHashes
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'build-info.json') -Encoding UTF8

    Compress-Archive -LiteralPath $stage -DestinationPath $archive -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $packageName.zip" | Set-Content -LiteralPath "$archive.sha256" -Encoding ASCII
    Write-Output "Package: $archive"
    Write-Output "SHA256: $hash"
    Write-Output "Executable: $(Join-Path $stage 'idreaml_clip.exe')"
} finally {
    Pop-Location
}
