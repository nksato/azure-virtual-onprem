<#
.SYNOPSIS
    疑似オンプレミス環境をデプロイするスクリプト
.DESCRIPTION
    Bicep テンプレートを段階的にデプロイし、AD 再起動待機・ドメイン参加の
    リトライ処理を行います。
    使用テンプレートを -TemplateFile パラメータで切り替えられます。
.PARAMETER ResourceGroupName
    デプロイ先のリソースグループ名
.PARAMETER Location
    リソースのリージョン (既定: japaneast)
.PARAMETER TemplateFile
    使用する Bicep テンプレート (既定: infra/main.bicep)
    - infra/main.bicep        : 既定の送信 IP あり (アラート表示)
    - infra/main-closed.bicep : 閉域構成 (送信ブロック)
    - infra/main-nat.bicep    : NAT Gateway 付き (送信可能)
.PARAMETER AdminUsername
    VM の管理者ユーザー名 (既定: labadmin)
.PARAMETER DomainName
    Active Directory ドメイン名 (既定: lab.local)
.PARAMETER RemoteGatewayIp
    Azure 側 VPN Gateway のパブリック IP (省略時は S2S 接続をスキップ)
.PARAMETER RemoteAddressPrefix
    Azure 側のアドレス空間 (既定: 10.100.0.0/16)
.PARAMETER SkipDomainJoin
    ドメイン参加をスキップする場合に指定
.EXAMPLE
    .\Deploy-Lab.ps1 -ResourceGroupName "rg-onpre" -Location "japaneast"
.EXAMPLE
    .\Deploy-Lab.ps1 -ResourceGroupName "rg-onpre" -TemplateFile "infra/main-closed.bicep"
.EXAMPLE
    .\Deploy-Lab.ps1 -ResourceGroupName "rg-onpre" -TemplateFile "infra/main-nat.bicep"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [string]$Location = 'japaneast',
    [ValidateSet('infra/main.bicep', 'infra/main-closed.bicep', 'infra/main-nat.bicep')]
    [string]$TemplateFile = 'infra/main.bicep',
    [string]$AdminUsername = 'labadmin',
    [string]$DomainName = 'lab.local',
    [string]$RemoteGatewayIp = '',
    [string]$RemoteAddressPrefix = '10.100.0.0/16',
    [switch]$SkipDomainJoin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# ヘルパー関数
# ============================================================

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Wait-VmReady {
    <#
    .SYNOPSIS
        VM が起動しエージェントが Ready になるまで待機する
    #>
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [int]$TimeoutMinutes = 15,
        [int]$IntervalSeconds = 30
    )

    Write-Host "  VM '$VmName' の起動を待機中..." -ForegroundColor Yellow
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    while ((Get-Date) -lt $deadline) {
        $status = az vm get-instance-view `
            --resource-group $ResourceGroup `
            --name $VmName `
            --query "instanceView.statuses[?code=='PowerState/running'].displayStatus" `
            -o tsv 2>$null

        if ($status -eq 'VM running') {
            # エージェントの Ready 状態も確認
            $agentStatus = az vm get-instance-view `
                --resource-group $ResourceGroup `
                --name $VmName `
                --query "instanceView.vmAgent.statuses[0].displayStatus" `
                -o tsv 2>$null

            if ($agentStatus -eq 'Ready') {
                Write-Host "  VM '$VmName' は Ready です。" -ForegroundColor Green
                return
            }
        }
        Write-Host "  待機中... (状態: $status / Agent: $agentStatus)" -ForegroundColor Gray
        Start-Sleep -Seconds $IntervalSeconds
    }

    throw "タイムアウト: VM '$VmName' が $TimeoutMinutes 分以内に Ready になりませんでした。"
}

function Install-VmExtension {
    <#
    .SYNOPSIS
        VM 拡張機能をインストールし、リトライ処理を行う
    #>
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$ExtensionName,
        [string]$Publisher,
        [string]$ExtensionType,
        [string]$TypeHandlerVersion,
        [string]$Settings = '',
        [string]$ProtectedSettings = '',
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 60
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        Write-Host "  拡張機能 '$ExtensionName' を '$VmName' にインストール中... (試行 $attempt/$MaxRetries)" -ForegroundColor Yellow

        $azArgs = @(
            'vm', 'extension', 'set'
            '--resource-group', $ResourceGroup
            '--vm-name', $VmName
            '--name', $ExtensionType
            '--publisher', $Publisher
            '--version', $TypeHandlerVersion
            '--extension-instance-name', $ExtensionName
        )
        if ($Settings) {
            $azArgs += '--settings'
            $azArgs += $Settings
        }
        if ($ProtectedSettings) {
            $azArgs += '--protected-settings'
            $azArgs += $ProtectedSettings
        }

        $result = az @azArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  拡張機能 '$ExtensionName' のインストールに成功しました。" -ForegroundColor Green
            return
        }

        Write-Host "  拡張機能 '$ExtensionName' のインストールに失敗しました。" -ForegroundColor Red
        Write-Host "  エラー: $result" -ForegroundColor Red

        if ($attempt -lt $MaxRetries) {
            Write-Host "  ${RetryDelaySeconds}秒後にリトライします..." -ForegroundColor Yellow
            Start-Sleep -Seconds $RetryDelaySeconds
            # リトライ前に VM の Ready 状態を確認
            Wait-VmReady -ResourceGroup $ResourceGroup -VmName $VmName
        }
    }

    throw "拡張機能 '$ExtensionName' のインストールが $MaxRetries 回失敗しました。"
}

# ============================================================
# 0. 事前準備
# ============================================================

Write-Step "0. 事前チェック"

# Azure CLI ログイン確認
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) {
    throw "Azure CLI にログインしてください: az login"
}
Write-Host "  サブスクリプション: $($account.name) ($($account.id))" -ForegroundColor Green

# パスワード入力
$adminPasswordSecure = Read-Host -Prompt "管理者パスワードを入力してください" -AsSecureString
$adminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($adminPasswordSecure)
)

$vpnSharedKeySecure = Read-Host -Prompt "VPN 共有キーを入力してください" -AsSecureString
$vpnSharedKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($vpnSharedKeySecure)
)

# リソースグループ作成
Write-Host "  リソースグループ '$ResourceGroupName' を作成中..."
az group create --name $ResourceGroupName --location $Location -o none

# ============================================================
# 1. インフラ + VM デプロイ (Bicep)
# ============================================================

Write-Step "1. Bicep テンプレートをデプロイ (インフラ + VM)"

$templatePath = Join-Path $PSScriptRoot $TemplateFile
if (-not (Test-Path $templatePath)) {
    throw "テンプレートファイルが見つかりません: $templatePath"
}
Write-Host "  テンプレート: $TemplateFile" -ForegroundColor White

$deployResult = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $templatePath `
    --parameters `
        adminUsername=$AdminUsername `
        adminPassword=$adminPassword `
        domainName=$DomainName `
        vpnSharedKey=$vpnSharedKey `
        remoteGatewayIp=$RemoteGatewayIp `
        remoteAddressPrefix=$RemoteAddressPrefix `
    --query "properties.provisioningState" `
    -o tsv 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "  Bicep デプロイ結果:" -ForegroundColor Red
    Write-Host $deployResult -ForegroundColor Red

    # ドメイン参加の失敗は想定内 — AD 再起動後にリトライ
    $isDomainJoinFailure = $deployResult | Select-String -Pattern 'DomainJoin|JsonADDomainExtension' -Quiet
    if (-not $isDomainJoinFailure) {
        throw "Bicep デプロイに失敗しました。"
    }
    Write-Host "  ドメイン参加の拡張機能でエラーが発生しました（AD 再起動中のため想定内）。" -ForegroundColor Yellow
    Write-Host "  後続のステップでリトライします。" -ForegroundColor Yellow
}
else {
    Write-Host "  Bicep デプロイ: $deployResult" -ForegroundColor Green
}

# ============================================================
# 2. AD サーバの再起動完了を待機
# ============================================================

Write-Step "2. AD サーバ (OnPrem-AD) の再起動完了を待機"

Write-Host "  AD フォレスト構築後の再起動を待っています (最大 10 分)..." -ForegroundColor Yellow
Start-Sleep -Seconds 90  # shutdown /r /t 60 + 起動時間の余裕

Wait-VmReady -ResourceGroup $ResourceGroupName -VmName 'OnPrem-AD' -TimeoutMinutes 10

# AD DS サービスの起動を追加で待機
Write-Host "  AD DS サービスの初期化を待機中 (120秒)..." -ForegroundColor Yellow
Start-Sleep -Seconds 120

# ============================================================
# 3. ドメイン参加 (SQL / Web)
# ============================================================

if (-not $SkipDomainJoin) {
    Write-Step "3. SQL / Web サーバのドメイン参加"

    $domainJoinSettings = @{
        Name    = $DomainName
        User    = "$DomainName\$AdminUsername"
        Restart = 'true'
        Options = '3'
    } | ConvertTo-Json -Compress

    $domainJoinProtected = @{
        Password = $adminPassword
    } | ConvertTo-Json -Compress

    # 既存の失敗した拡張機能を削除してからリトライ
    foreach ($vmName in @('OnPrem-SQL', 'OnPrem-Web')) {
        Write-Host "  $vmName の既存 DomainJoin 拡張機能を確認中..."
        $existingExt = az vm extension show `
            --resource-group $ResourceGroupName `
            --vm-name $vmName `
            --name 'DomainJoin' `
            --query "provisioningState" `
            -o tsv 2>$null

        if ($existingExt -and $existingExt -ne 'Succeeded') {
            Write-Host "  $vmName の失敗した DomainJoin 拡張機能を削除中..." -ForegroundColor Yellow
            az vm extension delete `
                --resource-group $ResourceGroupName `
                --vm-name $vmName `
                --name 'DomainJoin' `
                -o none 2>$null
            Start-Sleep -Seconds 10
        }
        elseif ($existingExt -eq 'Succeeded') {
            Write-Host "  $vmName は既にドメインに参加しています。スキップします。" -ForegroundColor Green
            continue
        }

        Wait-VmReady -ResourceGroup $ResourceGroupName -VmName $vmName

        Install-VmExtension `
            -ResourceGroup $ResourceGroupName `
            -VmName $vmName `
            -ExtensionName 'DomainJoin' `
            -Publisher 'Microsoft.Compute' `
            -ExtensionType 'JsonADDomainExtension' `
            -TypeHandlerVersion '1.3' `
            -Settings $domainJoinSettings `
            -ProtectedSettings $domainJoinProtected `
            -MaxRetries 3 `
            -RetryDelaySeconds 90
    }

    # ドメイン参加後の再起動待機
    Write-Host ""
    Write-Host "  ドメイン参加後の再起動を待機中 (60秒)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 60

    foreach ($vmName in @('OnPrem-SQL', 'OnPrem-Web')) {
        Wait-VmReady -ResourceGroup $ResourceGroupName -VmName $vmName -TimeoutMinutes 10
    }
}
else {
    Write-Step "3. ドメイン参加をスキップ (-SkipDomainJoin)"
}

# ============================================================
# 4. デプロイ結果の表示
# ============================================================

Write-Step "4. デプロイ完了 — 環境情報"

$vpnGwPip = az network public-ip show `
    --resource-group $ResourceGroupName `
    --name 'OnPrem-VpnGw-PIP' `
    --query "ipAddress" -o tsv 2>$null

Write-Host ""
Write-Host "  リソースグループ : $ResourceGroupName" -ForegroundColor White
Write-Host "  リージョン       : $Location" -ForegroundColor White
Write-Host "  ドメイン名       : $DomainName" -ForegroundColor White
Write-Host "  管理者ユーザー   : $AdminUsername" -ForegroundColor White
Write-Host ""
Write-Host "  [サーバ]" -ForegroundColor White
Write-Host "    DC01  (OnPrem-AD)  : 10.0.1.4" -ForegroundColor White
Write-Host "    DB01  (OnPrem-SQL) : 10.0.1.5" -ForegroundColor White
Write-Host "    APP01 (OnPrem-Web) : 10.0.1.6" -ForegroundColor White
Write-Host ""
Write-Host "  [ネットワーク]" -ForegroundColor White
Write-Host "    VPN Gateway PIP    : $vpnGwPip" -ForegroundColor White
Write-Host "    Bastion            : OnPrem-Bastion (Azure Portal からアクセス)" -ForegroundColor White
Write-Host ""
Write-Host "  接続方法: Azure Portal → OnPrem-Bastion → 各 VM に RDP" -ForegroundColor Green
Write-Host ""

# パスワードをメモリからクリア
$adminPassword = $null
$vpnSharedKey = $null
[System.GC]::Collect()

Write-Host "デプロイが完了しました。" -ForegroundColor Green
