<#
.SYNOPSIS
    ラボ環境の Azure VM を Azure Arc 対応サーバーとして登録するスクリプト
.DESCRIPTION
    Azure VM 上で Azure Arc 対応サーバーを評価するため、以下の手順を自動実行します。
    1. 環境変数 MSFT_ARC_TEST を設定 (Azure VM 上での Arc インストールを許可)
    2. VM 拡張機能を削除
    3. Azure VM ゲスト エージェントを無効化
    4. IMDS エンドポイントへのアクセスをブロック (ファイアウォール ルール)
    5. Azure Connected Machine Agent をインストール
    6. azcmagent connect で Azure Arc に接続

    参考: https://learn.microsoft.com/ja-jp/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine
.PARAMETER ResourceGroupName
    VM が存在するリソースグループ名
.PARAMETER ArcResourceGroupName
    Arc リソースを登録するリソースグループ名 (省略時は ResourceGroupName と同じ)
.PARAMETER Location
    Arc リソースのリージョン (既定: japaneast)
.PARAMETER TenantId
    Azure AD テナント ID (省略時は現在のコンテキストから取得)
.PARAMETER SubscriptionId
    サブスクリプション ID (省略時は現在のコンテキストから取得)
.PARAMETER ServicePrincipalId
    Azure Connected Machine Onboarding ロールを持つサービス プリンシパルのアプリケーション ID
.PARAMETER VmNames
    Arc 対応にする VM 名の配列 (既定: OnPrem-AD, OnPrem-SQL, OnPrem-Web)
.EXAMPLE
    .\Enable-ArcOnVMs.ps1 -ResourceGroupName "rg-onpre"
.EXAMPLE
    .\Enable-ArcOnVMs.ps1 -ResourceGroupName "rg-onpre" -VmNames @("OnPrem-Web")
.EXAMPLE
    .\Enable-ArcOnVMs.ps1 -ResourceGroupName "rg-onpre" -ArcResourceGroupName "rg-arc" -ServicePrincipalId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [string]$ArcResourceGroupName = '',
    [string]$Location = 'japaneast',
    [string]$TenantId = '',
    [string]$SubscriptionId = '',
    [string]$ServicePrincipalId = '',

    [string[]]$VmNames = @('OnPrem-AD', 'OnPrem-SQL', 'OnPrem-Web')
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

function Invoke-VmRunCommand {
    <#
    .SYNOPSIS
        VM 上でスクリプトを実行し、結果を返す
    #>
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$Script,
        [string]$Description = ''
    )

    if ($Description) {
        Write-Host "  [$VmName] $Description" -ForegroundColor Yellow
    }

    $result = az vm run-command invoke `
        --resource-group $ResourceGroup `
        --name $VmName `
        --command-id RunPowerShellScript `
        --scripts $Script `
        -o json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [$VmName] コマンド実行に失敗しました: $result" -ForegroundColor Red
        return $null
    }

    $parsed = $result | ConvertFrom-Json
    $stdout = $parsed.value | Where-Object { $_.code -like '*StdOut*' } | Select-Object -ExpandProperty message
    $stderr = $parsed.value | Where-Object { $_.code -like '*StdErr*' } | Select-Object -ExpandProperty message

    if ($stderr) {
        Write-Host "  [$VmName] StdErr: $stderr" -ForegroundColor Yellow
    }
    if ($stdout) {
        Write-Host "  [$VmName] $stdout" -ForegroundColor Gray
    }

    return $stdout
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

if (-not $TenantId) {
    $TenantId = $account.tenantId
}
if (-not $SubscriptionId) {
    $SubscriptionId = $account.id
}
if (-not $ArcResourceGroupName) {
    $ArcResourceGroupName = $ResourceGroupName
}

Write-Host "  テナント ID       : $TenantId" -ForegroundColor White
Write-Host "  サブスクリプション: $SubscriptionId" -ForegroundColor White
Write-Host "  Arc リソース RG   : $ArcResourceGroupName" -ForegroundColor White
Write-Host "  対象 VM           : $($VmNames -join ', ')" -ForegroundColor White

# ============================================================
# 1. サービス プリンシパルの準備
# ============================================================

Write-Step "1. サービス プリンシパルの準備"

if (-not $ServicePrincipalId) {
    Write-Host "  Arc オンボーディング用サービス プリンシパルを作成します..." -ForegroundColor Yellow

    $spJson = az ad sp create-for-rbac `
        --name "arc-onboarding-lab" `
        --role "Azure Connected Machine Onboarding" `
        --scopes "/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName" `
        -o json 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "サービス プリンシパルの作成に失敗しました: $spJson"
    }

    $sp = $spJson | ConvertFrom-Json
    $ServicePrincipalId = $sp.appId
    $spSecret = $sp.password

    Write-Host "  サービス プリンシパル作成完了" -ForegroundColor Green
    Write-Host "    App ID: $ServicePrincipalId" -ForegroundColor White
}
else {
    Write-Host "  既存のサービス プリンシパルを使用します: $ServicePrincipalId" -ForegroundColor Green
    $spSecretSecure = Read-Host -Prompt "サービス プリンシパルのシークレットを入力してください" -AsSecureString
    $spSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($spSecretSecure)
    )
}

# ============================================================
# 2. 各 VM を Arc 対応に準備
# ============================================================

foreach ($vmName in $VmNames) {
    Write-Step "2. [$vmName] Arc 対応の準備"

    # --- 2a. 環境変数 MSFT_ARC_TEST を設定 ---
    Invoke-VmRunCommand `
        -ResourceGroup $ResourceGroupName `
        -VmName $vmName `
        -Description "環境変数 MSFT_ARC_TEST を設定" `
        -Script '[System.Environment]::SetEnvironmentVariable("MSFT_ARC_TEST","true",[System.EnvironmentVariableTarget]::Machine); Write-Output "MSFT_ARC_TEST=true を設定しました"'

    # --- 2b. VM 拡張機能を削除 ---
    Write-Host "  [$vmName] VM 拡張機能を確認中..." -ForegroundColor Yellow
    $extensions = az vm extension list `
        --resource-group $ResourceGroupName `
        --vm-name $vmName `
        --query "[].name" -o tsv 2>$null

    if ($extensions) {
        foreach ($ext in $extensions -split "`n") {
            $ext = $ext.Trim()
            if ($ext) {
                Write-Host "  [$vmName] 拡張機能 '$ext' を削除中..." -ForegroundColor Yellow
                az vm extension delete `
                    --resource-group $ResourceGroupName `
                    --vm-name $vmName `
                    --name $ext `
                    -o none 2>$null
                Write-Host "  [$vmName] 拡張機能 '$ext' を削除しました。" -ForegroundColor Green
            }
        }
    }
    else {
        Write-Host "  [$vmName] 削除対象の拡張機能はありません。" -ForegroundColor Green
    }

    # --- 2c. Azure VM ゲスト エージェントを無効化 ---
    Invoke-VmRunCommand `
        -ResourceGroup $ResourceGroupName `
        -VmName $vmName `
        -Description "Azure VM ゲスト エージェントを無効化" `
        -Script 'Set-Service WindowsAzureGuestAgent -StartupType Disabled -Verbose; Stop-Service WindowsAzureGuestAgent -Force -Verbose; Write-Output "WindowsAzureGuestAgent を無効化しました"'

    # --- 2d. IMDS エンドポイントをブロック ---
    Invoke-VmRunCommand `
        -ResourceGroup $ResourceGroupName `
        -VmName $vmName `
        -Description "IMDS エンドポイントへのアクセスをブロック" `
        -Script @'
$ruleName = "BlockAzureIMDS"
$existing = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Output "ファイアウォール ルール '$ruleName' は既に存在します。スキップします。"
} else {
    New-NetFirewallRule -Name $ruleName -DisplayName "Block access to Azure IMDS" -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.254
    Write-Output "ファイアウォール ルール '$ruleName' を作成しました。"
}
$ruleName2 = "BlockAzureIMDS_AzureLocal"
$existing2 = Get-NetFirewallRule -Name $ruleName2 -ErrorAction SilentlyContinue
if ($existing2) {
    Write-Output "ファイアウォール ルール '$ruleName2' は既に存在します。スキップします。"
} else {
    New-NetFirewallRule -Name $ruleName2 -DisplayName "Block access to Azure Local IMDS" -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.253
    Write-Output "ファイアウォール ルール '$ruleName2' を作成しました。"
}
'@
}

# ============================================================
# 3. Azure Connected Machine Agent のインストールと接続
# ============================================================

foreach ($vmName in $VmNames) {
    Write-Step "3. [$vmName] Azure Connected Machine Agent のインストールと接続"

    # エージェントのダウンロードとインストール
    Invoke-VmRunCommand `
        -ResourceGroup $ResourceGroupName `
        -VmName $vmName `
        -Description "Azure Connected Machine Agent をダウンロード・インストール" `
        -Script @'
# 既にインストール済みか確認
if (Test-Path "C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe") {
    Write-Output "Azure Connected Machine Agent は既にインストールされています。"
} else {
    Write-Output "Azure Connected Machine Agent をダウンロード中..."
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri "https://aka.ms/AzureConnectedMachineAgent" -OutFile "$env:TEMP\install_windows_azcmagent.msi" -UseBasicParsing
    Write-Output "インストール中..."
    $exitCode = (Start-Process -FilePath msiexec.exe -ArgumentList "/i", "$env:TEMP\install_windows_azcmagent.msi", "/l*v", "$env:TEMP\installationlog.txt", "/qn" -Wait -Passthru).ExitCode
    if ($exitCode -ne 0) {
        throw "Azure Connected Machine Agent のインストールに失敗しました (ExitCode: $exitCode)。ログ: $env:TEMP\installationlog.txt"
    }
    Write-Output "Azure Connected Machine Agent のインストールが完了しました。"
}
'@

    # azcmagent connect で Arc に接続
    # サービス プリンシパルの資格情報を使用
    $connectScript = @"
`$env:MSFT_ARC_TEST = 'true'
& "C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe" connect ``
    --service-principal-id "$ServicePrincipalId" ``
    --service-principal-secret "$spSecret" ``
    --tenant-id "$TenantId" ``
    --subscription-id "$SubscriptionId" ``
    --resource-group "$ArcResourceGroupName" ``
    --location "$Location" ``
    --resource-name "$vmName-Arc"
if (`$LASTEXITCODE -eq 0) {
    Write-Output "Azure Arc への接続に成功しました。"
} else {
    Write-Output "Azure Arc への接続に失敗しました (ExitCode: `$LASTEXITCODE)。"
}
"@

    Invoke-VmRunCommand `
        -ResourceGroup $ResourceGroupName `
        -VmName $vmName `
        -Description "Azure Arc に接続" `
        -Script $connectScript
}

# ============================================================
# 4. 接続結果の確認
# ============================================================

Write-Step "4. Azure Arc 接続状況の確認"

$arcResources = az resource list `
    --resource-group $ArcResourceGroupName `
    --resource-type "Microsoft.HybridCompute/machines" `
    --query "[].{name:name, status:properties.status, location:location}" `
    -o table 2>$null

if ($arcResources) {
    Write-Host $arcResources -ForegroundColor Green
}
else {
    Write-Host "  Arc リソースが見つかりません。接続が完了するまで数分かかる場合があります。" -ForegroundColor Yellow
    Write-Host "  Azure Portal で確認してください: Azure Arc > サーバー" -ForegroundColor Yellow
}

# シークレットをメモリからクリア
$spSecret = $null
[System.GC]::Collect()

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Arc 対応の処理が完了しました" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  確認方法:" -ForegroundColor White
Write-Host "    Azure Portal → Azure Arc → サーバー" -ForegroundColor White
Write-Host "    または: az connectedmachine list -g $ArcResourceGroupName -o table" -ForegroundColor White
Write-Host ""
