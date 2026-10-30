param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][string]$AcceptedDataRoot,
    [Parameter(Mandatory=$true)][string]$EvidenceDir, [string]$NormalProject,
    [ValidateSet('win-arm64','win-x64')][string]$RuntimeIdentifier='win-arm64',
    [ValidateSet('Debug','Release')][string]$Configuration='Debug',
    [ValidateSet('pane','cancel','turn-on','cap','label','light','dark','night-sky','release-off','release-on','release-smoke','session','account-cancel','delete-cancel','zero-http','consent-gate','consent','consent-cap','consent-error','training','training-cap','creation-cancel','creation-ready','creation-savefail','creation-uncertain','creation-expired')][string]$Step='pane',
    [ValidatePattern('^[^"\r\n]*$')][string]$ConsentScenario='tone;rate=44100;channels=2', [ValidateRange(1,35)][int]$StopSeconds=12,
    [ValidateRange(1,95)][int]$TrainingSeconds=65,
    [ValidateSet('ready','verification','save-failure','uncertain','expired','speaker-mismatch','speaker-unavailable')][string]$CreationScenario='ready',
    [ValidateSet('Night sky','High Contrast Black','High Contrast White')][string]$ContrastTheme='Night sky',
    [switch]$SessionFixtures, [switch]$Schedule)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $EvidenceDir | Out-Null
$EvidenceDir=(Resolve-Path -LiteralPath $EvidenceDir).Path
$resultPath=Join-Path $EvidenceDir 'result.json'
if (Test-Path -LiteralPath $resultPath) { throw 'Use a fresh evidence directory for every step and every idle-gate retry.' }
if ($Schedule) {
    $task='VoxClipVoiceLab-' + [Guid]::NewGuid().ToString('N')
    $projectArgument=if($NormalProject){' -NormalProject "'+$NormalProject+'"'}else{''}
    $arguments='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Root "'+$Root+'" -AcceptedDataRoot "'+$AcceptedDataRoot+'" -EvidenceDir "'+$EvidenceDir+'" -RuntimeIdentifier '+$RuntimeIdentifier+' -Configuration '+$Configuration+' -Step '+$Step+$projectArgument
    if($SessionFixtures){$arguments+=' -SessionFixtures'}
    $arguments+=' -ConsentScenario "'+$ConsentScenario+'" -StopSeconds '+$StopSeconds
    $arguments+=' -TrainingSeconds '+$TrainingSeconds+' -CreationScenario '+$CreationScenario
    $arguments+=' -ContrastTheme "'+$ContrastTheme+'"'
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
function Find-Id([string]$id,[switch]$Optional) {
    $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty,$id)
    for($attempt=0;$attempt -lt 60;$attempt++) {
        $element=[System.Windows.Automation.AutomationElement]::FromHandle($script:window).FindFirst([System.Windows.Automation.TreeScope]::Descendants,$condition)
        if($element){return $element}
        if($Optional){return $null}
        Start-Sleep -Milliseconds 200
    }
    throw "Missing Voice Lab AutomationId: $id"
}
function Assert-NoStatement {
    if(Get-ChildItem -LiteralPath $data -Recurse -Filter 'statement.wav'){throw 'Abandon left statement audio behind.'}
    $temporary=Join-Path $data 'Cache\voice-consent'
    if((Test-Path -LiteralPath $temporary) -and (Get-ChildItem -LiteralPath $temporary -Force)){throw 'Verify left temporary audio behind.'}
}
function Consent-Step {
    if($Step -ne 'consent-gate') {
        if($Configuration -ne 'Debug'){throw 'Consent fixtures require DEBUG; refusing provider access.'}
        Invoke-Control 'Check ElevenLabs account';Invoke-Control 'Continue'
    }
    Invoke-Control ('Create Your Voice'+[char]0x2026)
    [void](Find-Control 'Back to Voice Lab')
    $record=Find-Id 'voice-record-statement'
    $teleprompter=Find-Id 'voice-consent-teleprompter'
    if($teleprompter.Current.Name -ne 'Read this aloud'){throw 'Teleprompter has no accessible name.'}
    [void](Find-Id 'voice-consent-headphones')
    if($Step -eq 'consent-gate') {
        if($record.Current.IsEnabled){throw 'A8-closed Record is enabled.'}
        if(-not (Find-Id 'voice-create-gate').Current.Name.Contains('The speaker check is not ready on Windows yet. Creating a voice is unavailable.')){throw 'A8 gate reason missing.'}
        Assert-NoStatement
        Capture 'consent-gated'
        return
    }
    (Find-Id 'voice-display-name').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('Example')
    foreach($id in @('voice-attest-own','voice-attest-adult','voice-attest-videos')) {
        (Find-Id $id).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    }
    $teleprompter.SetFocus()
    foreach($id in @('voice-consent-teleprompter','voice-consent-headphones','voice-record-statement')) {
        $focused=[System.Windows.Automation.AutomationElement]::FocusedElement
        if($focused.Current.ProcessId -ne $app.Id -or $focused.Current.AutomationId -ne $id){throw ('Consent Tab order skipped '+$id)}
        $tabOrder.Add($focused.Current.Name)
        [VoiceLabNative]::Key(0x09);Start-Sleep -Milliseconds 150
    }
    $expected=$null
    if($Step -eq 'consent-error') {
        switch -Regex ($ConsentScenario) {
            '^denied' {$expected='Microphone access is off. Turn on Microphone access and Let desktop apps access your microphone in Settings '+[char]0x2192+' Privacy & security '+[char]0x2192+' Microphone to record your consent.';break}
            '^nodevice' {$expected='No microphone found. Connect one and try again.';break}
            '^inuse' {$expected="The microphone isn't available. Check your input device and try again.";break}
            '^(lost@|stall@)' {$expected='The microphone stopped sending audio. This take was discarded. Check your input device and record again.';break}
            '^silentflags' {$expected="The microphone sent only silence. Check that it isn't muted, and that Settings "+[char]0x2192+' Privacy & security '+[char]0x2192+' Microphone lets desktop apps use it.';break}
            default {throw 'U6 requires denied, nodevice, inuse, lost@3, stall@2 or silentflags.'}
        }
    }
    Invoke-Control 'Record statement'
    $deadline=[DateTime]::UtcNow.AddSeconds(75)
    $finished=$false
    while([DateTime]::UtcNow -lt $deadline) {
        if($expected -and (Find-Control $expected -Optional)){$finished=$true;break}
        $verify=Find-Id 'voice-verify-statement' -Optional
        if($verify -and $verify.Current.IsEnabled){$finished=$true;break}
        $seconds=Find-Id 'voice-microphone-seconds' -Optional
        if($seconds -and $seconds.Current.Name -match '^([0-9]+\.[0-9]+) seconds$' -and [double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture) -ge $StopSeconds) {
            Invoke-Control 'Stop recording';$finished=$true;break
        }
        Start-Sleep -Milliseconds 50
    }
    if(-not $finished){throw 'Consent capture did not complete before the probe deadline.'}
    if($expected) {
        [void](Find-Control $expected)
        Assert-NoStatement
        if($ConsentScenario -match '^(denied|silentflags)') {
            Invoke-Control 'Open Settings'
            $uri=Join-Path $data 'Cache\microphone-settings-uri.txt'
            for($attempt=0;$attempt -lt 30;$attempt++) {
                if((Test-Path -LiteralPath $uri) -and (Get-Content -LiteralPath $uri -Raw) -eq 'ms-settings:privacy-microphone'){break}
                Start-Sleep -Milliseconds 100
            }
            if(-not (Test-Path -LiteralPath $uri) -or (Get-Content -LiteralPath $uri -Raw) -ne 'ms-settings:privacy-microphone'){throw 'DEBUG did not intercept the privacy deep link.'}
        }
        Capture 'consent-error'
        return
    }
    if($StopSeconds -lt 5) {
        [void](Find-Control ('Record the statement clearly, in one take lasting 5'+[char]0x2013+'30 seconds.'))
        Assert-NoStatement
        return
    }
    for($attempt=0;$attempt -lt 60;$attempt++) {if((Find-Id 'voice-verify-statement').Current.IsEnabled){break};Start-Sleep -Milliseconds 200}
    if(-not (Find-Id 'voice-verify-statement').Current.IsEnabled){throw 'Verify was not enabled after a valid take.'}
    $statements=@(Get-ChildItem -LiteralPath $data -Recurse -Filter 'statement.wav')
    if($statements.Count -ne 1){throw 'Expected one private statement.'}
    $bytes=[IO.File]::ReadAllBytes($statements[0].FullName)
    $rate=[BitConverter]::ToInt32($bytes,24);$frames=([BitConverter]::ToInt32($bytes,40)/2)
    if($rate -ne 48000 -or $frames -lt (5*48000) -or $frames -gt (30*48000)){throw 'Statement rate or duration is outside the contract.'}
    Invoke-Control ('Verify statement '+[char]0xB7+' < $0.01')
    [void](Find-Id 'voice-verify-confirmation')
    [VoiceLabNative]::Key(0x0D)
    [void](Find-Control 'Statement verified. Record your training read-aloud next.')
    $scribe=Get-Content -LiteralPath (Join-Path $data 'Cache\consent-scribe-result.json') -Raw | ConvertFrom-Json
    if($scribe.fixture -ne 'consent-scribe.json' -or $scribe.calls -ne 1 -or $scribe.httpCalls -ne 0){throw 'Fake Scribe zero-HTTP evidence missing.'}
    Capture 'consent-verified'
    if($Step -match '^(training|creation)') {Training-Creation-Step;return}
    Invoke-Control 'Back to Voice Lab';[void](Find-Control 'Keep going');[VoiceLabNative]::Key(0x0D)
    [void](Find-Id 'voice-consent-teleprompter')
    Invoke-Control 'Back to Voice Lab';[void](Find-Control 'Keep going');[VoiceLabNative]::Key(0x1B)
    [void](Find-Id 'voice-consent-teleprompter')
    Invoke-Control 'Back to Voice Lab';Invoke-Control 'Stop'
    [void](Find-Control 'Show Voice Lab (beta)')
    Assert-NoStatement
}
function Training-Creation-Step {
    Invoke-Control 'Record training read-aloud'
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $deadline=[DateTime]::UtcNow.AddSeconds(115)
    $stopped=$false
    while([DateTime]::UtcNow -lt $deadline) {
        if(Find-Control 'Training recording is ready.' -Optional){break}
        if($TrainingSeconds -lt 60 -and (Find-Control ('Record 5'+[char]0x2013+'30 seconds for consent, or 60'+[char]0x2013+'90 seconds for the training read-aloud, with clear speech.') -Optional)){break}
        $seconds=Find-Id 'voice-microphone-seconds' -Optional
        if($TrainingSeconds -lt 90 -and -not $stopped -and $seconds -and $seconds.Current.Name -match '^([0-9]+\.[0-9]+) seconds$' -and [double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture) -ge $TrainingSeconds) {
            Invoke-Control 'Stop recording';$stopped=$true
        }
        Start-Sleep -Milliseconds 100
    }
    if($TrainingSeconds -lt 60) {
        if((Find-Id 'voice-create-submit').Current.IsEnabled){throw 'Short training enabled Create.'}
        [void](Find-Control ('Record 5'+[char]0x2013+'30 seconds for consent, or 60'+[char]0x2013+'90 seconds for the training read-aloud, with clear speech.'))
        return
    }
    [void](Find-Control 'Training recording is ready.')
    $training=Get-Content -LiteralPath (Join-Path $data 'Cache\training-result.json') -Raw | ConvertFrom-Json
    if($training.seconds -lt 60 -or $training.seconds -gt 90 -or $training.maximumSeconds -ne 90 -or $training.httpCalls -ne 0){throw 'Training duration or zero-HTTP invariant failed.'}
    if($TrainingSeconds -ge 90) {
        while($timer.Elapsed.TotalSeconds -lt $TrainingSeconds){Start-Sleep -Milliseconds 100}
        if($stopped -or [Math]::Abs($training.seconds-90) -gt .05){throw 'The 95-second attempt did not stop automatically at 90 seconds.'}
    }
    if([System.Windows.Automation.AutomationElement]::FocusedElement.Current.AutomationId -ne 'voice-create-submit'){throw 'Training did not focus Create voice.'}
    Capture 'training-ready'
    if($Step -match '^training'){return}
    Invoke-Control ('Create voice'+[char]0x2026)
    [void](Find-Id 'voice-create-confirmation')
    if($Step -eq 'creation-cancel') {
        [VoiceLabNative]::Key(0x1B)
        $receipt=Get-Content -LiteralPath (Join-Path $data 'Cache\creation-result.json') -Raw | ConvertFrom-Json
        if($receipt.createCalls -ne 0 -or $receipt.planChecks -ne 0 -or $receipt.httpCalls -ne 0){throw 'Cancel sent a request.'}
        return
    }
    [VoiceLabNative]::Key(0x0D)
    if($Step -eq 'creation-expired') {
        [void](Find-Control ('This request expired. Choose Create voice'+[char]0x2026+' again. Nothing was sent.'))
    } elseif($Step -eq 'creation-savefail') {
        [void](Find-Id 'voice-create-retry-save')
        (Find-Id 'voice-create-retry-save').GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        [void](Find-Control 'Consent record saved. No create request was repeated.')
    } elseif($Step -eq 'creation-uncertain') {
        [void](Find-Control 'Voice creation may have completed. Reconcile the pending voice in Settings. Do not create it again.')
    } elseif($CreationScenario -eq 'verification') {
        [void](Find-Control 'ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back.')
    } else {[void](Find-Control 'Your voice is ready.')}
    $receipt=Get-Content -LiteralPath (Join-Path $data 'Cache\creation-result.json') -Raw | ConvertFrom-Json
    $expected=if($Step -eq 'creation-expired'){0}else{1}
    if($receipt.createCalls -ne $expected -or $receipt.planChecks -ne $expected -or $receipt.httpCalls -ne 0){throw 'Creation count, refresh count or zero-HTTP invariant failed.'}
    if($expected -eq 1) {
        $card=Find-Id ('voice-card-'+$receipt.recordId)
        if([System.Windows.Automation.AutomationElement]::FocusedElement.Current.AutomationId -ne $card.Current.AutomationId){throw 'Creation did not focus its saved or recovery card.'}
        if($Step -eq 'creation-uncertain') {
            $buttons=$card.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
            foreach($button in $buttons){if($button.Current.AutomationId -like 'retry-voice-*'){$button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke();break}}
            Start-Sleep -Milliseconds 500
            $again=Get-Content -LiteralPath (Join-Path $data 'Cache\creation-result.json') -Raw | ConvertFrom-Json
            if($again.createCalls -ne 1 -or $again.httpCalls -ne 0){throw 'Recovery repeated creation.'}
        }
    }
    Capture $Step
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
    $start.EnvironmentVariables.Remove('VOXCLIP_DEBUG_VOICELAB')
    $start.EnvironmentVariables.Remove('VOXCLIP_DEBUG_MIC')
    if($Step -eq 'consent-gate' -and $SessionFixtures){throw 'U3 must use the production speaker gate, not the DEBUG available fake.'}
    if($SessionFixtures -or $Step -in @('session','account-cancel','delete-cancel','zero-http','consent','consent-cap','consent-error')){
        if($Configuration -ne 'Debug'){throw 'Session fixtures require a DEBUG build; refusing real provider access.'}
        $start.EnvironmentVariables['VOXCLIP_DEBUG_VOICELAB']='fixtures:'+(Join-Path $root 'shared\fixtures\voice-lab')
    }
    if($Step -match '^(training|creation)') {
        if($Configuration -ne 'Debug'){throw 'R5 probes require DEBUG fixtures.'}
        $fixtures=Join-Path $EvidenceDir 'fixtures'
        Copy-Item -LiteralPath (Join-Path $root 'shared\fixtures\voice-lab') -Destination $fixtures -Recurse
        @{scenario=$CreationScenario}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $fixtures 'creation-scenario.json') -Encoding ASCII
        $start.EnvironmentVariables['VOXCLIP_DEBUG_VOICELAB']='fixtures:'+$fixtures
        $start.EnvironmentVariables['VOXCLIP_DEBUG_MIC']=$ConsentScenario
    }
    if($Step -in @('consent','consent-cap','consent-error')){$start.EnvironmentVariables['VOXCLIP_DEBUG_MIC']=$ConsentScenario}
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
        if($display -eq $ContrastTheme){$theme=$file.FullName;break}
    }
    if(-not $theme){throw ('The '+$ContrastTheme+' system theme was not found; do not substitute another contrast theme.')}
    $script:themeChanged=$true;$script:themeRestored=$false
    Start-Process -FilePath $theme
    Start-Sleep -Seconds 5
    if(-not [VoiceLabNative]::HighContrast()){throw ($ContrastTheme+' did not enable High Contrast.')}
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
    $settings=@{schema='voxclip-settings/1';'onboarding.completed'=$true;'update.autoCheck'=$false;'general.appearance'=$appearance;'voiceLab.enabled'=(-not $off);'voiceLab.betaNoticeAccepted'=(-not $off);'voiceLab.monthlyCapUsd.elevenlabs'='20'}
    $settings | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding ASCII
    if($Step -eq 'night-sky'){Set-NightSky}
    if($Step -eq 'zero-http'){
        Start-App ('--voice-lab-probe "'+$EvidenceDir+'"')
        $probePath=Join-Path $EvidenceDir 'voice-lab-native-result.json'
        for($attempt=0;$attempt -lt 120;$attempt++){
            if(Test-Path -LiteralPath $probePath){break}
            Start-Sleep -Milliseconds 250
        }
        if(-not (Test-Path -LiteralPath $probePath)){throw 'Voice Lab probe produced no report.'}
        $probe=Get-Content -LiteralPath $probePath -Raw | ConvertFrom-Json
        if($probe.status -ne 'passed' -or $probe.httpCalls -ne 0){throw 'The seeded zero-HTTP probe failed.'}
        $status='passed'
        return
    }
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
            {$_ -in @('consent-gate','consent','consent-cap','consent-error') -or $_ -match '^(training|creation)'} {Consent-Step}
            'session' {
                [void](Find-Control 'Check ElevenLabs account')
                [void](Find-Control ('Own-voice check '+[char]0xB7+' on this PC'))
                [void](Find-Control 'My voices')
                [void](Find-Control 'Example (VoxClip), created 29 October 2026')
                [void](Find-Control ('Created 29 October 2026 '+[char]0xB7+' fixtureOwnVoice'))
                [void](Find-Control 'Awaiting verification, created 29 October 2026')
                [void](Find-Control 'ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back.')
                [void](Find-Control ('Removing'+[char]0x2026))
                [void](Find-Control 'Recovery needs the ElevenLabs key that started this voice.')
                [void](Find-Control ('Checking paused '+[char]0x2014+' review the unfinished voice in your ElevenLabs account.'))
                $create=Find-Control ('Create Your Voice'+[char]0x2026)
                if(-not $create.Current.IsEnabled){throw 'Create Your Voice page is unreachable.'}
                $download=Find-Control 'Download own-voice check model'
                if($download.Current.IsEnabled){throw 'A8-closed download is enabled.'}
                $reason='The speaker check is not ready on Windows yet. Creating a voice is unavailable.'
                if($create.Current.HelpText -ne $reason -or $download.Current.HelpText -ne $reason){throw 'The disabled reason is missing.'}
                $tree=[System.Windows.Automation.AutomationElement]::FromHandle($window).FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
                @($tree | ForEach-Object {@{name=$_.Current.Name;id=$_.Current.AutomationId;help=$_.Current.HelpText;enabled=$_.Current.IsEnabled}}) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceDir 'voice-lab-uia.json') -Encoding UTF8
            }
            'account-cancel' {
                Invoke-Control 'Check ElevenLabs account'
                [void](Find-Control 'Continue');[void](Find-Control 'Cancel')
                [VoiceLabNative]::Key(0x0D);Start-Sleep -Milliseconds 400
                if(Find-Control 'Continue' -Optional){throw 'Account confirmation did not default to Cancel.'}
                Invoke-Control 'Check ElevenLabs account';[VoiceLabNative]::Key(0x1B);Start-Sleep -Milliseconds 400
                if(Find-Control 'Continue' -Optional){throw 'Esc did not cancel account confirmation.'}
                if((Read-Settings).'voiceLab.providerConsent.elevenlabs' -eq $true){throw 'Cancel persisted provider consent.'}
            }
            'delete-cancel' {
                Invoke-Control 'Delete voice Example (VoxClip), created 29 October 2026'
                [void](Find-Control 'Delete voice');[void](Find-Control 'Cancel')
                [VoiceLabNative]::Key(0x0D);Start-Sleep -Milliseconds 400
                if(Find-Control 'Cancel' -Optional){throw 'Delete confirmation did not default to Cancel.'}
                Invoke-Control 'Delete voice Example (VoxClip), created 29 October 2026';[VoiceLabNative]::Key(0x1B);Start-Sleep -Milliseconds 400
                if(Find-Control 'Cancel' -Optional){throw 'Esc did not cancel deletion.'}
                [void](Find-Control 'Example (VoxClip), created 29 October 2026')
                Invoke-Control 'Remove from VoxClip only Example (VoxClip), created 29 October 2026'
                [void](Find-Control 'Cancel');[VoiceLabNative]::Key(0x0D);Start-Sleep -Milliseconds 400
                [void](Find-Control 'Example (VoxClip), created 29 October 2026')
                Invoke-Control 'Remove from VoxClip only Example (VoxClip), created 29 October 2026';[VoiceLabNative]::Key(0x1B);Start-Sleep -Milliseconds 400
                if(Find-Control 'Cancel' -Optional){throw 'Esc did not cancel local removal.'}
            }
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
    if($SessionFixtures -or $Step -eq 'session'){
        $scrollCondition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::IsScrollPatternAvailableProperty,$true)
        $scrollables=[System.Windows.Automation.AutomationElement]::FromHandle($window).FindAll([System.Windows.Automation.TreeScope]::Descendants,$scrollCondition)
        $scroller=$null
        foreach($candidate in $scrollables){
            $pattern=$candidate.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
            if($pattern.Current.VerticallyScrollable){$scroller=$pattern;break}
        }
        if(-not $scroller){throw 'The seeded Settings rows have no reachable vertical scroll pattern.'}
        foreach($percent in @(0,50,100)){
            $scroller.SetScrollPercent(-1,$percent);Start-Sleep -Milliseconds 400
            Capture ('settings-voicelab-'+$Step+'-scroll-'+$percent)
        }
        $scroller.SetScrollPercent(-1,0)
    }
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
