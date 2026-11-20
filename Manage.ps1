<#
管理当前用户的监控：Install 设置登录启动并启动；Stop 用停止标记退出；Uninstall 移除启动项。
仅管理本工具，绝不按名称批量结束 PowerShell/Codex。迁移文件夹后重新 Install。
#>
param([ValidateSet('Install','Start','Stop','Status','Uninstall','TestAlert','SelfTest','EnsureRunning')][string]$Action='Status')
$ErrorActionPreference='Stop'
$dataRoot=Join-Path $env:LOCALAPPDATA 'CodexTrafficMonitor'
[IO.Directory]::CreateDirectory($dataRoot)>$null
$systemPS=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shortcutPath=Join-Path ([Environment]::GetFolderPath('Startup')) 'CodexTrafficMonitor.lnk'
$stopPath=Join-Path $dataRoot 'stop.flag'
$recoveryTask='CodexTrafficMonitor-Recovery'
function Install-RecoveryTask([string]$ProjectRoot) {
    # 新电脑创建当前用户任务；目录迁移时完整更新任务，使用 wscript 避免控制台闪烁。
    $taskAction=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\wscript.exe') -Argument ('//B //Nologo "'+(Join-Path $ProjectRoot 'Watchdog.vbs')+'"')
    $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName 'CodexTrafficMonitor-Recovery' -Action $taskAction -Trigger $trigger -Settings $settings -Principal $principal -Force > $null
}
function Start-Monitor {
    if(Test-Path -LiteralPath $stopPath){Remove-Item -LiteralPath $stopPath}
    $watchdog=Join-Path $PSScriptRoot 'Watchdog.vbs'
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('//B //Nologo "'+$watchdog+'" start') -WindowStyle Hidden
}
switch($Action){
    'EnsureRunning' {
        # 仅恢复本监控；显式停止标记优先，不自动重新开启用户已停止的监控。
        if(Test-Path -LiteralPath $stopPath){exit}
        $live=$false; $status=Join-Path $dataRoot 'status.json'
        if(Test-Path -LiteralPath $status){
            try{$s=Get-Content -Raw -LiteralPath $status|ConvertFrom-Json;$p=Get-Process -Id $s.pid -ErrorAction SilentlyContinue;$live=($null -ne $p -and $p.ProcessName -eq 'powershell' -and $p.StartTime -le [datetime]$s.started -and $p.StartTime -ge ([datetime]$s.started).AddSeconds(-30))}catch{$live=$false}
        }
        if(!$live){Start-Monitor}
    }
    'Install' {
        $shell=New-Object -ComObject WScript.Shell
        $shortcut=$shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath=Join-Path $env:SystemRoot 'System32\wscript.exe'
        $shortcut.Arguments='//B //Nologo "'+(Join-Path $PSScriptRoot 'Watchdog.vbs')+'" start'
        $shortcut.WorkingDirectory=$PSScriptRoot;$shortcut.WindowStyle=7;$shortcut.Description='Codex 本机流量与运行时失败告警（仅提醒）';$shortcut.Save()
        Install-RecoveryTask $PSScriptRoot
        Start-Monitor
        Write-Output 'Installed current-user login startup and launched monitor.'
    }
    'Start' {Start-Monitor;Write-Output 'Start requested; duplicate instances exit automatically.'}
    'Stop' {Set-Content -LiteralPath $stopPath -Value 'stop';Write-Output 'Stop requested. Usually exits within 10 seconds. Login startup remains enabled.'}
    'Uninstall' {
        Set-Content -LiteralPath $stopPath -Value 'stop'
        if(Test-Path -LiteralPath $shortcutPath){Remove-Item -LiteralPath $shortcutPath}
        if(Get-ScheduledTask -TaskName $recoveryTask -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $recoveryTask -Confirm:$false}
        Write-Output 'Login startup removed; stop requested. Local records preserved.'
    }
    'Status' {
        $status=Join-Path $dataRoot 'status.json'
        if(Test-Path -LiteralPath $status){Get-Content -Raw -LiteralPath $status}else{Write-Output 'No status yet.'}
        Write-Output ('LoginStartup='+[string](Test-Path -LiteralPath $shortcutPath))
        Write-Output ('StopRequested='+[string](Test-Path -LiteralPath $stopPath))
    }
    'TestAlert' {
        # 测试弹窗不需要停止正在运行的实例，也不更改其计数。
        $code="`$w=New-Object -ComObject WScript.Shell; [void]`$w.Popup('Codex 流量监控自检：弹窗通道正常，此消息不是异常告警。',15,'Codex 流量监控',48)"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        Start-Process $systemPS -ArgumentList @('-NoProfile','-STA','-WindowStyle','Hidden','-EncodedCommand',$encoded) -WindowStyle Hidden
        @{time=(Get-Date -Format o);kind='self-test-request';message='Popup launch requested'}|ConvertTo-Json -Compress|Add-Content -LiteralPath (Join-Path $dataRoot 'self-test.jsonl') -Encoding UTF8
        Write-Output 'Local notification test launched (no external traffic).'
    }
    'SelfTest' {
        . (Join-Path $PSScriptRoot 'Core.ps1')
        $base=(Get-Date).AddMinutes(-1)
        $c=[pscustomobject]@{id='a';upload=100;download=200;start=$base.AddSeconds(1).ToString('o');chains=@('proxy');metadata=[pscustomobject]@{sourcePort='123';process='';host='chatgpt.com'}}
        $r=Get-ObservedDelta @($c) @{} @{'123'='codex'} $base
        if($r.codex -ne 300){throw 'New connection accounting failed'}
        $c.download=300;$s=Get-ObservedDelta @($c) $r.next @{'123'='codex'} $base
        if($s.codex -ne 100){throw 'Incremental accounting failed'}
        $c.download=0;$c.upload=0;$s=Get-ObservedDelta @($c) $r.next @{'123'='codex'} $base
        if($s.codex -ne 0){throw 'Counter reset failed'}
        $c.upload=100;$c.chains=@('DIRECT');$s=Get-ObservedDelta @($c) @{} @{'123'='codex'} $base
        if($s.vpn -ne 0){throw 'DIRECT filtering failed'}
        $c.chains=@('proxy');$c.start=$base.AddSeconds(-1).ToString('o');$s=Get-ObservedDelta @($c) @{} @{'123'='codex'} $base
        if($s.codex -ne 0){throw 'Existing connection baseline failed'}
        if(!(Test-ActivationFailure 'primary_runtime_bundle_install_outcome outcome=failed failureStage=activate_runtime')){throw 'Activation failure detection failed'}
        if(Test-ActivationFailure 'primary_runtime_bundle_install_outcome outcome=installed'){throw 'Success misclassified'}
        Write-Output 'PASS: 7 accounting and log-detection cases.'
    }
}
