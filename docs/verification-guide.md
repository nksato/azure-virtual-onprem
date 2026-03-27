# OPLab 動作確認手順書

## 前提条件

- デプロイが完了していること
- Azure Portal にアクセスできること
- 確認対象リソースグループ: `rg-onpre`

---

## 1. 閉域構成の確認 (ネットワーク露出チェック)

### 1-1. VM にパブリック IP がないことを確認

```powershell
# 各 VM の NIC にパブリック IP が割り当てられていないことを確認
az network nic show --resource-group rg-onpre --name OnPrem-AD-NIC --query "ipConfigurations[].publicIPAddress" -o tsv
az network nic show --resource-group rg-onpre --name OnPrem-SQL-NIC --query "ipConfigurations[].publicIPAddress" -o tsv
az network nic show --resource-group rg-onpre --name OnPrem-Web-NIC --query "ipConfigurations[].publicIPAddress" -o tsv
```

**期待結果**: 3つとも出力なし (パブリック IP 未割り当て)

### 1-2. NSG ルールの確認

```powershell
# NSG の有効なルールを確認
az network nsg show --resource-group rg-onpre --name OnPrem-Server-NSG --query "securityRules[].{name:name, direction:direction, access:access, priority:priority, source:sourceAddressPrefix, dest:destinationAddressPrefix}" -o table
```

**期待結果** (使用テンプレートにより異なる):

**main.bicep / main-nat.bicep の場合** (2 ルール):

| Name | Direction | Access | Priority | Source | Dest |
|---|---|---|---|---|---|
| AllowVNetInbound | Inbound | Allow | 100 | VirtualNetwork | VirtualNetwork |
| DenyInternetInbound | Inbound | Deny | 4000 | Internet | * |

**main-closed.bicep の場合** (3 ルール — 上記 + 以下):

| Name | Direction | Access | Priority | Source | Dest |
|---|---|---|---|---|---|
| DenyInternetOutbound | Outbound | Deny | 4000 | * | Internet |

### 1-3. VM からインターネットへの送信確認

Bastion 経由で任意の VM に接続し (接続方法は [2-1](#2-1-azure-portal-から-bastion-接続) を参照)、以下を実行します。

```powershell
# インターネットへの送信テスト
Test-NetConnection -ComputerName 8.8.8.8 -Port 443 -InformationLevel Quiet
```

**期待結果** (使用テンプレートにより異なる):

| テンプレート | 期待結果 | 理由 |
|---|---|---|
| main.bicep | `True` | 既定の送信 IP でインターネットアクセス可能 |
| main-closed.bicep | `False` | defaultOutboundAccess: false + NSG Outbound Deny |
| main-nat.bicep | `True` | NAT Gateway 経由でインターネットアクセス可能 |

---

## 2. Azure Bastion 経由の RDP 接続確認

### 2-1. Azure Portal から Bastion 接続

以下の手順を各 VM (DC01, DB01, APP01) に対して実施します。

#### Azure Portal からの接続手順

1. [Azure Portal](https://portal.azure.com) → リソースグループ `rg-onpre` を開く
2. 対象 VM を選択 (OnPrem-AD / OnPrem-SQL / OnPrem-Web)
3. 左メニュー「概要」→ 上部の「接続」ボタン →「Bastion 経由で接続」を選択
4. 認証情報を入力:
   - **認証の種類**: VM パスワード
   - **ユーザー名**: `labadmin`
   - **パスワード**: デプロイ時に指定したパスワード
5. 「接続」をクリック → ブラウザの新しいタブで RDP セッションが開く

> **ポップアップブロック**: ブラウザのポップアップブロッカーが有効な場合、接続タブが開かないことがあります。`https://portal.azure.com` のポップアップを許可してください。

#### Azure CLI からの接続手順

```powershell
# RDP ファイルをダウンロードして接続 (Azure CLI + Bastion 拡張機能)
az network bastion rdp `
  --resource-group rg-onpre `
  --name OnPrem-Bastion `
  --target-resource-id $(az vm show --resource-group rg-onpre --name OnPrem-AD --query id -o tsv)
```

> **前提**: `az extension add --name bastion` で Bastion 拡張機能がインストールされていること。
> `--name` の後の VM 名を `OnPrem-SQL` / `OnPrem-Web` に変えて各 VM に接続します。

**期待結果**: 各 VM に RDP でログインできること

| VM 名 | ホスト名 | IP | 接続結果 |
|---|---|---|---|
| OnPrem-AD | DC01 | 10.0.1.4 | □ OK / □ NG |
| OnPrem-SQL | DB01 | 10.0.1.5 | □ OK / □ NG |
| OnPrem-Web | APP01 | 10.0.1.6 | □ OK / □ NG |

### 2-2. 各サーバのセットアップ完了確認

Bastion 接続後、各 VM で以下を確認します。

#### DC01 (Active Directory)

```powershell
# ドメインコントローラーであることを確認
Get-ADDomainController | Select-Object Name, Domain, Forest, IPv4Address

# DNS サーバが動作していることを確認
Get-DnsServerZone | Select-Object ZoneName, ZoneType

# ドメイン名の確認
(Get-ADDomain).DNSRoot
```

**期待結果**:
- ドメイン名: `lab.local`
- DNS ゾーン `lab.local` が存在
- DC01 がドメインコントローラーとして認識

#### DB01 (SQL Server)

```powershell
# ドメイン参加の確認
(Get-WmiObject Win32_ComputerSystem).Domain

# SQL Server サービスの稼働確認
Get-Service -Name MSSQLSERVER | Select-Object Name, Status

# SQL Server 接続テスト
sqlcmd -S localhost -Q "SELECT @@SERVERNAME AS ServerName, @@VERSION AS Version"

# データドライブの確認
Get-Volume | Where-Object { $_.DriveLetter -eq 'F' } | Select-Object DriveLetter, FileSystemLabel, Size
```

**期待結果**:
- ドメイン: `lab.local`
- MSSQLSERVER サービス: Running
- SQL Server 2022 Developer Edition
- F: ドライブが存在 (128 GB)

#### APP01 (IIS / ASP.NET)

```powershell
# ドメイン参加の確認
(Get-WmiObject Win32_ComputerSystem).Domain

# IIS がインストールされていることを確認
Get-WindowsFeature Web-Server | Select-Object Name, InstallState

# ASP.NET 4.5 がインストールされていることを確認
Get-WindowsFeature Web-Asp-Net45 | Select-Object Name, InstallState

# IIS Default Web Site の動作確認
Invoke-WebRequest -Uri http://localhost -UseBasicParsing | Select-Object StatusCode
```

**期待結果**:
- ドメイン: `lab.local`
- Web-Server: Installed
- Web-Asp-Net45: Installed
- HTTP 200 応答

---

## 3. 閉域内の相互接続確認

各 VM に Bastion で接続し、以下のコマンドを実行します。

### 3-1. Ping による疎通確認

#### APP01 (10.0.1.6) から実行

```powershell
# APP01 → DC01
Test-NetConnection -ComputerName 10.0.1.4 -InformationLevel Quiet

# APP01 → DB01
Test-NetConnection -ComputerName 10.0.1.5 -InformationLevel Quiet
```

#### DB01 (10.0.1.5) から実行

```powershell
# DB01 → DC01
Test-NetConnection -ComputerName 10.0.1.4 -InformationLevel Quiet

# DB01 → APP01
Test-NetConnection -ComputerName 10.0.1.6 -InformationLevel Quiet
```

#### DC01 (10.0.1.4) から実行

```powershell
# DC01 → DB01
Test-NetConnection -ComputerName 10.0.1.5 -InformationLevel Quiet

# DC01 → APP01
Test-NetConnection -ComputerName 10.0.1.6 -InformationLevel Quiet
```

**期待結果**: すべて `True`

### 3-2. DNS 名前解決の確認 (ドメイン名での接続)

#### APP01 から実行

```powershell
# ドメイン名での名前解決
Resolve-DnsName DC01.lab.local | Select-Object Name, IPAddress
Resolve-DnsName DB01.lab.local | Select-Object Name, IPAddress

# ドメイン名で Ping
Test-NetConnection -ComputerName DC01.lab.local -InformationLevel Quiet
Test-NetConnection -ComputerName DB01.lab.local -InformationLevel Quiet
```

**期待結果**:
- DC01.lab.local → 10.0.1.4
- DB01.lab.local → 10.0.1.5

### 3-3. サービスレベルの接続確認

#### APP01 → DB01 (SQL Server 接続)

```powershell
# SQL Server ポート (1433) への接続確認
Test-NetConnection -ComputerName 10.0.1.5 -Port 1433
```

**期待結果**: `TcpTestSucceeded: True`

#### APP01 → DC01 (LDAP 接続)

```powershell
# LDAP ポート (389) への接続確認
Test-NetConnection -ComputerName 10.0.1.4 -Port 389

# Kerberos ポート (88) への接続確認
Test-NetConnection -ComputerName 10.0.1.4 -Port 88
```

**期待結果**: 両方 `TcpTestSucceeded: True`

#### DC01 → DB01 / APP01 (リモート管理)

```powershell
# WinRM ポート (5985) への接続確認
Test-NetConnection -ComputerName 10.0.1.5 -Port 5985
Test-NetConnection -ComputerName 10.0.1.6 -Port 5985
```

**期待結果**: 両方 `TcpTestSucceeded: True`

---

## 確認結果サマリ

| # | 確認項目 | 結果 |
|---|---|---|
| 1-1 | VM にパブリック IP がない | □ OK / □ NG |
| 1-2 | NSG ルールが正しい | □ OK / □ NG |
| 1-3 | インターネットから到達不可 | □ OK / □ NG |
| 2-1 | Bastion → DC01 RDP 接続 | □ OK / □ NG |
| 2-1 | Bastion → DB01 RDP 接続 | □ OK / □ NG |
| 2-1 | Bastion → APP01 RDP 接続 | □ OK / □ NG |
| 2-2 | DC01 AD DS セットアップ | □ OK / □ NG |
| 2-2 | DB01 SQL Server セットアップ | □ OK / □ NG |
| 2-2 | APP01 IIS セットアップ | □ OK / □ NG |
| 3-1 | APP01 ↔ DC01 疎通 | □ OK / □ NG |
| 3-1 | APP01 ↔ DB01 疎通 | □ OK / □ NG |
| 3-1 | DC01 ↔ DB01 疎通 | □ OK / □ NG |
| 3-2 | ドメイン名での名前解決 | □ OK / □ NG |
| 3-3 | APP01 → DB01 SQL (1433) | □ OK / □ NG |
| 3-3 | APP01 → DC01 LDAP (389) | □ OK / □ NG |
| 3-3 | APP01 → DC01 Kerberos (88) | □ OK / □ NG |
