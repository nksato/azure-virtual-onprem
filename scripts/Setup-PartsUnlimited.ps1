# ============================================================
# Setup-PartsUnlimited.ps1
# APP01 (IIS/Web) に対して実行するセットアップスクリプト
# Parts Unlimited (ASP.NET 4.8 MVC) をビルド・デプロイします
# ============================================================
# 前提条件:
#   - main-nat.bicep でデプロイ済み (GitHub アクセスにインターネット送信が必要)
#   - DB01 で Setup-SqlServer.ps1 を実行済み
# 使い方: Bastion 経由で APP01 に RDP 接続し、管理者 PowerShell で実行
#   .\Setup-PartsUnlimited.ps1 -SqlPassword 'P@ssw0rd1234'
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

Write-Host '=== Parts Unlimited セットアップ開始 ===' -ForegroundColor Cyan

# ----------------------------------------------------------
# 1. 作業ディレクトリ作成
# ----------------------------------------------------------
Write-Host '[1/7] 作業ディレクトリ準備...' -ForegroundColor Yellow
if (Test-Path $WorkDir) {
    Write-Host "  $WorkDir は既に存在します。既存ファイルを削除します..." -ForegroundColor Yellow
    Remove-Item -Path $WorkDir -Recurse -Force
}
New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
Write-Host "  $WorkDir を作成しました。" -ForegroundColor Green

# ----------------------------------------------------------
# 2. Visual Studio Build Tools 2022 インストール
#    (Web ビルドツール ワークロード)
# ----------------------------------------------------------
Write-Host '[2/7] Visual Studio Build Tools のインストール確認...' -ForegroundColor Yellow

$msbuildPath = ''
$vsWherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"

if (Test-Path $vsWherePath) {
    $msbuildPath = & $vsWherePath -latest -requires Microsoft.Component.MSBuild `
        -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
}

if (-not $msbuildPath) {
    Write-Host '  Build Tools をダウンロード・インストールします (約 10-15 分)...' -ForegroundColor Yellow
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
        throw "Build Tools のインストールに失敗しました (ExitCode: $($process.ExitCode))"
    }

    # vswhere で MSBuild パスを再検索 (最大 30 秒リトライ)
    for ($i = 0; $i -lt 6; $i++) {
        if (Test-Path $vsWherePath) {
            $msbuildPath = & $vsWherePath -latest -requires Microsoft.Component.MSBuild `
                -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
        }
        if ($msbuildPath) { break }
        Write-Host '  Build Tools の登録を待機中...' -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }

    # フォールバック: 既知のインストールパスを直接検索
    if (-not $msbuildPath) {
        $fallbackPaths = @(
            "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
            "$env:ProgramFiles\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
        )
        $msbuildPath = $fallbackPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    if (-not $msbuildPath) {
        throw 'MSBuild が見つかりません。Build Tools のインストールを確認してください。'
    }
    Write-Host '  Build Tools をインストールしました。' -ForegroundColor Green
} else {
    Write-Host "  Build Tools は既にインストールされています: $msbuildPath" -ForegroundColor Green
}

# ----------------------------------------------------------
# 3. NuGet.exe のダウンロード
# ----------------------------------------------------------
Write-Host '[3/7] NuGet.exe のダウンロード...' -ForegroundColor Yellow
$nugetPath = "$WorkDir\nuget.exe"
if (-not (Test-Path $nugetPath)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile $nugetPath -UseBasicParsing
    Write-Host '  NuGet.exe をダウンロードしました。' -ForegroundColor Green
} else {
    Write-Host '  NuGet.exe は既に存在します。' -ForegroundColor Green
}

# ----------------------------------------------------------
# 4. ソースコードのダウンロードと展開
# ----------------------------------------------------------
Write-Host '[4/7] Parts Unlimited ソースコードのダウンロード...' -ForegroundColor Yellow
$zipPath = "$WorkDir\source.zip"
$repoUrl = 'https://github.com/microsoft/PartsUnlimitedE2E/archive/refs/heads/master.zip'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $repoUrl -OutFile $zipPath -UseBasicParsing

Write-Host '  ZIP を展開中...' -ForegroundColor Yellow
Expand-Archive -Path $zipPath -DestinationPath $WorkDir -Force

$srcRoot = Join-Path $WorkDir 'PartsUnlimitedE2E-master\PartsUnlimited-aspnet45'
if (-not (Test-Path $srcRoot)) {
    throw "ソースディレクトリが見つかりません: $srcRoot"
}
Write-Host "  ソースコード展開完了: $srcRoot" -ForegroundColor Green

# .csproj のターゲットを .NET 4.5.1 から .NET 4.8 に変更
# Windows Server 2022 には .NET 4.8 が標準搭載されていますが、
# 4.5.1 Targeting Pack は含まれません。アプリは .NET 4.8 で完全に動作します (上位互換)。
$csprojPath = Join-Path $srcRoot 'src\PartsUnlimitedWebsite\PartsUnlimitedWebsite.csproj'
$csprojContent = Get-Content $csprojPath -Raw
if ($csprojContent -match 'v4\.5\.1') {
    $csprojContent = $csprojContent -replace '<TargetFrameworkVersion>v4\.5\.1</TargetFrameworkVersion>', '<TargetFrameworkVersion>v4.8</TargetFrameworkVersion>'
    Set-Content -Path $csprojPath -Value $csprojContent -Encoding UTF8
    Write-Host '  プロジェクトのターゲットを .NET 4.5.1 から .NET 4.8 に変更しました。' -ForegroundColor Yellow
}

# ----------------------------------------------------------
# 5. NuGet パッケージ復元 & ビルド
# ----------------------------------------------------------
Write-Host '[5/7] NuGet パッケージ復元 & ビルド...' -ForegroundColor Yellow

$solutionPath = Join-Path $srcRoot 'PartsUnlimited.sln'
$publishDir = "$WorkDir\publish"
$webProjectPath = Join-Path $srcRoot 'src\PartsUnlimitedWebsite\PartsUnlimitedWebsite.csproj'

# NuGet restore (Web サイトプロジェクトのみ、modelproj 評価エラーを回避)
Write-Host '  NuGet パッケージを復元中...' -ForegroundColor Yellow
& $nugetPath restore $webProjectPath -SolutionDirectory $srcRoot
if ($LASTEXITCODE -ne 0) { throw 'NuGet restore に失敗しました。' }

# MSBuild — Web サイトプロジェクトのみビルド (テスト・モデリングプロジェクトはスキップ)
Write-Host '  ビルド中...' -ForegroundColor Yellow
& $msbuildPath $webProjectPath `
    /p:Configuration=Release `
    /p:DeployOnBuild=true `
    /p:publishUrl=$publishDir `
    /p:WebPublishMethod=FileSystem `
    /verbosity:quiet
if ($LASTEXITCODE -ne 0) { throw 'ビルドに失敗しました。' }
Write-Host '  ビルド成功。' -ForegroundColor Green

# ビルド出力のフォールバック: _PublishedWebsites ディレクトリを確認
if (-not (Test-Path "$publishDir\Web.config")) {
    $pubWebsites = Get-ChildItem -Path $srcRoot -Recurse -Directory -Filter '_PublishedWebsites' |
        Select-Object -First 1
    if ($pubWebsites) {
        $pubSite = Join-Path $pubWebsites.FullName 'PartsUnlimitedWebsite'
        if (Test-Path "$pubSite\Web.config") {
            $publishDir = $pubSite
            Write-Host "  発行ディレクトリ (フォールバック): $publishDir" -ForegroundColor Yellow
        }
    }
}

# フォールバック: PackageTmp ディレクトリ (PublishProfile なしの DeployOnBuild が作成)
if (-not (Test-Path "$publishDir\Web.config")) {
    $packageTmp = Join-Path $srcRoot 'src\PartsUnlimitedWebsite\obj\Release\Package\PackageTmp'
    if (Test-Path "$packageTmp\Web.config") {
        $publishDir = $packageTmp
        Write-Host "  発行ディレクトリ (PackageTmp): $publishDir" -ForegroundColor Yellow
    }
}

# さらにフォールバック: プロジェクトディレクトリ直下でWeb.configがある場所を探す
if (-not (Test-Path "$publishDir\Web.config")) {
    $webProject = Join-Path $srcRoot 'src\PartsUnlimitedWebsite'
    if (Test-Path "$webProject\Web.config") {
        $publishDir = $webProject
        Write-Host "  発行ディレクトリ (プロジェクト直接): $publishDir" -ForegroundColor Yellow
    }
}

if (-not (Test-Path "$publishDir\Web.config")) {
    throw "発行ディレクトリに Web.config が見つかりません: $publishDir"
}

# ----------------------------------------------------------
# 6. 接続文字列の書き換え
# ----------------------------------------------------------
Write-Host '[6/7] 接続文字列を DB01 (SQL Server) 向けに書き換え...' -ForegroundColor Yellow

$webConfigPath = Join-Path $publishDir 'Web.config'
[xml]$webConfig = Get-Content $webConfigPath
$connStr = $webConfig.configuration.connectionStrings.add |
    Where-Object { $_.name -eq 'DefaultConnectionString' }

$newConnStr = "Server=${SqlServer};Database=PartsUnlimitedWebsite;User Id=${SqlUser};Password=${SqlPassword};TrustServerCertificate=True;"
$connStr.connectionString = $newConnStr
$webConfig.Save($webConfigPath)
Write-Host '  接続文字列を更新しました。' -ForegroundColor Green

# ----------------------------------------------------------
# 7. IIS サイトの作成とデプロイ
# ----------------------------------------------------------
Write-Host '[7/7] IIS サイトをセットアップ...' -ForegroundColor Yellow

Import-Module WebAdministration

$appPoolName = $SiteName
$sitePath = "C:\inetpub\$SiteName"

# Default Web Site を停止 (ポート競合回避)
$defaultSite = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
if ($defaultSite -and $defaultSite.State -eq 'Started') {
    Stop-Website -Name 'Default Web Site'
    Write-Host '  Default Web Site を停止しました。' -ForegroundColor Yellow
}

# サイトディレクトリへコピー
if (Test-Path $sitePath) {
    Remove-Item -Path $sitePath -Recurse -Force
}
Copy-Item -Path $publishDir -Destination $sitePath -Recurse -Force

# アプリケーション プール作成
if (-not (Test-Path "IIS:\AppPools\$appPoolName")) {
    New-WebAppPool -Name $appPoolName | Out-Null
}
Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name 'managedRuntimeVersion' -Value 'v4.0'
Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name 'managedPipelineMode' -Value 'Integrated'

# IIS サイト作成
$existingSite = Get-Website -Name $SiteName -ErrorAction SilentlyContinue
if ($existingSite) {
    Remove-Website -Name $SiteName
}
New-Website -Name $SiteName -PhysicalPath $sitePath -ApplicationPool $appPoolName `
    -Port $SitePort -Force | Out-Null

# サイト開始
Start-Website -Name $SiteName
Write-Host "  IIS サイト '$SiteName' を作成・開始しました。" -ForegroundColor Green

# ----------------------------------------------------------
# 完了
# ----------------------------------------------------------
Write-Host ''
Write-Host '=== Parts Unlimited セットアップ完了 ===' -ForegroundColor Cyan
Write-Host ''
Write-Host '動作確認:' -ForegroundColor White
Write-Host "  APP01 ブラウザ: http://localhost:$SitePort" -ForegroundColor White
Write-Host "  他の VM から:   http://10.0.1.6:$SitePort" -ForegroundColor White
Write-Host ''
Write-Host '管理者ログイン:' -ForegroundColor White
Write-Host '  メール: Administrator@test.com' -ForegroundColor White
Write-Host '  パスワード: YouShouldChangeThisPassword1!' -ForegroundColor White
