@description('Describes plan\'s pricing tier and instance size. Check details at https://azure.microsoft.com/en-us/pricing/details/app-service/')
@allowed([
  'F1'
  'D1'
  'B1'
  'B2'
  'B3'
  'S1'
  'S2'
  'S3'
  'P1'
  'P2'
  'P3'
  'P4'
])
param skuName string = 'F1'

@description('Describes plan\'s instance count')
@minValue(1)
@maxValue(3)
param skuCapacity int = 1

@description('The admin user of the SQL Server')
param sqlAdministratorLogin string

@description('The password of the admin user of the SQL Server')
@secure()
param sqlAdministratorLoginPassword string

@description('Location for all resources.')
param location string = resourceGroup().location

var hostingPlanName = 'hostingplan${uniqueString(resourceGroup().id)}'
var websiteName = 'website${uniqueString(resourceGroup().id)}'
var sqlserverName = 'sqlServer${uniqueString(resourceGroup().id)}'
var databaseName = 'sampledb'
var privateEndpointName = 'sqlserver-private-endpoint'
var privateDnsZoneName = 'privatelink${environment().suffixes.sqlServerHostname}'
var pvtEndpointDnsGroupName = '${privateEndpointName}/mydnsgroupname'

resource sqlServer 'Microsoft.Sql/servers@2021-02-01-preview' = {
  name: sqlserverName
  location: location
  tags: {
    displayName: 'SQL Server'
  }
  properties: {
    administratorLogin: sqlAdministratorLogin
    administratorLoginPassword: sqlAdministratorLoginPassword
    version: '12.0'
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2021-02-01-preview' = {
  parent: sqlServer
  name: databaseName
  location: location
  tags: {
    displayName: 'Database'
  }
  sku: {
    name: 'Basic'
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 1073741824
  }
}

resource allowAllWindowsAzureIps 'Microsoft.Sql/servers/firewallRules@2021-02-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    endIpAddress: '0.0.0.0'
    startIpAddress: '0.0.0.0'
  }
}

// --- VNet

resource vnet 'Microsoft.Network/virtualNetworks@2021-05-01' = {
  name: uniqueString(resourceGroup().id)
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
  }
}

resource noPrivateLinkSubnet 'Microsoft.Network/virtualNetworks/subnets@2021-05-01' = {
  parent: vnet
  name: 'no-private-subnet'
  properties: {
    natGateway: {
      id: nat.id
    }
    addressPrefix: '10.0.1.0/24'
    privateEndpointNetworkPolicies: 'Disabled'

  }
}

resource privateLinkSubnet 'Microsoft.Network/virtualNetworks/subnets@2021-05-01' = {
  parent: vnet
  name: 'private-subnet'
  properties: {
    natGateway: {
      id: nat.id
    }
    addressPrefix: '10.0.0.0/24'
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2021-05-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: {
      id: privateLinkSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: privateEndpointName
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
  dependsOn: [
    vnet
  ]
}

// -- DNS

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  properties: {}
  dependsOn: [
    vnet
  ]
}

resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${privateDnsZoneName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource pvtEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2021-05-01' = {
  name: pvtEndpointDnsGroupName
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config1'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    privateEndpoint
  ]
}


resource natPublicPrefix 'Microsoft.Network/publicIPPrefixes@2021-08-01' = {
  name: 'nat-gateway-publicIPPrefix'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    prefixLength: 30
  }
}

resource natPublicIP 'Microsoft.Network/publicIPAddresses@2021-08-01' = {
  name: 'nat-gateway-publicIP'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nat 'Microsoft.Network/natGateways@2021-08-01' = {
  location: location
  name: 'example-nat'
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: natPublicIP.id
      }
    ]
    publicIpPrefixes: [
      {
        id: natPublicPrefix.id
      }
    ]
  }
}

// -- App Service Plan

resource hostingPlan 'Microsoft.Web/serverfarms@2020-12-01' = {
  name: hostingPlanName
  location: location
  tags: {
    displayName: 'HostingPlan'
  }
  sku: {
    name: skuName
    capacity: skuCapacity
  }
}

resource website 'Microsoft.Web/sites@2020-12-01' = {
  name: websiteName
  location: location
  tags: {
    'hidden-related:${hostingPlan.id}': 'empty'
    displayName: 'Website'
  }
  properties: {
    serverFarmId: hostingPlan.id
  }
}

resource webSiteConnectionStrings 'Microsoft.Web/sites/config@2020-12-01' = {
  parent: website
  name: 'connectionstrings'
  properties: {
    DefaultConnection: {
      value: 'Data Source=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Initial Catalog=${databaseName};User Id=${sqlAdministratorLogin}@${sqlServer.properties.fullyQualifiedDomainName};Password=${sqlAdministratorLoginPassword};'
      type: 'SQLAzure'
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'AppInsights${website.name}'
  location: location
  tags: {
    'hidden-link:${website.id}': 'Resource'
    displayName: 'AppInsightsComponent'
  }
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}
