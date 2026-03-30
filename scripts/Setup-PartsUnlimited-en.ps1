# ============================================================
# Setup-PartsUnlimited-en.ps1
# Setup script to run on APP01 (IIS/Web)
# Builds and deploys Parts Unlimited (ASP.NET 4.8 MVC)
# ============================================================
# Prerequisites:
#   - Deployed with main-nat.bicep (internet outbound required for GitHub access)
#   - Setup-SqlServer-en.ps1 already executed on DB01
# Usage: Connect to APP01 via Bastion RDP and run in admin PowerShell
#   .\Setup-PartsUnlimited-en.ps1 -SqlPassword 'P@ssw0rd1234'
# ============================================================

param(
    [Parameter(Mandatory)]
    [string]$SqlPassword,

    [string]$SqlUser = 'puadmin',
    [string]$SqlServer = '10.0.1.5',
    [string]$SiteName = 'PartsUnlimited',
    [int]$SitePort = 80,
    [string]$WorkDir = 'C:\PartsUnlimited'
)

$ErrorActionPreference = 'Stop'

Write-Host '=== Parts Unlimited Setup Started ===' -ForegroundColor Cyan

# ----------------------------------------------------------
# 1. Create working directory
# ----------------------------------------------------------
Write-Host '[1/7] Preparing working directory...' -ForegroundColor Yellow
if (Test-Path $WorkDir) {
    Write-Host "  $WorkDir already exists. Removing existing files..." -ForegroundColor Yellow
    Remove-Item -Path $WorkDir -Recurse -Force
}
New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
Write-Host "  Created $WorkDir." -ForegroundColor Green

# ----------------------------------------------------------
# 2. Install Visual Studio Build Tools 2022
#    (Web build tools workload)
# ----------------------------------------------------------
Write-Host '[2/7] Checking Visual Studio Build Tools installation...' -ForegroundColor Yellow

$msbuildPath = ''
$vsWherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"

if (Test-Path $vsWherePath) {
    $msbuildPath = & $vsWherePath -latest -requires Microsoft.Component.MSBuild `
        -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
}

if (-not $msbuildPath) {
    Write-Host '  Downloading and installing Build Tools (approx. 10-15 min)...' -ForegroundColor Yellow
    $installerPath = "$WorkDir\vs_buildtools.exe"

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile $installerPath -UseBasicParsing

    $installArgs = @(
        '--quiet', '--wait', '--norestart',
        '--add', 'Microsoft.VisualStudio.Workload.WebBuildTools',
        '--includeRecommended'
    )
    $process = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) {
        throw "Build Tools installation failed (ExitCode: $($process.ExitCode))"
    }

    # Search for MSBuild path again via vswhere (retry up to 30 sec)
    for ($i = 0; $i -lt 6; $i++) {
        if (Test-Path $vsWherePath) {
            $msbuildPath = & $vsWherePath -latest -requires Microsoft.Component.MSBuild `
                -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
        }
        if ($msbuildPath) { break }
        Write-Host '  Waiting for Build Tools registration...' -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }

    # Fallback: search known installation paths directly
    if (-not $msbuildPath) {
        $fallbackPaths = @(
            "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
            "$env:ProgramFiles\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
        )
        $msbuildPath = $fallbackPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    if (-not $msbuildPath) {
        throw 'MSBuild not found. Please verify Build Tools installation.'
    }
    Write-Host '  Build Tools installed.' -ForegroundColor Green
} else {
    Write-Host "  Build Tools already installed: $msbuildPath" -ForegroundColor Green
}

# ----------------------------------------------------------
# 3. Download NuGet.exe
# ----------------------------------------------------------
Write-Host '[3/7] Downloading NuGet.exe...' -ForegroundColor Yellow
$nugetPath = "$WorkDir\nuget.exe"
if (-not (Test-Path $nugetPath)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile $nugetPath -UseBasicParsing
    Write-Host '  NuGet.exe downloaded.' -ForegroundColor Green
} else {
    Write-Host '  NuGet.exe already exists.' -ForegroundColor Green
}

# ----------------------------------------------------------
# 4. Download and extract source code
# ----------------------------------------------------------
Write-Host '[4/7] Downloading Parts Unlimited source code...' -ForegroundColor Yellow
$zipPath = "$WorkDir\source.zip"
$repoUrl = 'https://github.com/microsoft/PartsUnlimitedE2E/archive/refs/heads/master.zip'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $repoUrl -OutFile $zipPath -UseBasicParsing

Write-Host '  Extracting ZIP...' -ForegroundColor Yellow
Expand-Archive -Path $zipPath -DestinationPath $WorkDir -Force

$srcRoot = Join-Path $WorkDir 'PartsUnlimitedE2E-master\PartsUnlimited-aspnet45'
if (-not (Test-Path $srcRoot)) {
    throw "Source directory not found: $srcRoot"
}
Write-Host "  Source code extracted: $srcRoot" -ForegroundColor Green

# Retarget .csproj from .NET 4.5.1 to .NET 4.8
# Windows Server 2022 ships with .NET 4.8 but does not have 4.5.1 Targeting Pack.
# The app is fully compatible with .NET 4.8 (backward compatible).
$csprojPath = Join-Path $srcRoot 'src\PartsUnlimitedWebsite\PartsUnlimitedWebsite.csproj'
$csprojContent = Get-Content $csprojPath -Raw
if ($csprojContent -match 'v4\.5\.1') {
    $csprojContent = $csprojContent -replace '<TargetFrameworkVersion>v4\.5\.1</TargetFrameworkVersion>', '<TargetFrameworkVersion>v4.8</TargetFrameworkVersion>'
    Set-Content -Path $csprojPath -Value $csprojContent -Encoding UTF8
    Write-Host '  Retargeted project from .NET 4.5.1 to .NET 4.8.' -ForegroundColor Yellow
}

# ----------------------------------------------------------
# 5. NuGet package restore & build
# ----------------------------------------------------------
Write-Host '[5/7] NuGet package restore & build...' -ForegroundColor Yellow

$publishDir = "$WorkDir\publish"
$webProjectPath = Join-Path $srcRoot 'src\PartsUnlimitedWebsite\PartsUnlimitedWebsite.csproj'

# NuGet restore (website project only to avoid modelproj evaluation errors)
Write-Host '  Restoring NuGet packages...' -ForegroundColor Yellow
& $nugetPath restore $webProjectPath -SolutionDirectory $srcRoot
if ($LASTEXITCODE -ne 0) { throw 'NuGet restore failed.' }

# MSBuild — build only the website project (skip tests and modeling projects)
Write-Host '  Building...' -ForegroundColor Yellow
& $msbuildPath $webProjectPath `
    /p:Configuration=Release `
    /p:DeployOnBuild=true `
    /p:publishUrl=$publishDir `
    /p:WebPublishMethod=FileSystem `
    /verbosity:quiet
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
Write-Host '  Build successful.' -ForegroundColor Green

# Build output fallback: check _PublishedWebsites directory
if (-not (Test-Path "$publishDir\Web.config")) {
    $pubWebsites = Get-ChildItem -Path $srcRoot -Recurse -Directory -Filter '_PublishedWebsites' |
        Select-Object -First 1
    if ($pubWebsites) {
        $pubSite = Join-Path $pubWebsites.FullName 'PartsUnlimitedWebsite'
        if (Test-Path "$pubSite\Web.config") {
            $publishDir = $pubSite
            Write-Host "  Publish directory (fallback): $publishDir" -ForegroundColor Yellow
        }
    }
}

# Fallback: PackageTmp directory (created by DeployOnBuild without PublishProfile)
if (-not (Test-Path "$publishDir\Web.config")) {
    $packageTmp = Join-Path $srcRoot 'src\PartsUnlimitedWebsite\obj\Release\Package\PackageTmp'
    if (Test-Path "$packageTmp\Web.config") {
        $publishDir = $packageTmp
        Write-Host "  Publish directory (PackageTmp): $publishDir" -ForegroundColor Yellow
    }
}

# Further fallback: look for Web.config directly under project directory
if (-not (Test-Path "$publishDir\Web.config")) {
    $webProject = Join-Path $srcRoot 'src\PartsUnlimitedWebsite'
    if (Test-Path "$webProject\Web.config") {
        $publishDir = $webProject
        Write-Host "  Publish directory (project direct): $publishDir" -ForegroundColor Yellow
    }
}

if (-not (Test-Path "$publishDir\Web.config")) {
    throw "Web.config not found in publish directory: $publishDir"
}

# ----------------------------------------------------------
# 6. Update connection string
# ----------------------------------------------------------
Write-Host '[6/7] Updating connection string for DB01 (SQL Server)...' -ForegroundColor Yellow

$webConfigPath = Join-Path $publishDir 'Web.config'
[xml]$webConfig = Get-Content $webConfigPath
$connStr = $webConfig.configuration.connectionStrings.add |
    Where-Object { $_.name -eq 'DefaultConnectionString' }

$newConnStr = "Server=${SqlServer};Database=PartsUnlimitedWebsite;User Id=${SqlUser};Password=${SqlPassword};TrustServerCertificate=True;"
$connStr.connectionString = $newConnStr
$webConfig.Save($webConfigPath)
Write-Host '  Connection string updated.' -ForegroundColor Green

# ----------------------------------------------------------
# 7. Create and deploy IIS site
# ----------------------------------------------------------
Write-Host '[7/7] Setting up IIS site...' -ForegroundColor Yellow

Import-Module WebAdministration

$appPoolName = $SiteName
$sitePath = "C:\inetpub\$SiteName"

# Stop Default Web Site (avoid port conflict)
$defaultSite = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
if ($defaultSite -and $defaultSite.State -eq 'Started') {
    Stop-Website -Name 'Default Web Site'
    Write-Host '  Stopped Default Web Site.' -ForegroundColor Yellow
}

# Copy files to site directory
if (Test-Path $sitePath) {
    Remove-Item -Path $sitePath -Recurse -Force
}
Copy-Item -Path $publishDir -Destination $sitePath -Recurse -Force

# Create application pool
if (-not (Test-Path "IIS:\AppPools\$appPoolName")) {
    New-WebAppPool -Name $appPoolName | Out-Null
}
Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name 'managedRuntimeVersion' -Value 'v4.0'
Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name 'managedPipelineMode' -Value 'Integrated'

# Create IIS site
$existingSite = Get-Website -Name $SiteName -ErrorAction SilentlyContinue
if ($existingSite) {
    Remove-Website -Name $SiteName
}
New-Website -Name $SiteName -PhysicalPath $sitePath -ApplicationPool $appPoolName `
    -Port $SitePort -Force | Out-Null

# Start site
Start-Website -Name $SiteName
Write-Host "  IIS site '$SiteName' created and started." -ForegroundColor Green

# ----------------------------------------------------------
# Complete
# ----------------------------------------------------------
Write-Host ''
Write-Host '=== Parts Unlimited Setup Complete ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Verification:' -ForegroundColor White
Write-Host "  APP01 browser: http://localhost:$SitePort" -ForegroundColor White
Write-Host "  From other VMs: http://10.0.1.6:$SitePort" -ForegroundColor White
Write-Host ''
Write-Host 'Admin login:' -ForegroundColor White
Write-Host '  Email: Administrator@test.com' -ForegroundColor White
Write-Host '  Password: YouShouldChangeThisPassword1!' -ForegroundColor White
