param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][string]$AcceptedDataRoot,
    [Parameter(Mandatory=$true)][string]$EvidenceDir, [string]$NormalProject,
    [ValidateSet('win-arm64','win-x64')][string]$RuntimeIdentifier='win-arm64',
    [ValidateSet('Debug','Release')][string]$Configuration='Debug',
    [ValidateSet('pane','cancel','turn-on','cap','label','light','dark','night-sky','release-off','release-on','release-smoke')][string]$Step='pane', [switch]$Schedule)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $EvidenceDir | Out-Null
$EvidenceDir=(Resolve-Path -LiteralPath $EvidenceDir).Path
$resultPath=Join-Path $EvidenceDir 'result.json'
if (Test-Path -LiteralPath $resultPath) { throw 'Use a fresh evidence directory for every step and every idle-gate retry.' }
if ($Schedule) {
    $task='VoxClipVoiceLab-' + [Guid]::NewGuid().ToString('N')
    $projectArgument=if($NormalProject){' -NormalProject "'+$NormalProject+'"'}else{''}
    $arguments='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Root "'+$Root+'" -AcceptedDataRoot "'+$AcceptedDataRoot+'" -EvidenceDir "'+$EvidenceDir+'" -RuntimeIdentifier '+$RuntimeIdentifier+' -Configuration '+$Configuration+' -Step '+$Step+$projectArgument
    $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
    try {
        Register-ScheduledTask -TaskName $task -Action $action -Principal $principal | Out-Null
        Start-ScheduledTask -TaskName $task
        $deadline=[DateTime]::UtcNow.AddSeconds(420)
        while (-not (Test-Path -LiteralPath $resultPath) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (-not (Test-Path -LiteralPath $resultPath)) { Write-Error 'Voice Lab step timed out; theme restoration is unverified. Stop the native round.' -ErrorAction Continue; exit 86 }
        $observed=Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if (-not $observed.themeRestored) { Write-Error $observed.reason -ErrorAction Continue; exit 86 }
        if ($observed.status -ne 'passed' -or -not $observed.themeRestored) { throw ('Voice Lab '+$Step+': '+$observed.status+'; '+$observed.reason) }
    } finally {
        Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    }
    return
}
Add-Type -AssemblyName System.Drawing,UIAutomationClient,UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class VoiceLabNative {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Contrast { public uint Size, Flags; public IntPtr Scheme; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect bounds);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern bool SystemParametersInfo(uint action, uint param, ref Contrast value, uint flags);
    [DllImport("shlwapi.dll", CharSet=CharSet.Unicode)] public static extern int SHLoadIndirectString(string source, StringBuilder output, uint size, IntPtr reserved);
    public static bool HighContrast() { var value=new Contrast { Size=(uint)Marshal.SizeOf<Contrast>() }; if(!SystemParametersInfo(0x42,value.Size,ref value,0)) throw new InvalidOperationException("Cannot read High Contrast"); return (value.Flags & 1)!=0; }
    public static void Key(byte key) { keybd_event(key,0,0,UIntPtr.Zero);keybd_event(key,0,2,UIntPtr.Zero); }
    public static void Chord(byte modifier,byte key) { keybd_event(modifier,0,0,UIntPtr.Zero);Key(key);keybd_event(modifier,0,2,UIntPtr.Zero); }
}
'@
$root=(Resolve-Path -LiteralPath $Root).Path
$data=Join-Path $EvidenceDir 'data'
$settingsPath=Join-Path $data 'settings.json'
$receipt=Join-Path $AcceptedDataRoot 'windows-runtime-agreement.txt'
$platform=if($RuntimeIdentifier -eq 'win-arm64'){'ARM64'}else{'x64'}
$exe=Join-Path $root "apps\windows\src\VoxClip.App\bin\$platform\$Configuration\net10.0-windows10.0.26100.0\$RuntimeIdentifier\VoxClip.exe"
$app=$null
$ownedStart=0
$window=[IntPtr]::Zero
$themeChanged=$false
$themeRestored=$true
$themeFiles=@()
$originalTheme=$null
$originalContrast=$false
$status='failed'
$reason=$null
$tabOrder=New-Object 'System.Collections.Generic.List[string]'
function Assert-Space {
    if ((Get-PSDrive -Name ([IO.Path]::GetPathRoot($root).TrimEnd('\').TrimEnd(':'))).Free -lt (6GB + 1536MB)) { throw 'Native steps require 6 GiB reserve plus 1.5 GiB headroom.' }
}
function Find-Control([string]$name,[switch]$Optional) {
    $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$name)
    for($attempt=0;$attempt -lt 30;$attempt++) {
        $element=[System.Windows.Automation.AutomationElement]::FromHandle($script:window).FindFirst([System.Windows.Automation.TreeScope]::Descendants,$condition)
        if($element){return $element}
        if($Optional){return $null}
        Start-Sleep -Milliseconds 200
    }
    throw "Missing Voice Lab UIA name: $name"
}
function Invoke-Control([string]$name) {
    $element=Find-Control $name
    $pattern=$null
    if($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){$pattern.Invoke()}
    elseif($element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)){$pattern.Select()}
    else {$element.SetFocus();[VoiceLabNative]::Key(0x0D)}
    Start-Sleep -Milliseconds 400
}
function Toggle-VoiceLab {
    $element=Find-Control 'Show Voice Lab (beta)'
    $element.SetFocus()
    $pattern=$element.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $pattern.Toggle();Start-Sleep -Milliseconds 500
}
function Read-Settings {
    Start-Sleep -Milliseconds 800
    Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
}
function Assert-Flags([bool]$accepted,[bool]$enabled) {
    $saved=Read-Settings
    if(($saved.'voiceLab.betaNoticeAccepted' -eq $true) -ne $accepted -or ($saved.'voiceLab.enabled' -eq $true) -ne $enabled){throw 'Unexpected beta acceptance or enablement on disk.'}
}
function Capture([string]$name) {
    [uint32]$owner=0
    [void][VoiceLabNative]::GetWindowThreadProcessId($script:window,[ref]$owner)
    if($owner -ne $app.Id -or [VoiceLabNative]::GetForegroundWindow() -ne $script:window){throw 'Capture does not belong to the owned foreground window.'}
    $bounds=New-Object VoiceLabNative+Rect
    if(-not [VoiceLabNative]::GetWindowRect($script:window,[ref]$bounds)){throw 'No capture bounds.'}
    $bitmap=New-Object System.Drawing.Bitmap(($bounds.Right-$bounds.Left),($bounds.Bottom-$bounds.Top))
    $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
    try {$graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size);$bitmap.Save((Join-Path $EvidenceDir "$name.png"),[System.Drawing.Imaging.ImageFormat]::Png)}
    finally {$graphics.Dispose();$bitmap.Dispose()}
}
function Start-App([string]$arguments) {
    $start=New-Object System.Diagnostics.ProcessStartInfo($exe)
    $start.UseShellExecute=$false;$start.Arguments=$arguments
    $start.EnvironmentVariables['VOXCLIP_DATA_DIR']=$data
    $start.EnvironmentVariables['VOXCLIP_SHARED_DIR']=Join-Path $root 'shared'
    $start.EnvironmentVariables['VOXCLIP_LIVE_TESTS']='0'
    $script:app=[System.Diagnostics.Process]::Start($start)
    $script:ownedStart=$app.StartTime.ToUniversalTime().Ticks
}
function Settings-Window {
    $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty,$app.Id)
    for($attempt=0;$attempt -lt 60;$attempt++) {
        $windows=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,$condition)
        foreach($candidate in $windows){if($candidate.Current.Name -eq 'VoxClip Settings'){return [IntPtr]$candidate.Current.NativeWindowHandle}}
        Start-Sleep -Milliseconds 250
    }
    throw 'Settings window was not reachable.'
}
function Set-NightSky {
    $script:originalTheme=(Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes').CurrentTheme
    $script:originalContrast=[VoiceLabNative]::HighContrast()
    if(-not $script:originalTheme -or -not (Test-Path -LiteralPath $script:originalTheme)){throw 'The current theme cannot be backed up; refusing to change it.'}
    foreach($file in (@($script:originalTheme,(Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes\Custom.theme')) | Select-Object -Unique)) {
        $exists=Test-Path -LiteralPath $file
        $backup=Join-Path $EvidenceDir ('theme-'+$script:themeFiles.Count+'.theme')
        if($exists){Copy-Item -LiteralPath $file -Destination $backup}
        $script:themeFiles+=@{path=$file;exists=$exists;backup=$backup;hash=$(if($exists){(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}else{$null})}
    }
    $theme=$null
    foreach($file in (Get-ChildItem -LiteralPath (Join-Path $env:windir 'Resources\Ease of Access Themes') -Filter '*.theme')) {
        $display=@(Get-Content -LiteralPath $file.FullName | Where-Object {$_ -like 'DisplayName=*'})[0]
        if(-not $display){continue}
        $display=$display.Substring(12)
        if($display.StartsWith('@')){$buffer=New-Object System.Text.StringBuilder 256;[void][VoiceLabNative]::SHLoadIndirectString($display,$buffer,256,[IntPtr]::Zero);$display=$buffer.ToString()}
        if($display -eq 'Night sky'){$theme=$file.FullName;break}
    }
    if(-not $theme){throw 'The Night sky system theme was not found; do not substitute another contrast theme.'}
    $script:themeChanged=$true;$script:themeRestored=$false
    Start-Process -FilePath $theme
    Start-Sleep -Seconds 5
    if(-not [VoiceLabNative]::HighContrast()){throw 'Night sky did not enable High Contrast.'}
}
try {
    Assert-Space
    if(-not (Test-Path -LiteralPath $receipt)){throw 'Explicitly accept the bundled runtime terms in the isolated accepted-data root first.'}
    if(-not (Test-Path -LiteralPath $exe)){throw 'Build this configuration and architecture first.'}
    if(Get-Process VoxClip -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $exe}){throw 'Refusing to attach to an existing app process.'}
    New-Item -ItemType Directory -Path $data | Out-Null
    Copy-Item -LiteralPath $receipt -Destination (Join-Path $data 'windows-runtime-agreement.txt')
    $off=$Step -in @('cancel','turn-on','release-off')
    $appearance=if($Step -eq 'dark'){'dark'}else{'light'}
    $settings=@{schema='voxclip-settings/1';'onboarding.completed'=$true;'general.appearance'=$appearance;'voiceLab.enabled'=(-not $off);'voiceLab.betaNoticeAccepted'=(-not $off);'voiceLab.monthlyCapUsd.elevenlabs'='20'}
    $settings | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding ASCII
    if($Step -eq 'night-sky'){Set-NightSky}
    $startup=Join-Path $EvidenceDir 'startup.json'
    if($Configuration -eq 'Debug'){Start-App ('--screen settings-voicelab --self-check "'+$startup+'"')}
    else {
        Start-App ('--self-check "'+$startup+'"')
        for($attempt=0;$attempt -lt 60;$attempt++){$app.Refresh();if($app.MainWindowHandle -ne [IntPtr]::Zero){break};Start-Sleep -Milliseconds 250}
        [void][VoiceLabNative]::SetForegroundWindow($app.MainWindowHandle)
        [VoiceLabNative]::Chord(0x11,0xBC)
    }
    $script:window=Settings-Window
    [void][VoiceLabNative]::SetForegroundWindow($window)
    if([VoiceLabNative]::GetForegroundWindow() -ne $window){throw 'Settings did not take foreground; leave this step owed rather than sending keys elsewhere.'}
    if($Step -eq 'release-off') {
        if(Find-Control 'Voice Lab' -Optional){throw 'Release exposes Voice Lab while disabled.'}
    } else {
        if($Configuration -eq 'Release'){Invoke-Control 'Voice Lab'}
        [void](Find-Control 'Show Voice Lab (beta)')
        switch($Step) {
            'pane' {
                $providers=@('ElevenLabs','fal.ai','sync.so')
                $expected=@('Show Voice Lab (beta)')
                foreach($provider in $providers){[void](Find-Control ($provider+' API key'));$save=Find-Control ('Save '+$provider+' key');if($save.Current.IsEnabled){throw 'An empty key must not enable Save.'};$expected+=($provider+' API key')}
                foreach($provider in $providers){$expected+=('Warn me above this amount a month '+[char]0xB7+' '+$provider)}
                $expected+=@('Label position','Add Content Credentials (C2PA) to exports')
                $storage=Find-Control 'Show in File Explorer'
                if($storage.Current.IsEnabled -or $storage.Current.HelpText -ne 'Nothing is stored yet.'){throw 'Empty storage must have the disabled reveal explanation.'}
                (Find-Control 'Show Voice Lab (beta)').SetFocus()
                $next=0
                for($attempt=0;$attempt -lt 100 -and $next -lt $expected.Count;$attempt++) {
                    $focused=[System.Windows.Automation.AutomationElement]::FocusedElement
                    if($focused.Current.ProcessId -ne $app.Id){throw 'Tab escaped the owned app.'}
                    $tabOrder.Add($focused.Current.Name)
                    if($focused.Current.Name -eq $expected[$next]){$next++}
                    [VoiceLabNative]::Key(0x09);Start-Sleep -Milliseconds 100
                }
                if($next -ne $expected.Count){throw ('Unexpected Voice Lab Tab order; next expected '+$expected[$next])}
            }
            'cancel' {
                Toggle-VoiceLab
                [void](Find-Control 'Turn on Voice Lab?');[void](Find-Control 'Cancel')
                [VoiceLabNative]::Key(0x0D);Assert-Flags $false $false
                if(Find-Control 'Turn on Voice Lab?' -Optional){throw 'The default Cancel did not close the notice.'}
            }
            'turn-on' {
                Toggle-VoiceLab;[void](Find-Control 'Turn on Voice Lab?');Invoke-Control 'Turn on';Assert-Flags $true $true
                Toggle-VoiceLab;Assert-Flags $true $false
                Toggle-VoiceLab;Assert-Flags $true $true
                if(Find-Control 'Turn on Voice Lab?' -Optional){throw 'An accepted notice was shown again.'}
            }
            'cap' {
                $cap=Find-Control ('Warn me above this amount a month '+[char]0xB7+' ElevenLabs')
                $cap.SetFocus();$value=$cap.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern);$value.SetValue('abc');[VoiceLabNative]::Key(0x09)
                [void](Find-Control 'Enter an amount in dollars with up to two decimals, such as 20 or 12.50.')
                if((Read-Settings).'voiceLab.monthlyCapUsd.elevenlabs' -ne '20'){throw 'Invalid cap changed the old value.'}
            }
            'label' {
                $position=Find-Control 'Label position';$position.SetFocus();[VoiceLabNative]::Chord(0x12,0x28);[VoiceLabNative]::Key(0x23);[VoiceLabNative]::Key(0x0D)
                if((Read-Settings).'voiceLab.labelPosition' -ne 'bottom-left'){throw 'Bottom left did not persist.'}
                if(-not $NormalProject){$NormalProject=Join-Path $root 'voice-lab-preview\passage-render-v3.voxclip'}
                if(-not (Test-Path -LiteralPath $NormalProject)){$status='owed';throw 'Materialize the passage-render-v3 fixture source and assets in VM scratch; set -NormalProject to that project. Never ship fixtures in the App.'}
                $fixtureAssets=Join-Path (Split-Path -Parent $NormalProject) 'VoiceLab'
                if(-not (Test-Path -LiteralPath $fixtureAssets)){$status='owed';throw 'The scratch fixture needs a sibling VoiceLab folder with its hash-verified synthetic assets.'}
                Copy-Item -LiteralPath $fixtureAssets -Destination (Join-Path $data 'VoiceLab') -Recurse
                [VoiceLabNative]::Chord(0x12,0x73);Start-Sleep -Milliseconds 400
                $open=New-Object System.Diagnostics.ProcessStartInfo($exe);$open.UseShellExecute=$false;$open.Arguments='"'+$NormalProject+'"';$open.EnvironmentVariables['VOXCLIP_DATA_DIR']=$data
                $redirect=[System.Diagnostics.Process]::Start($open);if(-not $redirect.WaitForExit(10000)){throw 'Fixture file activation did not redirect.'}
                $app.Refresh();$script:window=$app.MainWindowHandle;[void][VoiceLabNative]::SetForegroundWindow($window);Start-Sleep -Seconds 3
                Capture 'bottom-left-preview'
                $status='owed';throw 'Preview frame saved. A human must verify the AI MODIFIED chip is drawn bottom-left on the stage; screenshot existence is not pixel acceptance.'
            }
        }
    }
    Capture ('settings-voicelab-'+$Step)
    Assert-Space
    $status='passed'
} catch {$reason=$_.Exception.Message}
finally {
    if($app -and -not $app.HasExited -and $app.Path -eq $exe -and $app.StartTime.ToUniversalTime().Ticks -eq $ownedStart){Stop-Process -Id $app.Id -Force;[void]$app.WaitForExit(10000)}
    if($themeChanged) {
        try {
            Start-Process -FilePath $themeFiles[0].backup;Start-Sleep -Seconds 5
            foreach($file in $themeFiles){if($file.exists){Copy-Item -LiteralPath $file.backup -Destination $file.path -Force;if((Get-FileHash -LiteralPath $file.path -Algorithm SHA256).Hash -ne $file.hash){throw 'Theme file bytes did not restore.'}}elseif(Test-Path -LiteralPath $file.path){[IO.File]::Delete($file.path)}}
            Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes' -Name CurrentTheme -Value $originalTheme
            if([VoiceLabNative]::HighContrast() -ne $originalContrast){throw 'High Contrast did not restore.'}
            if((Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes').CurrentTheme -ne $originalTheme){throw 'The original theme path did not restore.'}
            $themeRestored=$true
        } catch {$status='failed';$reason='THEME RESTORE FAILED: '+$_.Exception.Message;$themeRestored=$false}
    }
    @{status=$status;reason=$reason;step=$Step;architecture=$RuntimeIdentifier;configuration=$Configuration;themeRestored=$themeRestored;tabOrder=@($tabOrder);evidence=$EvidenceDir;visualReview='pending';narrator='not observed'} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding ASCII
}
if($status -ne 'passed'){throw $reason}
