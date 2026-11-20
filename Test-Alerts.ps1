# 验证重复告警抑制、足量新增后重报、恢复再越线及历史恢复；不显示弹窗或连接代理。
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
$now=Get-Date
$first=Get-TrafficAlertDecision $null 501e6 500e6 501e6 $now
if(!$first.notify){throw 'Initial crossing not reported'}
$same=Get-TrafficAlertDecision $first.state 510e6 500e6 510e6 $now.AddMinutes(16)
if($same.notify){throw 'Stale excess repeated'}
$less=Get-TrafficAlertDecision $same.state 900e6 500e6 900e6 $now.AddMinutes(32)
if($less.notify){throw 'Insufficient new bytes repeated'}
$more=Get-TrafficAlertDecision $less.state 1002e6 500e6 1002e6 $now.AddMinutes(48)
if(!$more.notify){throw 'New threshold not reported'}
$reset=Get-TrafficAlertDecision $more.state 400e6 500e6 1002e6 $now.AddMinutes(64)
$cross=Get-TrafficAlertDecision $reset.state 501e6 500e6 1103e6 $now.AddMinutes(80)
if(!$cross.notify){throw 'Recovery/re-crossing not reported'}
$loaded=$cross.state|ConvertTo-Json|ConvertFrom-Json
$persisted=@{above=$loaded.above;lastTotal=$loaded.lastTotal;lastSent=$loaded.lastSent}
if((Get-TrafficAlertDecision $persisted 502e6 500e6 1104e6 $now.AddMinutes(96)).notify){throw 'Restart repeated old alert'}
$records=@([pscustomobject]@{updated=$now.AddMinutes(-50).ToString('o');day='d';codexDayBytes=100},[pscustomobject]@{updated=$now.AddMinutes(-20).ToString('o');day='d';codexDayBytes=900},[pscustomobject]@{updated=$now.AddMinutes(-1).ToString('o');day='d';codexDayBytes=950})
$history=Restore-TrafficWindow $records $now
[double]$sum=0;foreach($bucket in $history){$sum+=$bucket.bytes}
if($sum -ne 850){throw 'History restoration failed'}
Write-Output 'PASS: initial crossing, stale suppression, insufficient/new bytes, recovery, persisted state, window history.'
