<#
读取仓库默认 config.json，并合并可选的 config.local.json。
机器专用路径只放在本地覆盖文件中；不读取或保存代理认证值。
#>
function Get-MonitorConfig([string]$ProjectRoot) {
    # 显式传入项目目录，使移动目录后仍从新位置读取配置。
    $config=Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'config.json') | ConvertFrom-Json
    $localPath=Join-Path $ProjectRoot 'config.local.json'
    if(Test-Path -LiteralPath $localPath){
        $local=Get-Content -Raw -LiteralPath $localPath | ConvertFrom-Json
        foreach($property in $local.PSObject.Properties){
            if($config.PSObject.Properties.Name -notcontains $property.Name){throw ('Unknown configuration key: '+$property.Name)}
            $config.($property.Name)=$property.Value
        }
    }
    return $config
}
