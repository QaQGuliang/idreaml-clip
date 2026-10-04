[CmdletBinding()]
param(
    [string]$Dart = 'C:\tools\flutter\bin\dart.bat',
    [string]$InnoCompiler = 'build/tools/innosetup/ISCC.exe'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testId = [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path $projectRoot "build/lifecycle-test-$testId"
$namespace = "Local\Idreaml.Clip.Test.$testId"
$peers = [Collections.Generic.List[object]]::new()

function Start-Peer([string]$Directory, [string]$Mode, [string]$Label) {
    $exe = Join-Path $Directory 'idreaml_clip.exe'
    $log = Join-Path $testRoot "$Label.log"
    $process = Start-Process -FilePath $exe -ArgumentList @($Mode, $namespace) `
        -WorkingDirectory $Directory -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.stderr"
    $peer = [PSCustomObject]@{ Process = $process; Exe = $exe; Log = $log }
    $peers.Add($peer)
    return $peer
}

function Wait-Log($Peer, [string]$Expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ((Test-Path -LiteralPath $Peer.Log) -and
            ((Get-Content -LiteralPath $Peer.Log) -contains $Expected)) { return }
        Start-Sleep -Milliseconds 50
    }
    throw "Missing '$Expected' from $($Peer.Log)"
}

function Stop-TestPeer($Peer) {
    $running = Get-Process -Id $Peer.Process.Id -ErrorAction SilentlyContinue
    if ($running) {
        # Never stop a PID unless it still resolves to the exact test executable.
        if ($running.Path -ne $Peer.Exe -or
            -not $running.Path.StartsWith($testRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to stop a process outside the isolated test directory.'
        }
        Stop-Process -Id $running.Id
        $Peer.Process.WaitForExit(5000) | Out-Null
    }
}

function Invoke-Maintenance([string]$Label) {
    $harness = Join-Path $testRoot 'lifecycle-smoke.exe'
    $log = Join-Path $testRoot "$Label-installer.log"
    $process = Start-Process -FilePath $harness -WindowStyle Hidden -PassThru -Wait `
        -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
            "/DIR=`"$installed`"", "/LOG=`"$log`"")
    if ($process.ExitCode -ne 0) { throw "Maintenance failed; inspect $log" }
}

Push-Location $projectRoot
try {
    $installed = Join-Path $testRoot 'installed-中文'
    $portable = Join-Path $testRoot 'portable'
    New-Item -ItemType Directory -Path $installed, $portable | Out-Null
    & $Dart compile exe tool/instance_test_peer.dart -o (Join-Path $installed 'idreaml_clip.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Peer compilation failed' }
    Copy-Item -LiteralPath (Join-Path $installed 'idreaml_clip.exe') -Destination $portable

    # No registry entry, shortcuts, uninstall registration or user files. This
    # fixture runs the exact production maintenance function against test peers.
    $include = Join-Path $PSScriptRoot 'windows-process-lifecycle.iss'
    $iss = @"
#define LifecycleNamespace "$namespace"
[Setup]
AppId=IdreamlClipLifecycleSmoke-$testId
AppName=Idreaml lifecycle smoke
AppVersion=1
DefaultDirName=$installed
SetupArchitecture=x64
PrivilegesRequired=lowest
Uninstallable=yes
CreateUninstallRegKey=no
DisableProgramGroupPage=yes
OutputDir=$testRoot
OutputBaseFilename=lifecycle-smoke
[CustomMessages]
ApplicationCloseFailed=Application shutdown failed
[Code]
#include "$include"
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := PrepareApplicationMaintenance;
end;
procedure DeinitializeSetup;
begin
  EndApplicationMaintenance;
end;
procedure CurUninstallStepChanged(Step: TUninstallStep);
begin
  if Step = usUninstall then
    if PrepareApplicationMaintenance <> '' then Abort;
end;
procedure DeinitializeUninstall;
begin
  EndApplicationMaintenance;
end;
"@
    $source = Join-Path $testRoot 'lifecycle-smoke.iss'
    Set-Content -LiteralPath $source -Value $iss -Encoding utf8
    & $InnoCompiler '/Q' $source
    if ($LASTEXITCODE -ne 0) { throw 'Maintenance fixture compilation failed' }

    $race = @(0..7 | ForEach-Object { Start-Peer $installed 'normal' "race-$_" })
    foreach ($peer in $race) {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path -LiteralPath $peer.Log) -or
            -not (Get-Content -LiteralPath $peer.Log)) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Startup race timed out' }
            Start-Sleep -Milliseconds 50
        }
    }
    $winners = @($race | Where-Object { (Get-Content -LiteralPath $_.Log) -contains 'primary' })
    $losers = @($race | Where-Object { (Get-Content -LiteralPath $_.Log) -contains 'secondary' })
    if ($winners.Count -ne 1 -or $losers.Count -ne 7) { throw 'More than one primary instance' }
    foreach ($peer in $losers) {
        if (-not $peer.Process.WaitForExit(5000)) { throw 'Secondary did not exit' }
    }
    $primary = $winners[0]
    Wait-Log $primary 'activated'
    $other = Start-Peer $portable 'normal' 'portable-secondary'
    Wait-Log $other 'secondary'
    if (-not $other.Process.WaitForExit(5000)) { throw 'Portable second instance did not exit' }
    Write-Output 'PASS: eight concurrent launches produce one primary; portable copy activates it.'

    $unrelated = Start-Peer $portable 'legacy' 'unrelated-portable'
    Wait-Log $unrelated 'legacy'
    Invoke-Maintenance 'graceful'
    Wait-Log $primary 'shutdown'
    if (-not $primary.Process.WaitForExit(5000)) { throw 'Primary did not terminate' }
    if ($unrelated.Process.HasExited) { throw 'Unrelated portable copy was terminated' }
    Write-Output 'PASS: installer requests graceful exit; other directory is untouched.'

    $crash = Start-Peer $installed 'normal' 'crash'
    Wait-Log $crash 'primary'
    Stop-TestPeer $crash
    $restart = Start-Peer $installed 'normal' 'restart'
    Wait-Log $restart 'primary'
    Stop-TestPeer $restart
    Write-Output 'PASS: process death releases the instance lock and restart succeeds.'

    $legacyA = Start-Peer $installed 'legacy' 'legacy-a'
    $legacyB = Start-Peer $installed 'legacy' 'legacy-b'
    Wait-Log $legacyA 'legacy'
    Wait-Log $legacyB 'legacy'
    Invoke-Maintenance 'legacy'
    if (-not $legacyA.Process.WaitForExit(5000) -or
        -not $legacyB.Process.WaitForExit(5000)) { throw 'Legacy process survived maintenance' }
    if ($unrelated.Process.HasExited) { throw 'Portable copy was terminated during legacy cleanup' }
    Write-Output 'PASS: legacy duplicate processes are stopped only at the exact installation path.'

    $uninstallPeer = Start-Peer $installed 'normal' 'uninstall'
    Wait-Log $uninstallPeer 'primary'
    $uninstaller = Join-Path $installed 'unins000.exe'
    $uninstall = Start-Process -FilePath $uninstaller -WindowStyle Hidden -Wait -PassThru `
        -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
            "/LOG=`"$testRoot\uninstall-installer.log`"")
    if ($uninstall.ExitCode -ne 0) { throw 'Isolated uninstaller failed' }
    Wait-Log $uninstallPeer 'shutdown'
    if (-not $uninstallPeer.Process.WaitForExit(5000)) { throw 'Process survived uninstall' }
    if ($unrelated.Process.HasExited) { throw 'Uninstall stopped the other directory' }
    Write-Output 'PASS: actual Inno uninstall event waits for process exit before removing its files.'
    Write-Output "Evidence: $testRoot"
} finally {
    foreach ($peer in $peers) { Stop-TestPeer $peer }
    Pop-Location
}
