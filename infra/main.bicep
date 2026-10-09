@description('Name of the Logic App resource')
param logicAppName string

@description('Azure region/location for deployed resources')
param location string = resourceGroup().location

@description('SQL Server hostname for sql-conn_v1 connection')
param sqlServerName string

@description('Target database name for sql-conn_v1 connection')
param sqlDatabaseName string

@description('SQL Server Authentication username for sql-conn_v1')
param sqlUsername string

@description('SQL Server Authentication password for sql-conn_v1 (Key Vault secret reference)')
@secure()
param sqlPassword string

@description('Recipient for daily report and no-sales emails')
param salesDistributionListEmail string

@description('Recipient for technical failure alerts')
param technicalAlertEmail string

@description('Mailbox identity used by outlook-conn connection')
param senderMailbox string

var sqlConnectionName = 'sql-conn_v1'
var outlookConnectionName = 'outlook-conn'

resource sqlConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: sqlConnectionName
  location: location
  properties: {
    displayName: sqlConnectionName
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'sql')
    }
    parameterValues: {
      server: sqlServerName
      database: sqlDatabaseName
      authType: 'basic'
      username: sqlUsername
      password: sqlPassword
    }
  }
}

resource outlookConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: outlookConnectionName
  location: location
  properties: {
    displayName: outlookConnectionName
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')
    }
  }
}

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('workflows/DailySalesReport.workflow.json')
    parameters: {
      '$connections': {
        value: {
          sql: {
            connectionId: sqlConnection.id
            connectionName: sqlConnectionName
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'sql')
            connectionProperties: {
              authentication: {
                type: 'Raw'
              }
            }
          }
          office365: {
            connectionId: outlookConnection.id
            connectionName: outlookConnectionName
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')
          }
        }
      }
      salesDistributionListEmail: {
        value: salesDistributionListEmail
      }
      technicalAlertEmail: {
        value: technicalAlertEmail
      }
      senderMailbox: {
        value: senderMailbox
      }
    }
  }
  dependsOn: [
    sqlConnection
    outlookConnection
  ]
}
