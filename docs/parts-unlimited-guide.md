# Parts Unlimited デプロイガイド

Parts Unlimited は、Microsoft 公式のサンプル eCommerce アプリケーションです。
ASP.NET 4.5 MVC + Entity Framework 6 + SQL Server で構成されており、
疑似オンプレミス環境の Web/DB 構成を体験するのに適しています。

## 概要

| 項目 | 内容 |
|---|---|
| **リポジトリ** | [microsoft/PartsUnlimitedE2E](https://github.com/microsoft/PartsUnlimitedE2E) |
| **フレームワーク** | ASP.NET 4.5.1 MVC 5 |
| **ORM** | Entity Framework 6.1.3 (Code First) |
| **データベース** | SQL Server (EF が自動作成) |
| **認証** | ASP.NET Identity (OWIN) |
| **Web サーバ** | APP01 (10.0.1.6) — IIS |
| **DB サーバ** | DB01 (10.0.1.5) — SQL Server 2022 Developer |

## 前提条件

- **`main-nat.bicep`** でデプロイ済みであること (GitHub 等への外部アクセスが必要)
- Bastion 経由で各 VM に RDP 接続できること
- デプロイ完了後、AD ドメイン参加が完了していること

## セットアップ手順

### 1. スクリプトを VM に転送

Bastion RDP セッション内でスクリプトを実行するため、事前に VM へ転送します。

**方法 A: クリップボード経由**

1. ローカル PC でスクリプトの内容ををコピー
2. Bastion RDP セッション内でメモ帳を開き、貼り付けて保存

**方法 B: Storage Account 経由 (スクリプトが長い場合)**

1. Azure Storage Account に Blob としてアップロード
2. VM 内のブラウザ (IE/Edge) からダウンロード

### 2. DB01 — SQL Server セットアップ

Bastion → DB01 に RDP 接続し、管理者 PowerShell を開きます。

```powershell
# スクリプトを保存したディレクトリに移動
cd C:\scripts

# 実行ポリシーを一時的に変更
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# SQL Server をセットアップ
.\Setup-SqlServer.ps1 -SqlPassword 'P@ssw0rd1234'
```

#### 実行内容の詳細

1. **SQL 認証の有効化**: レジストリで LoginMode を 2 (混合モード) に変更
2. **TCP/IP の有効化**: WMI 経由で TCP/IP プロトコルを有効化
3. **ファイアウォール**: TCP 1433 の受信ルールを追加 (Domain/Private プロファイル)
4. **SQL Server 再起動**: 上記変更を反映するためサービスを再起動
5. **SQL ログイン作成**: `puadmin` ログインを作成し、`dbcreator` ロールを付与

> **dbcreator ロール**: Entity Framework Code First が初回アクセス時にデータベースを自動作成するために必要です。

### 3. APP01 — Parts Unlimited デプロイ

Bastion → APP01 に RDP 接続し、管理者 PowerShell を開きます。

```powershell
cd C:\scripts

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

.\Setup-PartsUnlimited.ps1 -SqlPassword 'P@ssw0rd1234'
```

#### 実行内容の詳細

1. **作業ディレクトリ作成**: `C:\PartsUnlimited`
2. **VS Build Tools インストール**: Web ビルドワークロード (MSBuild + WebApplication targets)
   - 初回は約 10〜15 分かかります
3. **NuGet.exe ダウンロード**: パッケージ復元用
4. **ソースコード取得**: GitHub から ZIP ダウンロード → 展開
5. **ビルド**: NuGet restore → MSBuild Release ビルド
6. **接続文字列書き換え**: `Web.config` の `DefaultConnectionString` を DB01 向けに変更
7. **IIS デプロイ**: アプリケーションプール作成 → サイト作成 → 開始

### 4. 動作確認

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

## 参考リンク

- [Parts Unlimited E2E リポジトリ](https://github.com/microsoft/PartsUnlimitedE2E)
- [ASP.NET MVC 5 ドキュメント](https://learn.microsoft.com/aspnet/mvc/overview/getting-started/introduction/)
- [Entity Framework 6 ドキュメント](https://learn.microsoft.com/ef/ef6/)
