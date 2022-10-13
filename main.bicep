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
param skuName string = 'S1'

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

var publicHostingPlanName = 'hostingplan${uniqueString(resourceGroup().id)}'
var privateHostingPlanName = 'privatehostingplan${uniqueString(resourceGroup().id)}'
var publicWebsiteName = 'website${uniqueString(resourceGroup().id)}'
var privateWebsiteName = 'privatewebsite${uniqueString(resourceGroup().id)}'
var sqlserverName = 'sqlServerName${uniqueString(resourceGroup().id)}'
var sqlPoolName = 'sqlElasticPool${uniqueString(resourceGroup().id)}'
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
    name: 'ElasticPool'
    tier: 'Basic'
    capacity: 0
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    elasticPoolId: sqlElasticPool.id
  }
}

resource sqlElasticPool 'Microsoft.Sql/servers/elasticPools@2022-05-01-preview' = {
  parent: sqlServer
  location: location
  name: sqlPoolName
  sku: {
    name: 'BasicPool'
    tier: 'Basic'
    capacity: 50
  }
  properties: {
    perDatabaseSettings: {
      minCapacity: 0
      maxCapacity: 5
    }
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


// --- VNet with no private link

resource publicVnet 'Microsoft.Network/virtualNetworks@2021-05-01' = {
  name: 'public${uniqueString(resourceGroup().id)}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'public-subnet'
        properties: {
          natGateway: {
            id: publicNat.id
          }
          addressPrefix: '10.0.0.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
          delegations: [
            {
              name: 'app-service-delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
    ]
  }
}


// --- VNET with private link

resource privateVnet 'Microsoft.Network/virtualNetworks@2021-05-01' = {
  name: 'private${uniqueString(resourceGroup().id)}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'private-link-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'private-link-app-subnet'
        properties: {
          natGateway: {
            id: privateNat.id
          }
          addressPrefix: '10.0.0.0/24'
          delegations: [
            {
              name: 'app-service-delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
    ]
  }
}


resource privateEndpoint 'Microsoft.Network/privateEndpoints@2021-05-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: {
      id: privateVnet.properties.subnets[0].id
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
}

// -- DNS

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  properties: {}
  dependsOn: [
    privateVnet
  ]
}

resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${privateDnsZoneName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: privateVnet.id
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

// -- NAT for private vnet

resource privateNatPublicPrefix 'Microsoft.Network/publicIPPrefixes@2021-08-01' = {
  name: 'private-nat-gateway-publicIPPrefix'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    prefixLength: 30
  }
}

resource privateNatPublicIP 'Microsoft.Network/publicIPAddresses@2021-08-01' = {
  name: 'private-nat-gateway-publicIP'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource privateNat 'Microsoft.Network/natGateways@2021-08-01' = {
  location: location
  name: 'private-nat'
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: privateNatPublicIP.id
      }
    ]
    publicIpPrefixes: [
      {
        id: privateNatPublicPrefix.id
      }
    ]
  }
}

// -- NAT for public vnet

resource publicNatPublicPrefix 'Microsoft.Network/publicIPPrefixes@2021-08-01' = {
  name: 'public-nat-gateway-publicIPPrefix'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    prefixLength: 30
  }
}

resource publicNatPublicIP 'Microsoft.Network/publicIPAddresses@2021-08-01' = {
  name: 'nat-gateway-publicIP'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource publicNat 'Microsoft.Network/natGateways@2021-08-01' = {
  location: location
  name: 'example-nat'
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: publicNatPublicIP.id
      }
    ]
    publicIpPrefixes: [
      {
        id: publicNatPublicPrefix.id
      }
    ]
  }
}

// -- Public App Service

resource publicHostingPlan 'Microsoft.Web/serverfarms@2020-12-01' = {
  name: publicHostingPlanName
  location: location
  tags: {
    displayName: 'PublicHostingPlan'
  }
  sku: {
    name: skuName
    capacity: skuCapacity
  }
}

resource publicWebsite 'Microsoft.Web/sites@2020-12-01' = {
  name: publicWebsiteName
  location: location
  tags: {
    'hidden-related:${publicHostingPlan.id}': 'empty'
    displayName: 'Website'
  }
  properties: {
    serverFarmId: publicHostingPlan.id
    virtualNetworkSubnetId: publicVnet.properties.subnets[0].id
    siteConfig: {
      vnetRouteAllEnabled: true
    }
  }
}

resource publicAppSettings 'Microsoft.Web/sites/config@2022-03-01' = {
  parent: publicWebsite
  name: 'appsettings'
  properties: {
    WEBSITE_NODE_DEFAULT_VERSION: 'Production'
  }
}

// -- Private App Service

resource privateHostingPlan 'Microsoft.Web/serverfarms@2020-12-01' = {
  name: privateHostingPlanName
  location: location
  tags: {
    displayName: 'HostingPlan'
  }
  sku: {
    name: skuName
    capacity: skuCapacity
  }
}

resource privateWebsite 'Microsoft.Web/sites@2020-12-01' = {
  name: privateWebsiteName
  location: location
  tags: {
    'hidden-related:${privateHostingPlan.id}': 'empty'
    displayName: 'Website'
  }
  properties: {
    serverFarmId: privateHostingPlan.id
    virtualNetworkSubnetId: privateVnet.properties.subnets[1].id
    siteConfig: {
      vnetRouteAllEnabled: true
    }
  }
}

resource privateAppSettings 'Microsoft.Web/sites/config@2022-03-01' = {
  parent: privateWebsite
  name: 'appsettings'
  properties: {
    WEBSITE_NODE_DEFAULT_VERSION: 'Production'
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'AppInsights'
  location: location
  tags: {
    displayName: 'AppInsightsComponent'
  }
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

output sqlserverDns string = '${sqlserverName}${environment().suffixes.sqlServerHostname}'
output publicWebsiteScmDns string = '${publicWebsiteName}.scm.azurewebsites.net'
output publicWebsiteName string = publicWebsiteName
