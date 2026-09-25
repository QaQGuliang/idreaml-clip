; Build using package-windows-installer.ps1 and Inno Setup 7.1 or newer.
#ifndef BundleDir
  #error BundleDir must point to a verified Windows release bundle.
#endif
#ifndef PackageVersion
  #error PackageVersion is required.
#endif
#ifndef DisplayVersion
  #error DisplayVersion is required.
#endif
#ifndef NumericVersion
  #error NumericVersion is required.
#endif
#ifndef InstallerOutputDir
  #error InstallerOutputDir is required.
#endif

[Setup]
; Keep the identity of the existing 0.1.0 Windows installer for upgrades.
AppId={{B2D7B7E4-6F2C-40AB-9A66-3F9E8A5C8A6E}
AppName=Idreaml Clip
AppVersion={#DisplayVersion}
AppVerName=Idreaml Clip {#PackageVersion}
AppPublisher=Idreaml
DefaultDirName={autopf}\Idreaml\Idreaml Clip
DefaultGroupName=Idreaml Clip
DisableProgramGroupPage=yes
DisableDirPage=no
DisableWelcomePage=no
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0
UninstallDisplayName=Idreaml Clip
UninstallDisplayIcon={app}\idreaml_clip.exe
SetupIconFile=..\windows\runner\resources\app_icon.ico
OutputDir={#InstallerOutputDir}
OutputBaseFilename=Idreaml-Clip-{#PackageVersion}-windows-x64-setup
VersionInfoVersion={#NumericVersion}
VersionInfoDescription=Idreaml Clip Installer
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
SetupMutex=Local\Idreaml.Clip.B2D7B7E4-6F2C-40AB-9A66-3F9E8A5C8A6E.Setup

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
chinesesimplified.WelcomeLabel2=即将在您的计算机上安装 [name/ver]。%n%n支持 Windows 10 及以上的 x86-64 系统，已包含所需运行库。%n%n安装时将自动关闭该安装目录中正在运行的 Idreaml Clip。
english.WelcomeLabel2=This will install [name/ver] on your computer.%n%nRequires Windows 10 or later on x86-64. Required runtime libraries are included.%n%nSetup will close Idreaml Clip running from the target installation folder.

[CustomMessages]
chinesesimplified.ApplicationCloseFailed=无法结束正在运行的 Idreaml Clip，尚未修改安装文件。请退出该程序后重试；如果程序以管理员身份运行，请以管理员身份运行安装或卸载程序。
english.ApplicationCloseFailed=Could not close the running Idreaml Clip. Installation files have not been changed. Exit the application and try again; if it is elevated, run Setup or Uninstall as administrator.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Idreaml Clip"; Filename: "{app}\idreaml_clip.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Idreaml Clip"; Filename: "{app}\idreaml_clip.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\idreaml_clip.exe"; WorkingDir: "{app}"; Description: "{cm:LaunchProgram,Idreaml Clip}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
#include "windows-process-lifecycle.iss"

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := PrepareApplicationMaintenance;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  // Allow the normal post-install launch after files have been replaced.
  if CurStep = ssPostInstall then EndApplicationMaintenance;
end;

procedure DeinitializeSetup;
begin
  EndApplicationMaintenance;
end;

procedure DeinitializeUninstall;
begin
  EndApplicationMaintenance;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  StartupValue: String;
  Executable: String;
  ShutdownError: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    ShutdownError := PrepareApplicationMaintenance;
    if ShutdownError <> '' then begin
      SuppressibleMsgBox(ShutdownError, mbError, MB_OK, IDOK);
      Abort;
    end;
    // Only remove startup for this installed copy, never another portable copy.
    Executable := InstalledExecutable;
    if RegQueryStringValue(HKCU,
      'Software\Microsoft\Windows\CurrentVersion\Run',
      'Idreaml Clip', StartupValue) then
    begin
      if (CompareText(StartupValue, Executable) = 0) or
        (CompareText(StartupValue, '"' + Executable + '"') = 0) then
        RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run',
          'Idreaml Clip');
    end;
  end;
end;
