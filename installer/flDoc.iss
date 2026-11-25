; flDoc Inno Setup 6 Installer Script
; Build Release first: flutter build windows --release
; Then compile: iscc /DAppVersion=0.1.8 installer\flDoc.iss

#ifndef AppVersion
  #define AppVersion "0.1.8"
#endif

#define AppName "flDoc"
#define AppPublisher "flDoc"
#define AppExeName "fldoc.exe"
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{7B6F5C4E-82A1-4D5A-9D9E-3A1E8F4B9A2C}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
AllowNoIcons=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\build\installer
OutputBaseFilename=flDoc-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式(&D)"; GroupDescription: "附加任务:"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Excludes: "LICENSE-MIT,rg.exe"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\third_party\ripgrep\rg.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\third_party\ripgrep\LICENSE-MIT"; DestDir: "{app}"; DestName: "RIPGREP-LICENSE-MIT.txt"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "安装完成后启动 {#AppName}"; Flags: nowait postinstall skipifsilent

[Code]
// On uninstall, ask whether to delete application data (%APPDATA%\...\flDoc).
// Never delete user's document libraries (%USERPROFILE%\flDocLibrary or custom roots).
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  AppDataDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    AppDataDir := ExpandConstant('{userappdata}\dev.fldoc\fldoc');
    if not DirExists(AppDataDir) then
      AppDataDir := ExpandConstant('{userappdata}\flDoc');
    if DirExists(AppDataDir) then
    begin
      if MsgBox('是否同时删除 flDoc 的应用数据（设置、向量索引与会话历史）？' + #13#10 +
                '注意：您的本地文档库文件不会被删除。',
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      begin
        DelTree(AppDataDir, True, True, True);
      end;
    end;
  end;
end;
