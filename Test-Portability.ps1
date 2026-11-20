<#
迁移自检：把发布文件复制到临时中文含空格目录，验证配置覆盖、脚本语法、核心测试和安装任务参数。
仅模拟计划任务接口，不安装启动项、不启动监控、不访问网络；临时副本保留以便检查。
#>
$ErrorActionPreference='Stop'
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$copy=Join-Path $tempRoot ('Codex 迁移验证 '+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($copy)>$null
$files=@('Core.ps1','LocalPipe.cs','Manage.ps1','Monitor.ps1','Settings.ps1','Watchdog.vbs','config.json','README.md','Test-Alerts.ps1')
foreach($name in $files){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $copy}
foreach($file in Get-ChildItem -LiteralPath $copy -Filter '*.ps1'){
    $tokens=$null;$parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw ($parseErrors|Out-String)}
}
. (Join-Path $copy 'Settings.ps1')
$defaults=Get-MonitorConfig $copy
if($defaults.hourMB -ne 500 -or $defaults.clashConfig -ne ''){throw 'Default configuration mismatch'}
$overridePath=Join-Path $copy 'config.local.json'
@{hourMB=600;codexLogRoot=(Join-Path $copy '本机日志')}|ConvertTo-Json|Set-Content -LiteralPath $overridePath -Encoding UTF8
$overrides=Get-MonitorConfig $copy
if($overrides.hourMB -ne 600 -or $overrides.codexLogRoot -ne (Join-Path $copy '本机日志') -or $overrides.pipeName -ne $defaults.pipeName){throw 'Local override failed'}
& (Join-Path $copy 'Manage.ps1') -Action SelfTest
& (Join-Path $copy 'Test-Alerts.ps1')
Add-Type -Path (Join-Path $copy 'LocalPipe.cs')
# 仅执行提取的安装任务函数，使用替身检查新电脑所需的创建参数。
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $copy 'Manage.ps1'),[ref]$tokens,[ref]$parseErrors)
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-RecoveryTask'},$true)
if(!$definition){throw 'Recovery installer missing'}
& {
    param($Definition,$CopyRoot)
    $script:calls=@{}
    function New-ScheduledTaskAction {param($Execute,$Argument) $script:calls.action=@{execute=$Execute;arguments=$Argument};return 'action'}
    function New-ScheduledTaskTrigger {param([switch]$Once,$At,$RepetitionInterval) $script:calls.interval=$RepetitionInterval;return 'trigger'}
    function New-ScheduledTaskSettingsSet {param($MultipleInstances,$ExecutionTimeLimit,[switch]$StartWhenAvailable,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries) $script:calls.settings=@{multiple=$MultipleInstances;limit=$ExecutionTimeLimit};return 'settings'}
    function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel) $script:calls.principal=@{user=$UserId;logon=$LogonType;level=$RunLevel};return 'principal'}
    function Register-ScheduledTask {param($TaskName,$Action,$Trigger,$Settings,$Principal,[switch]$Force) $script:calls.registered=$TaskName}
    . ([scriptblock]::Create($Definition.Extent.Text))
    Install-RecoveryTask $CopyRoot
    if($script:calls.registered -ne 'CodexTrafficMonitor-Recovery' -or $script:calls.interval.TotalMinutes -ne 1){throw 'Recovery registration failed'}
    if($script:calls.action.execute -notlike '*\wscript.exe' -or !$script:calls.action.arguments.Contains((Join-Path $CopyRoot 'Watchdog.vbs'))){throw 'Recovery path did not migrate'}
    if($script:calls.settings.limit -ne [TimeSpan]::Zero -or $script:calls.settings.multiple -ne 'IgnoreNew' -or $script:calls.principal.level -ne 'Limited'){throw 'Recovery settings mismatch'}
} $definition $copy
Write-Output ('PASS: relocated scripts, local overrides, parsing, core tests, C# compilation and recovery task parameters. Temporary copy: '+$copy)
