[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$StoragePath = Join-Path $env:APPDATA 'TRAE SOLO CN\User\globalStorage\storage.json'
$DeviceConfigPath = Join-Path $env:APPDATA 'TRAE SOLO CN\ahanet\tt_net_config.config'
$AuthStorageKey = 'iCubeAuthInfo://icube.cloudide'
$StatusUri = 'https://api.trae.cn/trae/api/v2/ug/checkin_credits/status'
$ClaimUri = 'https://api.trae.cn/trae/api/v2/ug/checkin_credits/claim'
$MaximumAttempts = 3
$RetrySeconds = 120

function ConvertFrom-TraeEncryptedValue {
    param([Parameter(Mandatory)][string]$Encoded)

    [byte[]]$allBytes = [Convert]::FromBase64String($Encoded)
    [byte[]]$header = @(116, 99, 5, 16, 0, 0)
    if ($allBytes.Length -lt 54) {
        throw 'TRAE 登录数据格式无效'
    }
    for ($index = 0; $index -lt $header.Length; $index++) {
        if ($allBytes[$index] -ne $header[$index]) {
            throw 'TRAE 登录数据格式已改变'
        }
    }

    [byte[]]$seed = $allBytes[6..37]
    [byte[]]$saltLeft = @(
        82, 9, 106, 213, 48, 54, 165, 56, 191, 64, 163, 158, 129, 243, 215, 251,
        124, 227, 57, 130, 155, 47, 255, 135, 52, 142, 67, 68, 196, 222, 233, 203,
        84, 123, 148, 50, 166, 194, 35, 61, 238, 76, 149, 11, 66, 250, 195, 78,
        8, 46, 161, 102, 40, 217, 36, 178, 118, 91, 162, 73, 109, 139, 209, 37
    )
    [byte[]]$saltRight = @(
        31, 221, 168, 51, 136, 7, 199, 49, 177, 18, 16, 89, 39, 128, 236, 95,
        96, 81, 127, 169, 25, 181, 74, 13, 45, 229, 122, 159, 147, 201, 156, 239,
        160, 224, 59, 77, 174, 42, 245, 176, 200, 235, 187, 60, 131, 83, 153, 97,
        23, 43, 4, 126, 186, 119, 214, 38, 225, 105, 20, 99, 85, 33, 12, 125
    )
    [byte[]]$salt = New-Object byte[] 64
    for ($index = 0; $index -lt $salt.Length; $index++) {
        $salt[$index] = $saltLeft[$index] -bxor $saltRight[$index]
    }

    $sha512 = [Security.Cryptography.SHA512]::Create()
    try {
        [byte[]]$material = New-Object byte[] 128
        [byte[]]$seedHash = $sha512.ComputeHash($seed)
        [Array]::Copy($seedHash, 0, $material, 0, 64)
        [Array]::Copy($salt, 0, $material, 64, 64)
        [byte[]]$derived = $sha512.ComputeHash($material)
        [byte[]]$key = $derived[0..15]
        [byte[]]$iv = $derived[16..31]
        [byte[]]$cipherText = $allBytes[38..($allBytes.Length - 1)]

        $aes = [Security.Cryptography.Aes]::Create()
        try {
            $aes.KeySize = 128
            $aes.Mode = [Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key = $key
            $aes.IV = $iv
            $decryptor = $aes.CreateDecryptor()
            try {
                [byte[]]$plainText = $decryptor.TransformFinalBlock($cipherText, 0, $cipherText.Length)
            }
            finally {
                $decryptor.Dispose()
            }
        }
        finally {
            $aes.Dispose()
        }

        if ($plainText.Length -le 64) {
            throw 'TRAE 登录数据内容无效'
        }
        [byte[]]$body = $plainText[64..($plainText.Length - 1)]
        [byte[]]$expectedHash = $sha512.ComputeHash($body)
        for ($index = 0; $index -lt 64; $index++) {
            if ($plainText[$index] -ne $expectedHash[$index]) {
                throw 'TRAE 登录数据完整性校验失败'
            }
        }
        return [Text.Encoding]::UTF8.GetString($body)
    }
    finally {
        $sha512.Dispose()
    }
}

function Get-TraeCredentials {
    if (-not (Test-Path -LiteralPath $StoragePath)) {
        throw '没有找到 TRAE 本地登录数据'
    }
    $storage = Get-Content -Raw -LiteralPath $StoragePath | ConvertFrom-Json
    $authProperty = $storage.PSObject.Properties[$AuthStorageKey]
    if ($null -eq $authProperty -or [string]::IsNullOrWhiteSpace([string]$authProperty.Value)) {
        throw 'TRAE 尚未登录或登录状态已丢失'
    }
    if (-not (Test-Path -LiteralPath $DeviceConfigPath)) {
        throw '没有找到 TRAE 设备标识'
    }
    $deviceMatch = [regex]::Match(
        [IO.File]::ReadAllText($DeviceConfigPath),
        'device_id&#\*([^@]+)@\$\*'
    )
    if (-not $deviceMatch.Success -or [string]::IsNullOrWhiteSpace($deviceMatch.Groups[1].Value)) {
        throw 'TRAE 设备标识格式无效'
    }

    $authJson = ConvertFrom-TraeEncryptedValue -Encoded ([string]$authProperty.Value)
    $auth = $authJson | ConvertFrom-Json
    if ($auth.account.scope -ne 'marscode' -or [string]::IsNullOrWhiteSpace([string]$auth.token)) {
        throw '当前 TRAE 登录状态不支持签到'
    }
    return [pscustomobject]@{
        Token = [string]$auth.token
        DeviceId = $deviceMatch.Groups[1].Value
    }
}

function Invoke-TraePost {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    foreach ($entry in $Headers.GetEnumerator()) {
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation([string]$entry.Key, [string]$entry.Value)
    }
    $content = New-Object System.Net.Http.StringContent('{}', [Text.Encoding]::UTF8, 'application/json')
    $response = $null
    try {
        try {
            $response = $client.PostAsync($Uri, $content).GetAwaiter().GetResult()
            [byte[]]$responseBytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $responseText = [Text.Encoding]::UTF8.GetString($responseBytes)
            $body = $null
            $parseError = $null
            if (-not [string]::IsNullOrWhiteSpace($responseText)) {
                try {
                    $body = $responseText | ConvertFrom-Json
                }
                catch {
                    $parseError = '服务器返回了无法解析的数据'
                }
            }
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Body = $body
                ParseError = $parseError
                TransportError = $null
            }
        }
        catch {
            return [pscustomobject]@{
                StatusCode = 0
                Body = $null
                ParseError = $null
                TransportError = '网络连接失败或请求超时'
            }
        }
        finally {
            if ($null -ne $response) {
                $response.Dispose()
            }
        }
    }
    finally {
        $content.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-ResponseDisposition {
    param([Parameter(Mandatory)]$Response)

    if ($Response.TransportError) {
        return [pscustomobject]@{ Kind = 'Retry'; Reason = $Response.TransportError }
    }
    if ($Response.StatusCode -eq 401 -or $Response.StatusCode -eq 403) {
        return [pscustomobject]@{ Kind = 'Fail'; Reason = 'TRAE 登录已过期，请重新登录' }
    }
    if ($Response.StatusCode -eq 429 -or $Response.StatusCode -ge 500) {
        return [pscustomobject]@{ Kind = 'Retry'; Reason = ('TRAE 服务暂时不可用（HTTP ' + $Response.StatusCode + '）') }
    }
    if ($Response.StatusCode -ne 200) {
        return [pscustomobject]@{ Kind = 'Fail'; Reason = ('TRAE 请求失败（HTTP ' + $Response.StatusCode + '）') }
    }
    if ($Response.ParseError -or $null -eq $Response.Body) {
        return [pscustomobject]@{ Kind = 'Fail'; Reason = 'TRAE 返回数据格式异常' }
    }
    return [pscustomobject]@{ Kind = 'Ok'; Reason = $null }
}

function Show-WindowsToast {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message
    )

    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $safeTitle = [Security.SecurityElement]::Escape($Title)
    $safeMessage = [Security.SecurityElement]::Escape($Message)
    $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$safeTitle</text><text>$safeMessage</text></binding></visual></toast>")
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('ByteDance.TraeSoloCN').Show($toast)
}

function Get-FriendlyCreditsText {
    param($Credits)

    [decimal]$parsedCredits = 0
    if ($null -ne $Credits -and [decimal]::TryParse([string]$Credits, [ref]$parsedCredits) -and $parsedCredits -gt 0) {
        return '，获得 ' + $parsedCredits + ' Credits'
    }
    return ''
}

try {
    $credentials = Get-TraeCredentials
    $headers = @{
        Authorization = 'Cloud-IDE-JWT ' + $credentials.Token
        'x-device-id' = $credentials.DeviceId
    }
    $lastReason = '未知错误'
    $claimAccepted = $false
    $expectedCredits = $null

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $statusResponse = Invoke-TraePost -Uri $StatusUri -Headers $headers
        $statusDisposition = Get-ResponseDisposition -Response $statusResponse
        if ($statusDisposition.Kind -eq 'Fail') {
            $lastReason = $statusDisposition.Reason
            break
        }
        if ($statusDisposition.Kind -eq 'Retry') {
            $lastReason = $statusDisposition.Reason
        }
        else {
            $status = $statusResponse.Body
            if (($null -eq $status.PSObject.Properties['enable']) -or
                ($null -eq $status.PSObject.Properties['checked_in']) -or
                ($status.enable -isnot [bool]) -or
                ($status.checked_in -isnot [bool])) {
                $lastReason = 'TRAE 签到状态格式异常'
                break
            }
            if (-not $status.enable) {
                $lastReason = 'TRAE 当前未开放签到'
                break
            }
            if ($status.checked_in) {
                if ($claimAccepted) {
                    $creditsText = Get-FriendlyCreditsText -Credits $expectedCredits
                    Show-WindowsToast -Title 'TRAE 签到成功' -Message ('已完成今日签到' + $creditsText)
                    Write-Output ('TRAE 签到成功' + $creditsText)
                }
                else {
                    Show-WindowsToast -Title 'TRAE 今日已签到' -Message '无需重复签到'
                    Write-Output 'TRAE 今日已签到'
                }
                exit 0
            }
            if ($null -ne $status.PSObject.Properties['credits']) {
                $expectedCredits = $status.credits
            }

            $claimResponse = Invoke-TraePost -Uri $ClaimUri -Headers $headers
            $claimDisposition = Get-ResponseDisposition -Response $claimResponse
            if ($claimDisposition.Kind -eq 'Fail') {
                $lastReason = $claimDisposition.Reason
                break
            }
            if ($claimDisposition.Kind -eq 'Retry') {
                $lastReason = $claimDisposition.Reason
            }
            elseif ($claimResponse.Body.PSObject.Properties['code'] -eq $null) {
                $lastReason = 'TRAE 领取结果格式异常'
                break
            }
            elseif ([int]$claimResponse.Body.code -eq 9074) {
                $lastReason = '参与用户较多，TRAE 服务繁忙（9074）'
            }
            elseif ([int]$claimResponse.Body.code -ne 0) {
                $lastReason = 'TRAE 拒绝签到（业务码 ' + [int]$claimResponse.Body.code + '）'
                break
            }
            else {
                $claimAccepted = $true
                $verifyResponse = Invoke-TraePost -Uri $StatusUri -Headers $headers
                $verifyDisposition = Get-ResponseDisposition -Response $verifyResponse
                if ($verifyDisposition.Kind -eq 'Fail') {
                    $lastReason = $verifyDisposition.Reason
                    break
                }
                if ($verifyDisposition.Kind -eq 'Retry') {
                    $lastReason = $verifyDisposition.Reason
                }
                elseif (($null -eq $verifyResponse.Body.PSObject.Properties['checked_in']) -or
                        ($verifyResponse.Body.checked_in -isnot [bool])) {
                    $lastReason = 'TRAE 签到复查格式异常'
                    break
                }
                elseif ($verifyResponse.Body.checked_in) {
                    $creditsText = Get-FriendlyCreditsText -Credits $expectedCredits
                    Show-WindowsToast -Title 'TRAE 签到成功' -Message ('已完成今日签到' + $creditsText)
                    Write-Output ('TRAE 签到成功' + $creditsText)
                    exit 0
                }
                else {
                    $lastReason = 'TRAE 尚未确认签到结果'
                }
            }
        }

        if ($attempt -lt $MaximumAttempts) {
            Start-Sleep -Seconds $RetrySeconds
        }
    }

    Show-WindowsToast -Title 'TRAE 签到失败' -Message $lastReason
    Write-Error $lastReason -ErrorAction Continue
    exit 1
}
catch {
    $reason = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($reason)) {
        $reason = '发生未知错误'
    }
    try {
        Show-WindowsToast -Title 'TRAE 签到失败' -Message $reason
    }
    catch {
        # The non-zero exit code still lets Task Scheduler record the failure.
    }
    Write-Error $reason -ErrorAction Continue
    exit 1
}
