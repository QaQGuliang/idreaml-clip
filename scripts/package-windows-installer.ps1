[CmdletBinding()]
param(
    [string]$BundleDirectory,
    [string]$OutputDirectory = 'dist/windows',
    [string]$InnoCompiler = 'build/tools/innosetup/ISCC.exe'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Resolve-ProjectPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $projectRoot $Path))
}

Push-Location $projectRoot
try {
    $versionMatch = [regex]::Match((Get-Content pubspec.yaml -Raw),
        '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*$')
    if (-not $versionMatch.Success) { throw 'Expected a numeric version in pubspec.yaml.' }
    $displayVersion = $versionMatch.Groups[1].Value
    $buildNumber = if ($versionMatch.Groups[2].Success) { $versionMatch.Groups[2].Value } else { '0' }
    $packageVersion = if ($versionMatch.Groups[2].Success) { "$displayVersion+$buildNumber" } else { $displayVersion }
    if (-not $BundleDirectory) { $BundleDirectory = "dist/windows/Idreaml-Clip-$packageVersion-windows-x64" }
    $bundle = (Resolve-Path -LiteralPath (Resolve-ProjectPath $BundleDirectory)).Path
    $compiler = (Resolve-Path -LiteralPath (Resolve-ProjectPath $InnoCompiler)).Path
    $output = Resolve-ProjectPath $OutputDirectory
    $installerName = "Idreaml-Clip-$packageVersion-windows-x64-setup.exe"
    $installer = Join-Path $output $installerName
    if (Test-Path -LiteralPath $installer) { throw "Installer already exists: $installer" }

    # Verify the precise bundle that produced the portable ZIP before wrapping it.
    $info = Get-Content (Join-Path $bundle 'build-info.json') -Raw | ConvertFrom-Json
    if ($info.version -ne $packageVersion -or $info.platform -ne 'windows-x64' -or $info.buildMode -ne 'release') {
        throw 'Release bundle version, platform or build mode does not match.'
    }
    $bundlePrefix = $bundle.TrimEnd('\') + '\'
    foreach ($entry in $info.files) {
        $file = [IO.Path]::GetFullPath((Join-Path $bundle $entry.path))
        if (-not $file.StartsWith($bundlePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "File escapes the release bundle: $($entry.path)"
        }
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($actual -ne $entry.sha256) { throw "Release file changed: $($entry.path)" }
    }
    $allFiles = @(Get-ChildItem -LiteralPath $bundle -Recurse -File)
    if ($allFiles.Count -ne $info.files.Count + 1) { throw 'Release bundle contains unexpected files.' }
    if (@(Get-ChildItem -LiteralPath $bundle -Recurse -Attributes ReparsePoint).Count) {
        throw 'Release bundle must not contain links.'
    }
    foreach ($file in $allFiles | Where-Object { $_.Extension -in '.exe', '.dll' }) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
        if ([BitConverter]::ToUInt16($bytes, $peOffset + 4) -ne 0x8664) {
            throw "Not an x86-64 binary: $($file.Name)"
        }
    }

    New-Item -ItemType Directory -Path $output -Force | Out-Null
    & $compiler '/Qp' "/DBundleDir=$bundle" "/DPackageVersion=$packageVersion" `
        "/DDisplayVersion=$displayVersion" "/DNumericVersion=$displayVersion.$buildNumber" `
        "/DInstallerOutputDir=$output" (Join-Path $PSScriptRoot 'windows-installer.iss')
    if ($LASTEXITCODE -ne 0) { throw "Installer compiler failed (exit $LASTEXITCODE)." }
    $installerBytes = [IO.File]::ReadAllBytes($installer)
    $installerPE = [BitConverter]::ToInt32($installerBytes, 0x3C)
    if ([BitConverter]::ToUInt16($installerBytes, $installerPE + 4) -ne 0x8664) {
        throw 'The installer bootstrap must also be x86-64.'
    }
    $hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $installerName" | Set-Content -LiteralPath "$installer.sha256" -Encoding ASCII
    Write-Output "Installer: $installer"
    Write-Output "SHA256: $hash"
}
finally {
    Pop-Location
}
