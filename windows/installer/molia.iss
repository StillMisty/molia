; Molia Windows 安装器（Inno Setup 6）
;
; 由 .github/workflows/release.yml 的 windows job 调用：
;   ISCC.exe /DAppVersion=0.1.0-beta.1 /DVersionNum=0.1.0.123 \
;            /DSourceDir=<staging> /DOutputDir=<dist> windows\installer\molia.iss
;
; 设计要点：
; - **按用户安装**（PrivilegesRequired=lowest，装到 %LOCALAPPDATA%\Programs\Molia）：
;   不需要管理员权限，且安装目录可写 —— 应用内更新才能直接跑新版安装器；
; - **静默升级**：[Run] 段不带 skipifsilent，`/SILENT` 安装完成后自动重启应用，
;   应用内更新只需启动新版 setup.exe 后自行退出（见 ADR-0006）；
; - CloseApplications（Restart Manager）负责在安装时优雅关闭仍在运行的 molia，
;   RestartApplications 置 no：重启统一由 [Run] 段负责，避免重复启动；
; - 卸载只删程序文件；用户数据（%APPDATA%\top.stillmisty.molia 与曲库）保留。

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

; 版本资源必须是纯数字 x.y.z(.w)：带预发布后缀的 tag 由 CI 传入数值化版本。
#ifndef VersionNum
  #define VersionNum "0.0.0.0"
#endif

; 待打包的 Flutter Release 目录（由 CI 传入绝对路径）。
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

; 安装器输出目录（默认仓库根 dist/）。
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

#define AppName "Molia"
#define AppPublisher "StillMisty"
#define AppUrl "https://github.com/StillMisty/molia"
#define AppExeName "molia.exe"

[Setup]
; AppId 是升级/卸载的身份：一旦发布不可更改。
AppId={{7E2A9C61-5B4E-4A3D-9F1C-2D8B6A0E5C47}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
AllowNoIcons=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=molia-{#AppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
VersionInfoVersion={#VersionNum}
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#VersionNum}
CloseApplications=yes
RestartApplications=no

[Languages]
; 中文语言包在部分 Inno 版本里不随附：有则显示中文向导，无则退回英文。
Name: "english"; MessagesFile: "compiler:Default.isl"
#if FileExists(AddBackslash(CompilerPath) + "Languages\ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
; 静默升级也走这里：应用内更新启动 setup 后自行退出，安装完由本行拉起新版。
Filename: "{app}\{#AppExeName}"; Flags: nowait
