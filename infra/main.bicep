targetScope = 'resourceGroup'

@description('Name of the Consumption Logic App.')
param logicAppName string

@description('Azure region for the Logic App and managed API connections.')
param location string = resourceGroup().location

@description('SQL Server managed API connection parameter values. Supply the approved authentication configuration securely.')
@secure()
param sqlConnectionParameterValues object

@description('Office 365 Outlook managed API connection parameter values. Supply the authenticated mailbox configuration securely.')
@secure()
param outlookConnectionParameterValues object

@description('SQL Server name used by the workflow.')
param sqlServerName string

@description('SQL database name used by the workflow.')
param sqlDatabaseName string

@description('Schema-qualified employee table name.')
param sqlEmployeeTable string

@description('Identity column used by the SQL create trigger.')
param employeeIdentityColumn string

@description('Employee name column.')
param employeeNameColumn string

@description('Employee ID column.')
param employeeIdColumn string

@description('Department column.')
param departmentColumn string

@description('Joining date column.')
param joiningDateColumn string

@description('HR recipient address or distribution list.')
param hrRecipientAddress string

@description('Number of retries for the email action.')
param emailRetryCount int

@description('Maximum interval between email retries in ISO 8601 duration format.')
param emailRetryMaximumInterval string

var workflowSchema = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
var sqlApiId = subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'sql')
var outlookApiId = subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')

resource sqlConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: 'sqlEmployeeConnection'
  location: location
  properties: {
    api: {
      id: sqlApiId
    }
    displayName: 'sqlEmployeeConnection'
    parameterValues: sqlConnectionParameterValues
  }
}

resource outlookConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: 'hrOutlookConnection'
  location: location
  properties: {
    api: {
      id: outlookApiId
    }
    displayName: 'hrOutlookConnection'
    parameterValues: outlookConnectionParameterValues
  }
}

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': workflowSchema
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': {
          type: 'Object'
          defaultValue: {}
        }
        sqlServerName: {
          type: 'String'
        }
        sqlDatabaseName: {
          type: 'String'
        }
        sqlEmployeeTable: {
          type: 'String'
        }
        employeeIdentityColumn: {
          type: 'String'
        }
        employeeNameColumn: {
          type: 'String'
        }
        employeeIdColumn: {
          type: 'String'
        }
        departmentColumn: {
          type: 'String'
        }
        joiningDateColumn: {
          type: 'String'
        }
        hrRecipientAddress: {
          type: 'String'
        }
        emailRetryCount: {
          type: 'Int'
        }
        emailRetryMaximumInterval: {
          type: 'String'
        }
      }
      triggers: {
        When_an_item_is_created: {
          type: 'ApiConnection'
          recurrence: {
            frequency: 'Minute'
            interval: 5
          }
          inputs: {
            host: {
              connection: {
                name: '@parameters(\'$connections\')[\'sqlEmployeeConnection\'][\'connectionId\']'
              }
            }
            method: 'get'
            path: '/v2/datasets/@{encodeURIComponent(encodeURIComponent(parameters(\'sqlServerName\')))},@{encodeURIComponent(encodeURIComponent(parameters(\'sqlDatabaseName\')))}/tables/@{encodeURIComponent(encodeURIComponent(parameters(\'sqlEmployeeTable\')))}/onnewitems'
            parameters: {
              server: '@parameters(\'sqlServerName\')'
              database: '@parameters(\'sqlDatabaseName\')'
              table: '@parameters(\'sqlEmployeeTable\')'
            }
          }
          splitOn: '@triggerBody()?[\'value\']'
        }
      }
      actions: {
        Get_Employee_Details: {
          type: 'ApiConnection'
          runAfter: {}
          inputs: {
            host: {
              connection: {
                name: '@parameters(\'$connections\')[\'sqlEmployeeConnection\'][\'connectionId\']'
              }
            }
            method: 'get'
            path: '/v2/datasets/@{encodeURIComponent(encodeURIComponent(parameters(\'sqlServerName\')))},@{encodeURIComponent(encodeURIComponent(parameters(\'sqlDatabaseName\')))}/tables/@{encodeURIComponent(encodeURIComponent(parameters(\'sqlEmployeeTable\')))}/items/@{encodeURIComponent(triggerBody()?[parameters(\'employeeIdentityColumn\')])}'
            parameters: {
              server: '@parameters(\'sqlServerName\')'
              database: '@parameters(\'sqlDatabaseName\')'
              table: '@parameters(\'sqlEmployeeTable\')'
              id: '@triggerBody()?[parameters(\'employeeIdentityColumn\')]'
            }
          }
        }
        Send_HR_Notification: {
          type: 'ApiConnection'
          runAfter: {
            Get_Employee_Details: [
              'Succeeded'
            ]
          }
          inputs: {
            host: {
              connection: {
                name: '@parameters(\'$connections\')[\'hrOutlookConnection\'][\'connectionId\']'
              }
            }
            method: 'post'
            path: '/v2/Mail'
            body: {
              To: '@parameters(\'hrRecipientAddress\')'
              Subject: 'New employee added'
              Body: '@concat(\'<p>A new employee has been added.</p><p><strong>Name:</strong> \', string(body(\'Get_Employee_Details\')?[parameters(\'employeeNameColumn\')]), \'<br/><strong>Employee ID:</strong> \', string(body(\'Get_Employee_Details\')?[parameters(\'employeeIdColumn\')]), \'<br/><strong>Department:</strong> \', string(body(\'Get_Employee_Details\')?[parameters(\'departmentColumn\')]), \'<br/><strong>Joining Date:</strong> \', string(body(\'Get_Employee_Details\')?[parameters(\'joiningDateColumn\')]), \'</p>\')'
            }
          }
          retryPolicy: {
            type: 'Exponential'
            count: '@parameters(\'emailRetryCount\')'
            interval: '@parameters(\'emailRetryMaximumInterval\')'
          }
        }
        Handle_Email_Failure: {
          type: 'Scope'
          runAfter: {
            Send_HR_Notification: [
              'Failed'
              'TimedOut'
            ]
          }
          actions: {
            Record_Sanitized_Failure: {
              type: 'Compose'
              inputs: '@concat(\'Email notification failed. Status: \', actions(\'Send_HR_Notification\').status, \'. Workflow run: \', workflow().run.id)'
              runAfter: {}
            }
          }
        }
      }
      outputs: {}
    }
    parameters: {
      '$connections': {
        value: {
          sqlEmployeeConnection: {
            connectionId: sqlConnection.id
            connectionName: sqlConnection.name
            id: sqlApiId
          }
          hrOutlookConnection: {
            connectionId: outlookConnection.id
            connectionName: outlookConnection.name
            id: outlookApiId
          }
        }
      }
      sqlServerName: {
        value: sqlServerName
      }
      sqlDatabaseName: {
        value: sqlDatabaseName
      }
      sqlEmployeeTable: {
        value: sqlEmployeeTable
      }
      employeeIdentityColumn: {
        value: employeeIdentityColumn
      }
      employeeNameColumn: {
        value: employeeNameColumn
      }
      employeeIdColumn: {
        value: employeeIdColumn
      }
      departmentColumn: {
        value: departmentColumn
      }
      joiningDateColumn: {
        value: joiningDateColumn
      }
      hrRecipientAddress: {
        value: hrRecipientAddress
      }
      emailRetryCount: {
        value: emailRetryCount
      }
      emailRetryMaximumInterval: {
        value: emailRetryMaximumInterval
      }
    }
  }
}

output logicAppResourceId string = logicApp.id
output sqlConnectionResourceId string = sqlConnection.id
output outlookConnectionResourceId string = outlookConnection.id
