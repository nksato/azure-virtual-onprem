# Parts Unlimited デプロイガイド

Parts Unlimited は、Microsoft 公式のサンプル eCommerce アプリケーションです。
ASP.NET 4.5 MVC + Entity Framework 6 + SQL Server で構成されており、
疑似オンプレミス環境の Web/DB 構成を体験するのに適しています。

## 概要

| 項目 | 内容 |
|---|---|
| **リポジトリ** | [microsoft/PartsUnlimitedE2E](https://github.com/microsoft/PartsUnlimitedE2E) (パブリック アーカイブ) |
| **フレームワーク** | ASP.NET 4.5.1 MVC 5 |
| **ORM** | Entity Framework 6.1.3 (Code First) |
| **データベース** | SQL Server (EF が自動作成) |
| **認証** | ASP.NET Identity (OWIN) |
| **Web サーバ** | APP01 (10.0.1.6) — IIS |
| **DB サーバ** | DB01 (10.0.1.5) — SQL Server 2022 Developer |

## 前提条件

- **`main.bicep`** または **`main-nat.bicep`** でデプロイ済みであること (GitHub 等への外部アクセスが必要)
- Bastion 経由で各 VM に RDP 接続できること
- デプロイ完了後、AD ドメイン参加が完了していること

## セットアップ手順

### 1. DB01 — SQL Server セットアップ

Bastion → DB01 に RDP 接続し、管理者 PowerShell を開きます。

#### スクリプトのダウンロード

```powershell
# <GitHubユーザー名> を自身のリポジトリに合わせて変更してください
$repo = 'https://raw.githubusercontent.com/<GitHubユーザー名>/azure-virtual-onprem/main/scripts'
New-Item -Path C:\scripts -ItemType Directory -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri "$repo/Setup-SqlServer.ps1" -OutFile 'C:\scripts\Setup-SqlServer.ps1' -UseBasicParsing
```

> インターネットにアクセスできない環境 (`main-closed.bicep`) の場合は、Bastion RDP のクリップボードにスクリプト内容を貼り付けてファイル保存するか、Storage Account 経由で転送してください。Bastion Basic SKU のブラウザ RDP ではテキストのクリップボードのみ利用可能です。

#### スクリプトの実行

```powershell
cd C:\scripts
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# SQL Server をセットアップ (パスワードは任意の値に変更してください)
.\Setup-SqlServer.ps1 -SqlPassword '<任意のパスワード>'
```

> **注意**: `P@ssw0rd1234` 等の推測されやすいパスワードは避け、十分な強度のパスワードを使用してください。ここで指定したパスワードは APP01 側の `Setup-PartsUnlimited.ps1` でも同じ値を使用します。

#### 実行内容の詳細

1. **SQL 認証の有効化**: レジストリで LoginMode を 2 (混合モード) に変更
2. **TCP/IP の有効化**: WMI 経由で TCP/IP プロトコルを有効化
3. **ファイアウォール**: TCP 1433 の受信ルールを追加 (Domain/Private プロファイル)
4. **SQL Server 再起動**: 上記変更を反映するためサービスを再起動
5. **SQL ログイン作成**: `puadmin` ログインを作成し、`dbcreator` ロールを付与

> **dbcreator ロール**: Entity Framework Code First が初回アクセス時にデータベースを自動作成するために必要です。

> **SQL 認証を使用する理由**: 一般的なオンプレミス環境では、IIS アプリケーション プールをドメイン サービス アカウントで実行し、Windows 認証 (`Integrated Security=True`) で SQL Server に接続するのが標準的です。本ラボでは Parts Unlimited のサンプル アプリが AD 統合を前提としない簡易構成のため、SQL Server 認証 (混合モード) を使用しています。

### 2. APP01 — Parts Unlimited デプロイ

Bastion → APP01 に RDP 接続し、管理者 PowerShell を開きます。

#### スクリプトのダウンロード

```powershell
# <GitHubユーザー名> を自身のリポジトリに合わせて変更してください
$repo = 'https://raw.githubusercontent.com/<GitHubユーザー名>/azure-virtual-onprem/main/scripts'
New-Item -Path C:\scripts -ItemType Directory -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri "$repo/Setup-PartsUnlimited.ps1" -OutFile 'C:\scripts\Setup-PartsUnlimited.ps1' -UseBasicParsing
```

> インターネットにアクセスできない環境 (`main-closed.bicep`) の場合は、Bastion RDP のクリップボードにスクリプト内容を貼り付けてファイル保存するか、Storage Account 経由で転送してください。Bastion Basic SKU のブラウザ RDP ではテキストのクリップボードのみ利用可能です。

#### スクリプトの実行

```powershell
cd C:\scripts
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

.\Setup-PartsUnlimited.ps1 -SqlPassword '<Setup-SqlServer.ps1 と同じパスワード>'
```

#### 実行内容の詳細

1. **作業ディレクトリ作成**: `C:\PartsUnlimited`
2. **VS Build Tools インストール**: Visual Studio Build Tools 2022 を自動ダウンロードし、Web ビルドワークロード (MSBuild + WebApplication targets) をインストール
   - 初回は約 10〜15 分かかります
   - Build Tools はサブスクリプション不要で無償利用可能です (ライセンス条項は参考リンクを参照)
   - スクリプトは `--quiet` オプションでサイレント インストールを行うため、実行時にライセンス条項へ自動的に同意したものとみなされます。事前に条項を確認してください
   - .NET Framework 4.5.1 Targeting Pack (ビルド用の参照アセンブリ) が未インストールの場合は自動的に追加インストールします。Parts Unlimited は .NET 4.5.1 をターゲットとしており、Web ビルドワークロードの既定には含まれないためです
3. **NuGet.exe ダウンロード**: パッケージ復元用
4. **ソースコード取得**: GitHub から ZIP ダウンロード → 展開
5. **ビルド**: NuGet restore → MSBuild Release ビルド

> **注意 (NuGet Audit 警告)**: NuGet 6.8 以降では、パッケージ復元時に既知の脆弱性を検出する **NuGet Audit** 機能が既定で有効になっています。Parts Unlimited はアーカイブ済みのサンプル アプリであり、古いバージョンのパッケージを使用しているため、復元時に `NU1901`〜`NU1904` 等の脆弱性警告が多数表示されることがあります。これらはラボ環境での動作には影響しませんが、本番利用を意図したものではない点にご注意ください。

6. **接続文字列書き換え**: `Web.config` の `DefaultConnectionString` を DB01 向けに変更
7. **IIS デプロイ**: アプリケーションプール作成 → サイト作成 → 開始

### 3. 動作確認

#### ブラウザでアクセス

APP01 の RDP セッション内で IE/Edge を開き:

```
http://localhost
```

他の VM (DC01, DB01) からは:

```
http://10.0.1.6
```

#### 期待される画面

- ヘッダーに "Parts Unlimited" ロゴ
- カテゴリ: Brakes, Lighting, Wheels & Tires, Batteries, Oil
- 各カテゴリに 3 つずつ商品が表示される
- ショッピングカート機能が動作する

#### 管理者ログイン

画面右上の「Log in」から以下でログイン:

| 項目 | 値 |
|---|---|
| メールアドレス | `Administrator@test.com` |
| パスワード | `YouShouldChangeThisPassword1!` |

> これらはサンプル アプリの `Web.config` にハードコードされた既定値です。アプリ起動時に ASP.NET Identity の Seed データとして DB に自動登録されます。

管理者としてログインすると、商品の追加・編集・削除、注文管理が可能です。

## トラブルシューティング

### Build Tools のインストールに失敗する

- インターネット送信アクセスを確認: `main-nat.bicep` テンプレートでデプロイされているか
- `Test-NetConnection -ComputerName aka.ms -Port 443` で外部接続を確認

### ビルドエラー

- NuGet パッケージソースが到達可能か確認: `C:\PartsUnlimited\nuget.exe sources list`
- ビルドログ: `C:\PartsUnlimited` 配下の MSBuild 出力を確認

### DB 接続エラー (初回アクセス時)

- DB01 の SQL Server が起動しているか: `Get-Service MSSQLSERVER` (DB01 上)
- TCP/IP 接続確認: `Test-NetConnection -ComputerName 10.0.1.5 -Port 1433` (APP01 上)
- SQL ログインの確認: `Invoke-Sqlcmd -Query "SELECT name FROM sys.server_principals WHERE name = 'puadmin'" -ServerInstance '.' -TrustServerCertificate` (DB01 上)
- ファイアウォール: `Get-NetFirewallRule -DisplayName 'SQL Server (TCP 1433)'` (DB01 上)

### IIS 500 エラー

- 詳細エラーの確認: `Web.config` で `<customErrors mode="Off" />` になっていることを確認 (デフォルトで Off)
- アプリケーション プールの確認: `Get-WebAppPoolState -Name PartsUnlimited`
- イベントログ: `Get-EventLog -LogName Application -Source ASP.NET* -Newest 10`

## データベース構成

Entity Framework Code First により、初回アクセス時に以下が自動作成されます:

| テーブル | 内容 |
|---|---|
| Categories | 5 カテゴリ (Brakes, Lighting, Wheels & Tires, Batteries, Oil) |
| Products | 18 商品 |
| Stores | 20 店舗 |
| RainChecks | 各店舗にランダムな Raincheck |
| AspNetUsers / AspNetRoles | ASP.NET Identity テーブル |
| Orders / OrderDetails | 注文テーブル (初期データなし) |
| CartItems | カートテーブル (初期データなし) |

## 備考: Azure VM Run Command によるリモート実行

Bastion RDP を使わず、ローカル PC から Azure CLI の `az vm run-command invoke` を使ってスクリプトを実行することも可能です。ローカルの `.ps1` ファイルの内容が VM に送信されて実行されるため、VM にスクリプトを事前配置する必要はありません。

> VM 名はホスト名 (DB01 / APP01) ではなく、Azure リソース名 (`OnPrem-SQL` / `OnPrem-Web`) を指定します。リソース名は `az vm list --resource-group rg-onpre --query "[].name" -o tsv` で確認できます。

> ここでは英語版スクリプト (`*-en.ps1`) を指定しています。VM Run Command はスクリプトの内容をそのまま VM に送信しますが、日本語を含むスクリプトは PowerShell 5.1 の文字コード処理でパースエラーになる場合があります。`*-en.ps1` はコメントやメッセージを英語に変更したもので、機能は日本語版と同一です。

```powershell
# DB01 (OnPrem-SQL) — SQL Server セットアップ
az vm run-command invoke `
  --resource-group rg-onpre `
  --name OnPrem-SQL `
  --command-id RunPowerShellScript `
  --scripts @scripts/Setup-SqlServer-en.ps1 `
  --parameters "SqlPassword=<任意のパスワード>" `
  --query "value[].message" -o tsv

# APP01 (OnPrem-Web) — Parts Unlimited デプロイ
az vm run-command invoke `
  --resource-group rg-onpre `
  --name OnPrem-Web `
  --command-id RunPowerShellScript `
  --scripts @scripts/Setup-PartsUnlimited-en.ps1 `
  --parameters "SqlPassword=<Setup-SqlServer.ps1 と同じパスワード>" `
  --query "value[].message" -o tsv
```

> `--query "value[].message" -o tsv` により、JSON ではなくスクリプトの標準出力・標準エラーがテキストとして表示されます。

> **注意**: `Setup-PartsUnlimited-en.ps1` は VS Build Tools のインストールを含むため、完了まで 15〜20 分程度かかる場合があります。`az vm run-command invoke` はスクリプト完了まで待機し、実行結果を返します。

## 参考リンク

- [Parts Unlimited E2E リポジトリ](https://github.com/microsoft/PartsUnlimitedE2E)
- [Visual Studio ダウンロード](https://visualstudio.microsoft.com/ja/downloads/)
- [Visual Studio Build Tools 2022](https://aka.ms/vs/17/release/vs_buildtools.exe)
- [Visual Studio Build Tools ライセンス条項](https://visualstudio.microsoft.com/license-terms/vs2022-ga-diagnosticbuildtools/)
- [ASP.NET MVC 5 ドキュメント](https://learn.microsoft.com/aspnet/mvc/overview/getting-started/introduction/)
- [Entity Framework 6 ドキュメント](https://learn.microsoft.com/ef/ef6/)
