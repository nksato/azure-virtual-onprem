// ============================================================
// 疑似オンプレミス環境 — パターン 3: NAT Gateway 付き (インターネット送信可能)
// ============================================================
// defaultOutboundAccess: false で既定の送信を無効化したうえで、
// NAT Gateway 経由でインターネットへの送信アクセスを提供します。
// Windows Update、パッケージインストール、GitHub からのダウンロード等が可能です。
// ============================================================

@description('管理者ユーザー名')
param adminUsername string = 'labadmin'

@description('管理者パスワード')
@secure()
param adminPassword string

@description('リソースの場所')
param location string = resourceGroup().location

@description('Active Directory ドメイン名')
param domainName string = 'lab.local'

@description('VPN 共有キー (S2S 接続用)')
@secure()
param vpnSharedKey string

@description('接続先 Azure VPN Gateway のパブリック IP アドレス (空の場合 S2S 接続リソースはスキップ)')
param remoteGatewayIp string = ''

@description('接続先 Azure 側のアドレス空間')
param remoteAddressPrefix string = '10.100.0.0/16'

// NSG: 閉域ネットワーク — VNet 内通信のみ許可、Inbound のみ制限
// ※ NAT Gateway 経由の Outbound を許可するため、Outbound 拒否ルールは設定しない
resource serverNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'OnPrem-Server-NSG'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowVNetInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyInternetInbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// NAT Gateway — ServerSubnet のインターネット送信アクセス用
resource natGatewayPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'OnPrem-NatGw-PIP'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'OnPrem-NatGw'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: natGatewayPip.id
      }
    ]
    idleTimeoutInMinutes: 4
  }
}

// 疑似オンプレミス VNet
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'OnPrem-VNet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    dhcpOptions: {
      dnsServers: [
        '10.0.1.4' // AD サーバをドメイン DNS として使用
      ]
    }
    subnets: [
      {
        name: 'ServerSubnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: serverNsg.id
          }
          defaultOutboundAccess: false
          natGateway: {
            id: natGateway.id
          }
        }
      }
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: '10.0.255.0/27'
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.0.254.0/26'
        }
      }
    ]
  }
}

resource serverSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'ServerSubnet'
}

resource gatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'GatewaySubnet'
}

resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'AzureBastionSubnet'
}

// Azure Bastion — 閉域ネットワークへの管理アクセス
resource bastionPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'OnPrem-Bastion-PIP'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: 'OnPrem-Bastion'
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastionIpConfig'
        properties: {
          publicIPAddress: {
            id: bastionPip.id
          }
          subnet: {
            id: bastionSubnet.id
          }
        }
      }
    ]
  }
}

// ============================================================
// AD サーバ (Windows Server 2022 / Active Directory)
// ============================================================

resource adNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'OnPrem-AD-NIC'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: serverSubnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.1.4'
        }
      }
    ]
  }
}

resource adVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'OnPrem-AD'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2ms'
    }
    osProfile: {
      computerName: 'DC01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-Datacenter'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: adNic.id
        }
      ]
    }
  }
}

// AD DS 役割インストール + ドメインコントローラー昇格
resource adSetupExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: adVm
  name: 'ADSetup'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -Command "Install-WindowsFeature -Name AD-Domain-Services,DNS -IncludeManagementTools; Import-Module ADDSDeployment; Install-ADDSForest -DomainName ${domainName} -SafeModeAdministratorPassword (ConvertTo-SecureString \'${adminPassword}\' -AsPlainText -Force) -DomainNetbiosName \'LAB\' -InstallDNS -Force -NoRebootOnCompletion; shutdown /r /t 60"'
    }
  }
}

// ============================================================
// SQL サーバ (SQL Server 2022 Developer on Windows Server 2022)
// ============================================================

resource sqlNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'OnPrem-SQL-NIC'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: serverSubnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.1.5'
        }
      }
    ]
  }
}

resource sqlVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'OnPrem-SQL'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2ms'
    }
    osProfile: {
      computerName: 'DB01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftSQLServer'
        offer: 'sql2022-ws2022'
        sku: 'sqldev-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          diskSizeGB: 128
          createOption: 'Empty'
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: sqlNic.id
        }
      ]
    }
  }
}

// SQL Server VM 固有の設定 (データドライブ構成)
resource sqlVmConfig 'Microsoft.SqlVirtualMachine/sqlVirtualMachines@2023-10-01' = {
  name: sqlVm.name
  location: location
  properties: {
    virtualMachineResourceId: sqlVm.id
    sqlServerLicenseType: 'PAYG'
    storageConfigurationSettings: {
      diskConfigurationType: 'NEW'
      sqlDataSettings: {
        luns: [0]
        defaultFilePath: 'F:\\SQLData'
      }
      sqlLogSettings: {
        luns: [0]
        defaultFilePath: 'F:\\SQLLog'
      }
    }
  }
}

// SQL サーバのドメイン参加 (AD 構築完了後に実行)
resource sqlDomainJoin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: sqlVm
  name: 'DomainJoin'
  location: location
  dependsOn: [
    adSetupExtension
  ]
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      Name: domainName
      User: '${domainName}\\${adminUsername}'
      Restart: 'true'
      Options: '3'
    }
    protectedSettings: {
      Password: adminPassword
    }
  }
}

// ============================================================
// Web サーバ (Windows Server 2022 / IIS + ASP.NET)
// ============================================================

resource webNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'OnPrem-Web-NIC'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: serverSubnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.1.6'
        }
      }
    ]
  }
}

resource webVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'OnPrem-Web'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2ms'
    }
    osProfile: {
      computerName: 'APP01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-Datacenter'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: webNic.id
        }
      ]
    }
  }
}

// IIS + ASP.NET 4.5 インストール
resource webIisExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: webVm
  name: 'IISSetup'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -Command "Install-WindowsFeature -Name Web-Server,Web-Asp-Net45,Web-Mgmt-Tools,NET-Framework-45-ASPNET -IncludeManagementTools"'
    }
  }
}

// Web サーバのドメイン参加 (AD 構築完了後に実行)
resource webDomainJoin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: webVm
  name: 'DomainJoin'
  location: location
  dependsOn: [
    adSetupExtension
    webIisExtension
  ]
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      Name: domainName
      User: '${domainName}\\${adminUsername}'
      Restart: 'true'
      Options: '3'
    }
    protectedSettings: {
      Password: adminPassword
    }
  }
}

// ============================================================
// VPN Gateway (S2S 接続用)
// ============================================================

resource vpnGatewayPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'OnPrem-VpnGw-PIP'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2024-05-01' = {
  name: 'OnPrem-VpnGw'
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: {
      name: 'VpnGw1'
      tier: 'VpnGw1'
    }
    ipConfigurations: [
      {
        name: 'vpnGwIpConfig'
        properties: {
          publicIPAddress: {
            id: vpnGatewayPip.id
          }
          subnet: {
            id: gatewaySubnet.id
          }
        }
      }
    ]
  }
}

// S2S 接続先 (Azure 側) を表す Local Network Gateway
resource localNetworkGateway 'Microsoft.Network/localNetworkGateways@2024-05-01' = if (remoteGatewayIp != '') {
  name: 'Azure-LocalGw'
  location: location
  properties: {
    gatewayIpAddress: remoteGatewayIp
    localNetworkAddressSpace: {
      addressPrefixes: [
        remoteAddressPrefix
      ]
    }
  }
}

// S2S VPN 接続
resource vpnConnection 'Microsoft.Network/connections@2024-05-01' = if (remoteGatewayIp != '') {
  name: 'OnPrem-to-Azure-S2S'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: vpnGateway.id
      properties: {}
    }
    localNetworkGateway2: {
      id: localNetworkGateway.id
      properties: {}
    }
    sharedKey: vpnSharedKey
    connectionProtocol: 'IKEv2'
  }
}

// ============================================================
// Outputs
// ============================================================

output vpnGatewayPublicIp string = vpnGatewayPip.properties.ipAddress
output bastionName string = bastion.name
output natGatewayPublicIp string = natGatewayPip.properties.ipAddress
output adServerPrivateIp string = '10.0.1.4'
output sqlServerPrivateIp string = '10.0.1.5'
output webServerPrivateIp string = '10.0.1.6'
