<#
中文说明：流量差分和安装错误识别，不访问 UI、不修改任何外部应用。
输入为代理连接快照；输出为本次可观测新增字节。首次看到已经存在的连接只记基线。
连接在两个采样间完成或最后一段传输未被采样，会漏计；因此不能作为 VPN 账单。
#>
function Get-ObservedDelta($Connections, $Previous, $PortOwners, [datetime]$Baseline) {
    $next = @{}; [double]$codex=0; [double]$related=0; [double]$vpn=0
    foreach ($c in $Connections) {
        $id=[string]$c.id; [double]$total=[double]$c.upload+[double]$c.download
        $next[$id]=$total; [double]$delta=0
        if ($Previous.ContainsKey($id)) { $delta=[Math]::Max(0,$total-[double]$Previous[$id]) }
        elseif ([datetimeoffset]::Parse($c.start).UtcDateTime -ge $Baseline.ToUniversalTime()) { $delta=$total }
        $chain=@($c.chains)
        if (!$chain.Count -or @($chain | Where-Object { $_ -match '^(DIRECT|REJECT|REJECT-DROP)$' }).Count) { continue }
        $vpn+=$delta
        $owner=$PortOwners[[string]$c.metadata.sourcePort]
        $processName=[IO.Path]::GetFileName([string]$c.metadata.process)
        if ($owner -or $processName -match '^(ChatGPT|codex)(\.exe)?$') { $codex+=$delta }
        elseif ([string]$c.metadata.host -match '(^|\.)(chatgpt\.com|openai\.com|oaistatic\.com|oaiusercontent\.com)$') { $related+=$delta }
    }
    return @{next=$next; codex=$codex; related=$related; vpn=$vpn}
}
function Test-ActivationFailure([string]$Line) {
    return ($Line -match 'primary_runtime_bundle_install_outcome' -and $Line -match 'outcome=failed' -and $Line -match 'failureStage=activate_runtime')
}

# 持续超标本身不重报；只有重新越线或上次通知后又新增一个阈值的流量才候选通知。
# 返回状态须持久保存，避免监控重启后把旧超标当作新事件。
function Get-TrafficAlertDecision($State,[double]$Current,[double]$Threshold,[double]$Total,[datetime]$Now,[int]$CooldownMinutes=15) {
    if($Threshold -le 0){throw 'Threshold must be positive'}
    if($null -eq $State){$State=@{above=$false;lastTotal=$Total;lastSent=[datetime]::MinValue.ToString('o')}}
    if($Current -lt $Threshold*0.9){$State.above=$false}
    $candidate=($Current -ge $Threshold -and (!$State.above -or ($Total-[double]$State.lastTotal) -ge $Threshold))
    $notify=($candidate -and ($Now-[datetime]$State.lastSent).TotalMinutes -ge $CooldownMinutes)
    if($notify){$State.above=$true;$State.lastTotal=$Total;$State.lastSent=$Now.ToString('o')}
    return @{notify=$notify;state=$State}
}

# 从已有15秒汇总恢复最近一小时观测值，不清空历史来消除弹窗。
# 跨日累计归零时使用新日增量；采样边界仍可能有一个汇总间隔的误差。
function Restore-TrafficWindow($Records,[datetime]$Now) {
    $out=New-Object Collections.ArrayList;$previous=$null
    foreach($record in @($Records|Sort-Object {[datetime]$_.updated})){
        $time=[datetime]$record.updated
        if($previous){
            [double]$amount=[double]$record.codexDayBytes-[double]$previous.codexDayBytes
            if($record.day -ne $previous.day){$amount=[double]$record.codexDayBytes}
            if($time -ge $Now.AddHours(-1) -and $time -le $Now -and $amount -gt 0){[void]$out.Add(@{time=$time;bytes=$amount})}
        }
        $previous=$record
    }
    return ,$out
}
