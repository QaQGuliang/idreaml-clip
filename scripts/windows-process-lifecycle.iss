// Shared by the production installer and the isolated lifecycle smoke test.
// Keep Namespace and UTF-16LE path hashing in sync with windows_app_instance.dart.
#ifndef LifecycleNamespace
  #define LifecycleNamespace "Local\Idreaml.Clip.B2D7B7E4-6F2C-40AB-9A66-3F9E8A5C8A6E"
#endif
const
  InstanceNamespace = '{#LifecycleNamespace}';
  ProcessQueryLimitedInformation = $1000;
  ProcessTerminate = $0001;
  SynchronizeAccess = $00100000;
  EventModifyState = $0002;
  WaitSignaled = 0;
  WaitTimeout = 258;

var
  MaintenanceHandle: THandle;

function OpenProcessAccess(Access: Cardinal; InheritHandle: Boolean;
  ProcessId: Cardinal): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function CloseNativeHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function QueryProcessPath(Process: THandle; Flags: Cardinal;
  Filename: String; var Size: Cardinal): Boolean;
  external 'QueryFullProcessImageNameW@kernel32.dll stdcall';
function TerminateNativeProcess(Process: THandle; ExitCode: Cardinal): Boolean;
  external 'TerminateProcess@kernel32.dll stdcall';
function WaitNativeObject(Handle: THandle; Milliseconds: Cardinal): Cardinal;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function OpenNativeEvent(Access: Cardinal; InheritHandle: Boolean;
  Name: String): THandle;
  external 'OpenEventW@kernel32.dll stdcall';
function CreateNativeEvent(Attributes: NativeInt; ManualReset, InitialState: Boolean;
  Name: String): THandle;
  external 'CreateEventW@kernel32.dll stdcall';
function SignalNativeEvent(Handle: THandle): Boolean;
  external 'SetEvent@kernel32.dll stdcall';

function InstalledExecutable: String;
begin
  Result := ExpandFileName(ExpandConstant('{app}\idreaml_clip.exe'));
end;

function InstalledExecutableKey: String;
begin
  Result := GetSHA256OfUnicodeString(LowerCase(InstalledExecutable));
end;

procedure EndApplicationMaintenance;
begin
  if MaintenanceHandle <> 0 then begin
    CloseNativeHandle(MaintenanceHandle);
    MaintenanceHandle := 0;
  end;
end;

function BeginApplicationMaintenance: Boolean;
begin
  if MaintenanceHandle = 0 then
    MaintenanceHandle := CreateNativeEvent(0, True, True,
      InstanceNamespace + '.Maintenance.' + InstalledExecutableKey);
  Result := MaintenanceHandle <> 0;
end;

procedure RequestApplicationShutdown;
var
  ShutdownHandle: THandle;
begin
  ShutdownHandle := OpenNativeEvent(EventModifyState, False,
    InstanceNamespace + '.Shutdown.' + InstalledExecutableKey);
  if ShutdownHandle <> 0 then begin
    try
      SignalNativeEvent(ShutdownHandle);
    finally
      CloseNativeHandle(ShutdownHandle);
    end;
  end;
end;

function ReadProcessPath(Handle: THandle): String;
var
  Size: Cardinal;
begin
  Size := 32768;
  SetLength(Result, Size);
  if QueryProcessPath(Handle, 0, Result, Size) then
    SetLength(Result, Size)
  else
    Result := '';
end;

function StopInstalledApplication: Boolean;
var
  Locator, Services, Processes, Process: Variant;
  Handles: array of THandle;
  Handle: THandle;
  Index, Count: Integer;
  AllExited: Boolean;
  WaitResult: Cardinal;
  Executable: String;
begin
  Result := False;
  Executable := InstalledExecutable;
  SetArrayLength(Handles, 0);
  try
   try
    // Enumerate IDs with WMI, then verify executable identity on a held native
    // handle. Never kill all processes by filename: portable copies are distinct.
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Services := Locator.ConnectServer('', 'root\CIMV2');
    Processes := Services.ExecQuery(
      'SELECT ProcessId, ExecutablePath FROM Win32_Process WHERE Name="idreaml_clip.exe"');
    for Index := 0 to Processes.Count - 1 do begin
      Process := Processes.ItemIndex(Index);
      Handle := OpenProcessAccess(ProcessQueryLimitedInformation or
        ProcessTerminate or SynchronizeAccess, False, Process.ProcessId);
      if Handle <> 0 then begin
        if CompareText(ReadProcessPath(Handle), Executable) = 0 then begin
          Count := GetArrayLength(Handles);
          SetArrayLength(Handles, Count + 1);
          Handles[Count] := Handle;
        end else
          CloseNativeHandle(Handle);
      end else if not VarIsNull(Process.ExecutablePath) then begin
        if CompareText(Process.ExecutablePath, Executable) = 0 then begin
          Log('Cannot obtain shutdown access to the installed application.');
          Exit;
        end;
      end;
    end;

    RequestApplicationShutdown;
    // New versions stop hooks, tray and SQLite themselves. Hold the process
    // handles until actual process exit, rather than merely waiting for a window.
    for Count := 1 to 80 do begin
      AllExited := True;
      for Index := 0 to GetArrayLength(Handles) - 1 do
        if WaitNativeObject(Handles[Index], 0) = WaitTimeout then
          AllExited := False;
      if AllExited then Break;
      Sleep(100);
    end;
    for Index := 0 to GetArrayLength(Handles) - 1 do begin
      WaitResult := WaitNativeObject(Handles[Index], 0);
      if WaitResult = WaitTimeout then begin
        // Compatibility with old releases which do not implement the shutdown
        // event, or a hung instance, limited to this exact installation path.
        Log('Stopping the remaining process from the target installation.');
        if not TerminateNativeProcess(Handles[Index], 0) then Exit;
        WaitResult := WaitNativeObject(Handles[Index], 5000);
      end;
      if WaitResult <> WaitSignaled then Exit;
    end;
    Result := True;
  except
    Log('Application shutdown failed: ' + GetExceptionMessage);
   end;
  finally
    for Index := 0 to GetArrayLength(Handles) - 1 do
      CloseNativeHandle(Handles[Index]);
  end;
end;

function PrepareApplicationMaintenance: String;
begin
  Result := '';
  if not BeginApplicationMaintenance or not StopInstalledApplication then begin
    EndApplicationMaintenance;
    Result := CustomMessage('ApplicationCloseFailed');
  end;
end;
