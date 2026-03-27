# ============================================================
# Setup-SqlServer.ps1
# DB01 (SQL Server) に対して実行するセットアップスクリプト
# - SQL Server 認証の有効化
# - TCP/IP プロトコルの有効化
# - ファイアウォール ポート 1433 の開放
# - Parts Unlimited 用ログインの作成
# ============================================================
# 使い方: Bastion 経由で DB01 に RDP 接続し、管理者 PowerShell で実行
#   .\Setup-SqlServer.ps1 -SqlPassword 'P@ssw0rd1234'
# ============================================================

param(
    [Parameter(Mandatory)]
    [string]$SqlPassword,

    [string]$SqlUser = 'puadmin',
    [string]$SqlInstance = 'MSSQLSERVER'
)

$ErrorActionPreference = 'Stop'

Write-Host '=== SQL Server セットアップ開始 ===' -ForegroundColor Cyan

# ----------------------------------------------------------
# 1. SQL Server 認証モードを混合モードに変更
# ----------------------------------------------------------
Write-Host '[1/5] SQL Server 認証モードを混合モードに変更...' -ForegroundColor Yellow

$regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.${SqlInstance}\MSSQLServer"
Set-ItemProperty -Path $regPath -Name 'LoginMode' -Value 2
Write-Host '  混合モード (Windows + SQL) に設定しました。' -ForegroundColor Green

# ----------------------------------------------------------
# 2. TCP/IP プロトコルを有効化
# ----------------------------------------------------------
Write-Host '[2/5] TCP/IP プロトコルを有効化...' -ForegroundColor Yellow

Import-Module SqlServer -ErrorAction SilentlyContinue

# WMI で TCP/IP を有効化
$wmi = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer
$tcpProtocol = $wmi.ServerInstances[$SqlInstance].ServerProtocols['Tcp']
if (-not $tcpProtocol.IsEnabled) {
    $tcpProtocol.IsEnabled = $true
    $tcpProtocol.Alter()
    Write-Host '  TCP/IP を有効化しました。' -ForegroundColor Green
} else {
    Write-Host '  TCP/IP は既に有効です。' -ForegroundColor Green
}

# ----------------------------------------------------------
# 3. ファイアウォール ポート 1433 を開放
# ----------------------------------------------------------
Write-Host '[3/5] ファイアウォール ポート 1433 を開放...' -ForegroundColor Yellow

$existingRule = Get-NetFirewallRule -DisplayName 'SQL Server (TCP 1433)' -ErrorAction SilentlyContinue
if (-not $existingRule) {
    New-NetFirewallRule -DisplayName 'SQL Server (TCP 1433)' `
        -Direction Inbound -Protocol TCP -LocalPort 1433 `
        -Action Allow -Profile Domain, Private | Out-Null
    Write-Host '  ファイアウォール ルールを作成しました。' -ForegroundColor Green
} else {
    Write-Host '  ファイアウォール ルールは既に存在します。' -ForegroundColor Green
}

# ----------------------------------------------------------
# 4. SQL Server を再起動して変更を反映
# ----------------------------------------------------------
Write-Host '[4/5] SQL Server サービスを再起動...' -ForegroundColor Yellow
Restart-Service -Name $SqlInstance -Force
Start-Sleep -Seconds 5
Write-Host '  SQL Server を再起動しました。' -ForegroundColor Green

# ----------------------------------------------------------
# 5. Parts Unlimited 用 SQL ログインを作成
# ----------------------------------------------------------
Write-Host "[5/5] SQL ログイン '${SqlUser}' を作成..." -ForegroundColor Yellow

$createLoginSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$SqlUser')
BEGIN
    CREATE LOGIN [$SqlUser] WITH PASSWORD = '$SqlPassword', CHECK_POLICY = OFF;
END

-- サーバーレベルのロールを付与 (dbcreator: EF Code First で DB 自動作成に必要)
ALTER SERVER ROLE [dbcreator] ADD MEMBER [$SqlUser];
"@

Invoke-Sqlcmd -Query $createLoginSql -ServerInstance '.' -TrustServerCertificate
Write-Host "  SQL ログイン '${SqlUser}' を作成しました (dbcreator ロール付与)。" -ForegroundColor Green

Write-Host ''
Write-Host '=== SQL Server セットアップ完了 ===' -ForegroundColor Cyan
Write-Host "接続文字列: Server=10.0.1.5;Database=PartsUnlimitedWebsite;User Id=${SqlUser};Password=<password>;TrustServerCertificate=True" -ForegroundColor White
