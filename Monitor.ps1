<#
独立后台监控：每两秒只读本机 Clash 命名管道，每十秒核对 Codex TCP 端口和增量日志。
输出到 LOCALAPPDATA/CodexTrafficMonitor；源码目录可移动，移动后需重新安装登录启动项。
不调用模型、不访问互联网、不改变代理、不停止其他进程。使用系统 Windows PowerShell 5.1。
#>
param([switch]$TestAlert)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'Settings.ps1')
$cfg=Get-MonitorConfig $PSScriptRoot
$dataRoot=Join-Path $env:LOCALAPPDATA 'CodexTrafficMonitor'
[IO.Directory]::CreateDirectory($dataRoot) > $null
$mutex=New-Object Threading.Mutex($false,('Local\CodexTrafficMonitor-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
if (!$mutex.WaitOne(0)) { $mutex.Dispose(); exit }
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'LocalPipe.cs')
    $script:alertTimes=@{}; $script:alertCount=0
    function Write-Alert([string]$Kind,[string]$Message,[switch]$TrafficDecision) {
        $now=Get-Date
        if (!$TrafficDecision -and $script:alertTimes.ContainsKey($Kind) -and ($now-$script:alertTimes[$Kind]).TotalMinutes -lt $cfg.alertCooldownMinutes) { return }
        $script:alertTimes[$Kind]=$now; $script:alertCount++
        $record=@{time=$now.ToString('o');kind=$Kind;message=$Message}|ConvertTo-Json -Compress
        Add-Content -LiteralPath (Join-Path $dataRoot ('alerts-'+$now.ToString('yyyy-MM-dd')+'.jsonl')) -Value $record -Encoding UTF8
        # 弹窗在单独的系统 PowerShell 中短时显示，不阻塞流量采样；内容不含凭据。
        $escaped=$Message.Replace("'","''")
        $code="`$w=New-Object -ComObject WScript.Shell; [void]`$w.Popup('$escaped',20,'Codex 流量监控',48)"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile','-STA','-WindowStyle','Hidden','-EncodedCommand',$encoded) -WindowStyle Hidden
    }
    $configPath=$cfg.clashConfig
    if (!$configPath) { $configPath=Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml' }
    $logRoot=$cfg.codexLogRoot
    if (!$logRoot) { $logRoot=Join-Path $env:LOCALAPPDATA 'Codex\Logs' }
    if($TestAlert){Write-Alert 'self-test' 'Codex 流量监控自检：本机告警已触发；这是测试，不代表流量异常。';exit}
    $previous=@{}; $ports=@{}; $cursors=@{}; $buckets=New-Object Collections.ArrayList
    $baseline=Get-Date; $started=$baseline; $lastOwners=[datetime]::MinValue; $lastStatus=[datetime]::MinValue
    $lastLog=[datetime]::MinValue; $lastConfig=[datetime]::MinValue; $lastCleanup=[datetime]::MinValue
    $secret=''; $apiUnavailableSince=$null; $script:day=$baseline.ToString('yyyy-MM-dd'); [double]$script:dayBytes=0
    $statusPath=Join-Path $dataRoot 'status.json'
    # 同一天重启保留日累计，未运行的时间不做猜测补算。
    if (Test-Path -LiteralPath $statusPath) {
        try { $old=Get-Content -Raw -LiteralPath $statusPath|ConvertFrom-Json; if($old.day -eq $script:day){$script:dayBytes=[double]$old.codexDayBytes} } catch { }
    }
    $lifetime=$script:dayBytes
    if($old -and $null -ne $old.codexLifetimeBytes){$lifetime=[double]$old.codexLifetimeBytes}
    $history=New-Object Collections.ArrayList
    foreach($date in @($baseline.AddDays(-1),$baseline)){
        $file=Join-Path $dataRoot ('metrics-'+$date.ToString('yyyy-MM-dd')+'.jsonl')
        if(Test-Path -LiteralPath $file){foreach($line in Get-Content -LiteralPath $file){try{[void]$history.Add(($line|ConvertFrom-Json))}catch{}}}
    }
    $buckets=Restore-TrafficWindow $history $baseline
    $trafficStates=@{};$alertStatePath=Join-Path $dataRoot 'traffic-alert-state.json'
    if(Test-Path -LiteralPath $alertStatePath){
        $saved=Get-Content -Raw -LiteralPath $alertStatePath|ConvertFrom-Json
        foreach($property in $saved.PSObject.Properties){$value=$property.Value;$trafficStates[$property.Name]=@{above=[bool]$value.above;lastTotal=[double]$value.lastTotal;lastSent=[string]$value.lastSent}}
    }else{
        # 一次性迁移旧告警：承认已经提醒过的事件，新增量从本次升级时开始计算。
        $legacy=Join-Path $dataRoot ('alerts-'+$script:day+'.jsonl')
        if(Test-Path -LiteralPath $legacy){foreach($line in Get-Content -LiteralPath $legacy){try{$entry=$line|ConvertFrom-Json;if($entry.kind -in @('five-minute','hour','day')){$trafficStates[$entry.kind]=@{above=$true;lastTotal=$lifetime;lastSent=[string]$entry.time}}}catch{}}}
    }
    while (!(Test-Path -LiteralPath (Join-Path $dataRoot 'stop.flag'))) {
        $now=Get-Date; $apiState='ok'; $delta=$null
        if (($now-$lastOwners).TotalSeconds -ge 10) {
            $owners=@{}; Get-Process ChatGPT,codex -ErrorAction SilentlyContinue | ForEach-Object { $owners[[string]$_.Id]=$_.ProcessName }
            $ports=@{}
            foreach ($line in (& "$env:SystemRoot\System32\netstat.exe" -ano -p tcp)) {
                $parts=$line.Trim() -split '\s+'
                if ($parts.Count -eq 5 -and $parts[0] -eq 'TCP' -and $owners.ContainsKey($parts[4])) {
                    $port=($parts[1] -split ':')[-1]; $ports[$port]=$owners[$parts[4]]
                }
            }
            $lastOwners=$now
        }
        try {
            if (($now-$lastConfig).TotalSeconds -ge 60) {
                $yaml=Get-Content -Raw -LiteralPath $configPath
                $secret=[regex]::Match($yaml,'(?m)^secret:\s*([^\r\n]*)').Groups[1].Value.Trim().Trim('"',"'")
                $lastConfig=$now
            }
            $snapshot=[CodexLocalPipe]::Connections($cfg.pipeName,$secret)|ConvertFrom-Json
            $apiUnavailableSince=$null
            $delta=Get-ObservedDelta $snapshot.connections $previous $ports $baseline
            $previous=$delta.next
            if ($script:day -ne $now.ToString('yyyy-MM-dd')) { $script:day=$now.ToString('yyyy-MM-dd');$script:dayBytes=0 }
            $script:dayBytes+=$delta.codex
            $lifetime+=$delta.codex
            [void]$buckets.Add(@{time=$now;bytes=$delta.codex})
            while($buckets.Count -and ($now-$buckets[0].time).TotalSeconds -gt 3600){$buckets.RemoveAt(0)}
            [double]$five=0;[double]$hour=0
            foreach($bucket in $buckets){$hour+=$bucket.bytes;if(($now-$bucket.time).TotalSeconds -le 300){$five+=$bucket.bytes}}
            foreach($item in @(@{kind='five-minute';value=$five;limit=$cfg.fiveMinuteMB;label='最近5分钟'},@{kind='hour';value=$hour;limit=$cfg.hourMB;label='最近1小时'},@{kind='day';value=$script:dayBytes;limit=$cfg.dayMB;label='今天'})){
                $decision=Get-TrafficAlertDecision $trafficStates[$item.kind] $item.value ($item.limit*1e6) $lifetime $now $cfg.alertCooldownMinutes
                $trafficStates[$item.kind]=$decision.state
                if($decision.notify){Write-Alert $item.kind ('Codex '+$item.label+'已观测 VPN 流量约 '+[Math]::Round($item.value/1e6,1)+' MB，阈值 '+$item.limit+' MB。本次为首次越线或上次告警后新增流量再次达到阈值；旧流量持续留在窗口内不会重复提醒。') -TrafficDecision}
            }
        } catch {
            $apiState='unavailable'
            if($null -eq $apiUnavailableSince){$apiUnavailableSince=$now}
            if(($now-$apiUnavailableSince).TotalMinutes -ge 2){Write-Alert 'proxy-unavailable' '无法读取本机 Clash 统计，流量监测暂不可用；日志监测仍继续。请检查 Clash 是否运行。'}
        }
        if (($now-$lastLog).TotalSeconds -ge 10) {
            $todayDir=Join-Path (Join-Path (Join-Path $logRoot $now.ToString('yyyy')) $now.ToString('MM')) $now.ToString('dd')
            foreach($file in @(Get-ChildItem -LiteralPath $todayDir -Filter '*.log' -File -ErrorAction SilentlyContinue)) {
                if(!$cursors.ContainsKey($file.FullName)) { $cursors[$file.FullName]=[long]0 }
                $position=[long]$cursors[$file.FullName];if($file.Length -lt $position){$position=0}
                $stream=$null;$reader=$null
                try {
                    $stream=[IO.File]::Open($file.FullName,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                    [void]$stream.Seek($position,'Begin'); $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8)
                    while($null -ne ($line=$reader.ReadLine())) {
                        if(Test-ActivationFailure $line) {
                            $stamp=$line.Substring(0,[Math]::Min(24,$line.Length));$eventTime=[datetime]::MinValue
                            if([datetime]::TryParse($stamp,[ref]$eventTime) -and $eventTime.ToUniversalTime() -ge $started.ToUniversalTime().AddMinutes(-5)) {
                                Write-Alert 'runtime-activation' '检测到 Codex 运行时下载后激活失败，可能每小时重新下载约500MB。请保存任务并彻底退出，修复更新故障。本监控不会自动退出 Codex。'
                            }
                        }
                    }
                    $cursors[$file.FullName]=$stream.Position
                } finally {if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
            }
            $lastLog=$now
        }
        if (($now-$lastStatus).TotalSeconds -ge 15) {
            $state=@{pid=$PID;script=(Join-Path $PSScriptRoot 'Monitor.ps1');started=$started.ToString('o');updated=$now.ToString('o');day=$script:day;codexDayBytes=$script:dayBytes;codex5MinuteBytes=$five;codexHourBytes=$hour;proxy=$apiState;codexPortCount=$ports.Count;alertsThisRun=$script:alertCount;mode='alert-only';pollSeconds=$cfg.pollSeconds;limitation='Observed active-connection deltas; short closed connections may be missed. No historical billing reconstruction.'}
            $state.thresholds=@{fiveMinuteMB=$cfg.fiveMinuteMB;hourMB=$cfg.hourMB;dayMB=$cfg.dayMB}; $temp=Join-Path $dataRoot 'status.tmp'
            $state.codexLifetimeBytes=$lifetime;$state.trafficAlertMode='crossing-or-new-threshold';$state|ConvertTo-Json|Set-Content -LiteralPath $temp -Encoding UTF8
            Move-Item -LiteralPath $temp -Destination $statusPath -Force
            $alertTemp=Join-Path $dataRoot 'traffic-alert-state.tmp';$trafficStates|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $alertTemp -Encoding UTF8
            Move-Item -LiteralPath $alertTemp -Destination $alertStatePath -Force
            Add-Content -LiteralPath (Join-Path $dataRoot ('metrics-'+$script:day+'.jsonl')) -Value ($state|ConvertTo-Json -Compress) -Encoding UTF8
            $lastStatus=$now
        }
        if(($now-$lastCleanup).TotalHours -ge 1){
            Get-ChildItem -LiteralPath $dataRoot -File | Where-Object { $_.Name -match '^(metrics|alerts)-\d{4}-\d{2}-\d{2}\.jsonl$' -and $_.LastWriteTime -lt $now.AddDays(-[int]$cfg.retentionDays) } | Remove-Item -Force
            $lastCleanup=$now
        }
        Start-Sleep -Seconds ([Math]::Max(1,[int]$cfg.pollSeconds))
    }
} catch {
    @{time=(Get-Date -Format o);type=$_.Exception.GetType().FullName;message=$_.Exception.Message}|ConvertTo-Json -Compress|Add-Content -LiteralPath (Join-Path $dataRoot 'fatal-errors.jsonl') -Encoding UTF8
    throw
} finally { $mutex.ReleaseMutex();$mutex.Dispose() }
