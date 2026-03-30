# ============================================================
# Setup-SqlServer.ps1
# Setup script to run on DB01 (SQL Server)
# - Enable SQL Server authentication
# - Enable TCP/IP protocol
# - Open firewall port 1433
# - Create login for Parts Unlimited
# ============================================================
# Usage: Connect to DB01 via Bastion RDP and run in admin PowerShell
#   .\Setup-SqlServer.ps1 -SqlPassword 'P@ssw0rd1234'
# ============================================================

param(
    [Parameter(Mandatory)]
    [string]$SqlPassword,

    [string]$SqlUser = 'puadmin',
    [string]$SqlInstance = 'MSSQLSERVER'
)

$ErrorActionPreference = 'Stop'

Write-Host '=== SQL Server Setup Started ===' -ForegroundColor Cyan

# ----------------------------------------------------------
# 1. Change SQL Server authentication mode to mixed mode
# ----------------------------------------------------------
Write-Host '[1/5] Changing SQL Server authentication to mixed mode...' -ForegroundColor Yellow

$regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.${SqlInstance}\MSSQLServer"
Set-ItemProperty -Path $regPath -Name 'LoginMode' -Value 2
Write-Host '  Set to mixed mode (Windows + SQL).' -ForegroundColor Green

# ----------------------------------------------------------
# 2. Enable TCP/IP protocol
# ----------------------------------------------------------
Write-Host '[2/5] Enabling TCP/IP protocol...' -ForegroundColor Yellow

# Enable TCP/IP via registry (SMO WMI assembly may not be available)
$tcpRegPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.${SqlInstance}\MSSQLServer\SuperSocketNetLib\Tcp"
$tcpEnabled = (Get-ItemProperty -Path $tcpRegPath -Name 'Enabled').Enabled
if ($tcpEnabled -ne 1) {
    Set-ItemProperty -Path $tcpRegPath -Name 'Enabled' -Value 1
    Write-Host '  TCP/IP enabled.' -ForegroundColor Green
} else {
    Write-Host '  TCP/IP is already enabled.' -ForegroundColor Green
}

# ----------------------------------------------------------
# 3. Open firewall port 1433
# ----------------------------------------------------------
Write-Host '[3/5] Opening firewall port 1433...' -ForegroundColor Yellow

$existingRule = Get-NetFirewallRule -DisplayName 'SQL Server (TCP 1433)' -ErrorAction SilentlyContinue
if (-not $existingRule) {
    New-NetFirewallRule -DisplayName 'SQL Server (TCP 1433)' `
        -Direction Inbound -Protocol TCP -LocalPort 1433 `
        -Action Allow -Profile Domain, Private | Out-Null
    Write-Host '  Firewall rule created.' -ForegroundColor Green
} else {
    Write-Host '  Firewall rule already exists.' -ForegroundColor Green
}

# ----------------------------------------------------------
# 4. Restart SQL Server to apply changes
# ----------------------------------------------------------
Write-Host '[4/5] Restarting SQL Server service...' -ForegroundColor Yellow
Restart-Service -Name $SqlInstance -Force
Start-Sleep -Seconds 5
Write-Host '  SQL Server restarted.' -ForegroundColor Green

# ----------------------------------------------------------
# 5. Create SQL login for Parts Unlimited
# ----------------------------------------------------------
Write-Host "[5/5] Creating SQL login '${SqlUser}'..." -ForegroundColor Yellow

$createLoginSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$SqlUser')
BEGIN
    CREATE LOGIN [$SqlUser] WITH PASSWORD = '$SqlPassword', CHECK_POLICY = OFF;
END

-- Grant server-level role (dbcreator: required for EF Code First auto DB creation)
ALTER SERVER ROLE [dbcreator] ADD MEMBER [$SqlUser];
"@

Invoke-Sqlcmd -Query $createLoginSql -ServerInstance '.'
Write-Host "  SQL login '${SqlUser}' created (dbcreator role granted)." -ForegroundColor Green

Write-Host ''
Write-Host '=== SQL Server Setup Complete ===' -ForegroundColor Cyan
Write-Host "接続文字列: Server=10.0.1.5;Database=PartsUnlimitedWebsite;User Id=${SqlUser};Password=<password>;TrustServerCertificate=True" -ForegroundColor White
