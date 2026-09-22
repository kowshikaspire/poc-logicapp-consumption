targetScope = 'resourceGroup'

@description('Name of the PurchaseOrderProcessing Logic App.')
param logicAppName string = 'PurchaseOrderProcessing'

@description('Azure region for the workflow and API connections.')
param location string = resourceGroup().location

@description('Azure SQL server name, without protocol.')
param sqlServerName string

@description('Azure SQL database name.')
param sqlDatabaseName string

@description('Configured Vendors table name.')
param vendorsTableName string

@description('Configured order header table name.')
param orderHeaderTableName string

@description('Configured order line table name.')
param orderLineTableName string

@description('Configured error log table name.')
param errorLogTableName string = 'ErrorLog'

@description('Azure Service Bus namespace name.')
param serviceBusNamespace string

@description('Service Bus queue for approved orders.')
param fulfilmentQueueName string = 'orders-to-fulfil'

@secure()
@description('Support team email address used for failure alerts.')
param supportTeamEmail string

@description('Procurement system CIDR ranges allowed to call the request trigger.')
param procurementIpRanges array

@description('Approval threshold for purchase orders.')
param approvalThreshold int = 10000

@description('Maximum approval wait duration.')
param approvalTimeout string = 'PT24H'

@secure()
@description('Deployment-time OAuth authorization value for the new Outlook API connection.')
param office365ConnectionAuthorization string

var sqlConnectionName = 'purchaseOrderSql'
var serviceBusConnectionName = 'purchaseOrderServiceBus'
var outlookConnectionName = 'purchaseOrderOutlook'
var sqlApiId = subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'sql')
var serviceBusApiId = subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'servicebus')
var outlookApiId = subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')

resource sqlConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: sqlConnectionName
  location: location
  #disable-next-line BCP187
  kind: 'V1'
  properties: json('{"api":{"id":"${sqlApiId}"},"authenticatedUser":{},"connectionState":"Enabled","customParameterValues":{},"displayName":"${sqlConnectionName}","parameterValueSet":{"name":"managedIdentityAuth","values":{}}}')
}

resource serviceBusConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: serviceBusConnectionName
  location: location
  #disable-next-line BCP187
  kind: 'V1'
  properties: json('{"api":{"id":"${serviceBusApiId}"},"authenticatedUser":{},"connectionState":"Enabled","customParameterValues":{},"displayName":"${serviceBusConnectionName}","parameterValueSet":{"name":"managedIdentityAuth","values":{"namespaceEndpoint":"sb://${serviceBusNamespace}.servicebus.windows.net/"}}}')
}

resource outlookConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: outlookConnectionName
  location: location
  properties: json('{"api":{"id":"${outlookApiId}"},"authenticatedUser":{},"connectionState":"Enabled","customParameterValues":{},"displayName":"${outlookConnectionName}","parameterValues":{"token":"${office365ConnectionAuthorization}"}}')
}

resource purchaseOrderProcessing 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    accessControl: {
      triggers: {
        allowedCallerIpAddresses: [for ipRange in procurementIpRanges: {
          addressRange: ipRange
        }]
      }
    }
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
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
        vendorsTableName: {
          type: 'String'
        }
        orderHeaderTableName: {
          type: 'String'
        }
        orderLineTableName: {
          type: 'String'
        }
        errorLogTableName: {
          type: 'String'
        }
        fulfilmentQueueName: {
          type: 'String'
        }
        supportTeamEmail: {
          type: 'SecureString'
        }
        approvalThreshold: {
          type: 'int'
        }
        approvalTimeout: {
          type: 'String'
        }
      }
      triggers: {
        When_an_HTTP_request_is_received: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {
              type: 'object'
              additionalProperties: false
              required: [
                'OrderId'
                'VendorId'
                'RequesterEmail'
                'ManagerEmail'
                'Currency'
                'Items'
              ]
              properties: {
                OrderId: {
                  type: 'string'
                  minLength: 1
                }
                VendorId: {
                  type: 'string'
                  minLength: 1
                }
                RequesterEmail: {
                  type: 'string'
                  format: 'email'
                }
                ManagerEmail: {
                  type: 'string'
                  format: 'email'
                }
                Currency: {
                  type: 'string'
                  minLength: 1
                }
                Items: {
                  type: 'array'
                  minItems: 1
                  items: {
                    type: 'object'
                    additionalProperties: false
                    required: [
                      'ItemCode'
                      'Quantity'
                      'UnitPrice'
                    ]
                    properties: {
                      ItemCode: {
                        type: 'string'
                        minLength: 1
                      }
                      Quantity: {
                        type: 'number'
                        exclusiveMinimum: 0
                      }
                      UnitPrice: {
                        type: 'number'
                        minimum: 0
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
      actions: {
        Accepted_response: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            statusCode: 202
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              OrderId: '''@triggerBody()?['OrderId']'''
            }
          }
          operationOptions: 'Asynchronous'
          runAfter: {}
        }
        Initialize_orderTotal: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'orderTotal'
                type: 'float'
                value: 0
              }
            ]
          }
          runAfter: {
            Accepted_response: [
              'Succeeded'
            ]
          }
        }
        Initialize_vendorEligible: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'vendorEligible'
                type: 'boolean'
                value: false
              }
            ]
          }
          runAfter: {
            Initialize_orderTotal: [
              'Succeeded'
            ]
          }
        }
        Initialize_approvalStatus: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'approvalStatus'
                type: 'string'
                value: 'NotRequired'
              }
            ]
          }
          runAfter: {
            Initialize_vendorEligible: [
              'Succeeded'
            ]
          }
        }
        Initialize_processingStatus: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'processingStatus'
                type: 'string'
                value: 'Received'
              }
            ]
          }
          runAfter: {
            Initialize_approvalStatus: [
              'Succeeded'
            ]
          }
        }
        Initialize_errorMessage: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'errorMessage'
                type: 'string'
                value: ''
              }
            ]
          }
          runAfter: {
            Initialize_processingStatus: [
              'Succeeded'
            ]
          }
        }
        Main_processing: {
          type: 'Scope'
          actions: {
            Calculate_order_total: {
              type: 'Foreach'
              foreach: '''@triggerBody()?['Items']'''
              operationOptions: 'Sequential'
              actions: {
                Add_line_total: {
                  type: 'IncrementVariable'
                  inputs: {
                    name: 'orderTotal'
                    value: '''@mul(float(items('Calculate_order_total')?['Quantity']), float(items('Calculate_order_total')?['UnitPrice']))'''
                  }
                  runAfter: {}
                }
              }
              runAfter: {}
            }
            Get_vendor_record: {
              type: 'ApiConnection'
              inputs: {
                host: {
                  connection: {
                    name: '''@parameters('$connections')['purchaseOrderSql']['connectionId']'''
                  }
                }
                method: 'get'
                path: '''/v2/datasets/@{encodeURIComponent(encodeURIComponent(parameters('sqlServerName')))},@{encodeURIComponent(encodeURIComponent(parameters('sqlDatabaseName')))}/tables/@{encodeURIComponent(encodeURIComponent(parameters('vendorsTableName')))}/items'''
                queries: {
                  '$filter': '''@concat('VendorId eq ', decodeUriComponent('%27'), triggerBody()?['VendorId'], decodeUriComponent('%27'))'''
                  '$top': 1
                }
                retryPolicy: {
                  type: 'exponential'
                  count: 4
                  interval: 'PT5S'
                }
              }
              runAfter: {
                Calculate_order_total: [
                  'Succeeded'
                ]
              }
            }
            Set_vendor_eligibility: {
              type: 'SetVariable'
              inputs: {
                name: 'vendorEligible'
                value: '''@and(greater(length(body('Get_vendor_record')?['value']), 0), equals(first(body('Get_vendor_record')?['value'])?['Active'], true))'''
              }
              runAfter: {
                Get_vendor_record: [
                  'Succeeded'
                ]
              }
            }
            Vendor_eligibility_condition: {
              type: 'If'
              expression: {
                equals: [
                  '''@variables('vendorEligible')'''
                  true
                ]
              }
              actions: {
                Approval_threshold_condition: {
                  type: 'If'
                  expression: {
                    greater: [
                      '''@variables('orderTotal')'''
                      '''@parameters('approvalThreshold')'''
                    ]
                  }
                  actions: {
                    Request_manager_approval: {
                      type: 'ApiConnection'
                      inputs: {
                        host: {
                          connection: {
                            name: '''@parameters('$connections')['purchaseOrderOutlook']['connectionId']'''
                          }
                        }
                        method: 'post'
                        path: '/v2/Mail/SendApprovalMail'
                        body: {
                          To: '''@triggerBody()?['ManagerEmail']'''
                          Subject: '''@concat('Purchase order approval required: ', triggerBody()?['OrderId'])'''
                          Options: 'Approve,Reject'
                          HeaderText: 'Manager approval required'
                          SelectionText: 'Select Approve or Reject'
                          Body: '''@concat('Order: ', triggerBody()?['OrderId'], '<br/>Vendor: ', triggerBody()?['VendorId'], '<br/>Total: ', string(variables('orderTotal')), ' ', triggerBody()?['Currency'])'''
                        }
                        retryPolicy: {
                          type: 'fixed'
                          count: 3
                          interval: 'PT10S'
                        }
                      }
                      limit: {
                        timeout: '''@parameters('approvalTimeout')'''
                      }
                      runAfter: {}
                    }
                    Set_approval_status: {
                      type: 'SetVariable'
                      inputs: {
                        name: 'approvalStatus'
                        value: '''@coalesce(body('Request_manager_approval')?['SelectedOption'], 'NotApproved')'''
                      }
                      runAfter: {
                        Request_manager_approval: [
                          'Succeeded'
                          'Failed'
                          'TimedOut'
                        ]
                      }
                    }
                  }
                  else: {
                    actions: {
                      Set_approval_not_required: {
                        type: 'SetVariable'
                        inputs: {
                          name: 'approvalStatus'
                          value: 'NotRequired'
                        }
                        runAfter: {}
                      }
                    }
                  }
                  runAfter: {}
                }
                Approval_outcome_condition: {
                  type: 'If'
                  expression: '''@or(equals(variables('approvalStatus'), 'Approve'), equals(variables('approvalStatus'), 'Approved'), equals(variables('approvalStatus'), 'NotRequired'))'''
                  actions: {
                    Check_duplicate_order: {
                      type: 'ApiConnection'
                      inputs: {
                        host: {
                          connection: {
                            name: '''@parameters('$connections')['purchaseOrderSql']['connectionId']'''
                          }
                        }
                        method: 'get'
                        path: '''/v2/datasets/@{encodeURIComponent(encodeURIComponent(parameters('sqlServerName')))},@{encodeURIComponent(encodeURIComponent(parameters('sqlDatabaseName')))}/tables/@{encodeURIComponent(encodeURIComponent(parameters('orderHeaderTableName')))}/items'''
                        queries: {
                          '$filter': '''@concat('OrderId eq ', decodeUriComponent('%27'), triggerBody()?['OrderId'], decodeUriComponent('%27'))'''
                          '$top': 1
                        }
                        retryPolicy: {
                          type: 'exponential'
                          count: 4
                          interval: 'PT5S'
                        }
                      }
                      runAfter: {}
                    }
                    Duplicate_condition: {
                      type: 'If'
                      expression: {
                        greater: [
                          '''@length(body('Check_duplicate_order')?['value'])'''
                          0
                        ]
                      }
                      actions: {
                        Set_duplicate_status: {
                          type: 'SetVariable'
                          inputs: {
                            name: 'processingStatus'
                            value: 'Duplicate'
                          }
                          runAfter: {}
                        }
                        Notify_duplicate_order: {
                          type: 'ApiConnection'
                          inputs: {
                            host: {
                              connection: {
                                name: '''@parameters('$connections')['purchaseOrderOutlook']['connectionId']'''
                              }
                            }
                            method: 'post'
                            path: '/v2/Mail'
                            body: {
                              To: '''@triggerBody()?['RequesterEmail']'''
                              Subject: '''@concat('Purchase order duplicate: ', triggerBody()?['OrderId'])'''
                              Body: '''@concat('Purchase order ', triggerBody()?['OrderId'], ' was already processed. Final status: Duplicate.')'''
                            }
                            retryPolicy: {
                              type: 'fixed'
                              count: 3
                              interval: 'PT10S'
                            }
                          }
                          runAfter: {
                            Set_duplicate_status: [
                              'Succeeded'
                            ]
                          }
                        }
                      }
                      else: {
                        actions: {
                          Insert_order_header: {
                            type: 'ApiConnection'
                            inputs: {
                              host: {
                                connection: {
                                  name: '''@parameters('$connections')['purchaseOrderSql']['connectionId']'''
                                }
                              }
                              method: 'post'
                              path: '''/v2/datasets/@{encodeURIComponent(encodeURIComponent(parameters('sqlServerName')))},@{encodeURIComponent(encodeURIComponent(parameters('sqlDatabaseName')))}/tables/@{encodeURIComponent(encodeURIComponent(parameters('orderHeaderTableName')))}/items'''
                              body: {
                                OrderId: '''@triggerBody()?['OrderId']'''
                                VendorId: '''@triggerBody()?['VendorId']'''
                                RequesterEmail: '''@triggerBody()?['RequesterEmail']'''
                                Currency: '''@triggerBody()?['Currency']'''
                                Total: '''@variables('orderTotal')'''
                                Status: 'Approved'
                              }
                              retryPolicy: {
                                type: 'exponential'
                                count: 4
                                interval: 'PT5S'
                              }
                            }
                            runAfter: {}
                          }
                          Insert_order_lines: {
                            type: 'Foreach'
                            foreach: '''@triggerBody()?['Items']'''
                            operationOptions: 'Sequential'
                            actions: {
                              Insert_order_line: {
                                type: 'ApiConnection'
                                inputs: {
                                  host: {
                                    connection: {
                                      name: '''@parameters('$connections')['purchaseOrderSql']['connectionId']'''
                                    }
                                  }
                                  method: 'post'
                                  path: '''/v2/datasets/@{encodeURIComponent(encodeURIComponent(parameters('sqlServerName')))},@{encodeURIComponent(encodeURIComponent(parameters('sqlDatabaseName')))}/tables/@{encodeURIComponent(encodeURIComponent(parameters('orderLineTableName')))}/items'''
                                  body: {
                                    OrderId: '''@triggerBody()?['OrderId']'''
                                    ItemCode: '''@items('Insert_order_lines')?['ItemCode']'''
                                    Quantity: '''@items('Insert_order_lines')?['Quantity']'''
                                    UnitPrice: '''@items('Insert_order_lines')?['UnitPrice']'''
                                  }
                                  retryPolicy: {
                                    type: 'exponential'
                                    count: 4
                                    interval: 'PT5S'
                                  }
                                }
                                runAfter: {}
                              }
                            }
                            runAfter: {
                              Insert_order_header: [
                                'Succeeded'
                              ]
                            }
                          }
                          Send_fulfilment_message: {
                            type: 'ApiConnection'
                            inputs: {
                              host: {
                                connection: {
                                  name: '''@parameters('$connections')['purchaseOrderServiceBus']['connectionId']'''
                                }
                              }
                              method: 'post'
                              path: '''/@{encodeURIComponent(parameters('fulfilmentQueueName'))}/messages'''
                              body: {
                                ContentData: '''@base64(string(json(concat('{"OrderId":"', triggerBody()?['OrderId'], '","VendorId":"', triggerBody()?['VendorId'], '","Total":', string(variables('orderTotal')), '}'))))'''
                                ContentType: 'application/json'
                                MessageId: '''@triggerBody()?['OrderId']'''
                              }
                              retryPolicy: {
                                type: 'exponential'
                                count: 4
                                interval: 'PT5S'
                              }
                            }
                            runAfter: {
                              Insert_order_lines: [
                                'Succeeded'
                              ]
                            }
                          }
                          Set_approved_status: {
                            type: 'SetVariable'
                            inputs: {
                              name: 'processingStatus'
                              value: 'Approved'
                            }
                            runAfter: {
                              Send_fulfilment_message: [
                                'Succeeded'
                              ]
                            }
                          }
                          Notify_requester_approved: {
                            type: 'ApiConnection'
                            inputs: {
                              host: {
                                connection: {
                                  name: '''@parameters('$connections')['purchaseOrderOutlook']['connectionId']'''
                                }
                              }
                              method: 'post'
                              path: '/v2/Mail'
                              body: {
                                To: '''@triggerBody()?['RequesterEmail']'''
                                Subject: '''@concat('Purchase order approved: ', triggerBody()?['OrderId'])'''
                                Body: '''@concat('Purchase order ', triggerBody()?['OrderId'], ' is approved. Total: ', string(variables('orderTotal')), ' ', triggerBody()?['Currency'], '. Final status: ', variables('processingStatus'), '.')'''
                              }
                              retryPolicy: {
                                type: 'fixed'
                                count: 3
                                interval: 'PT10S'
                              }
                            }
                            runAfter: {
                              Set_approved_status: [
                                'Succeeded'
                              ]
                            }
                          }
                        }
                      }
                      runAfter: {
                        Check_duplicate_order: [
                          'Succeeded'
                        ]
                      }
                    }
                  }
                  else: {
                    actions: {
                      Set_unapproved_status: {
                        type: 'SetVariable'
                        inputs: {
                          name: 'processingStatus'
                          value: '''@if(equals(variables('approvalStatus'), 'Rejected'), 'Rejected', 'ApprovalTimeout')'''
                        }
                        runAfter: {}
                      }
                      Notify_unapproved_order: {
                        type: 'ApiConnection'
                        inputs: {
                          host: {
                            connection: {
                              name: '''@parameters('$connections')['purchaseOrderOutlook']['connectionId']'''
                            }
                          }
                          method: 'post'
                          path: '/v2/Mail'
                          body: {
                            To: '''@triggerBody()?['RequesterEmail']'''
                            Subject: '''@concat('Purchase order not approved: ', triggerBody()?['OrderId'])'''
                            Body: '''@concat('Purchase order ', triggerBody()?['OrderId'], ' was not approved. Final status: ', variables('processingStatus'), '.')'''
                          }
                          retryPolicy: {
                            type: 'fixed'
                            count: 3
                            interval: 'PT10S'
                          }
                        }
                        runAfter: {
                          Set_unapproved_status: [
                            'Succeeded'
                          ]
                        }
                      }
                      Stop_unapproved_order: {
                        type: 'Terminate'
                        inputs: {
                          runStatus: 'Succeeded'
                        }
                        runAfter: {
                          Notify_unapproved_order: [
                            'Succeeded'
                          ]
                        }
                      }
                    }
                  }
                  runAfter: {
                    Approval_threshold_condition: [
                      'Succeeded'
                    ]
                  }
                }
              }
              else: {
                actions: {
                  Set_invalid_vendor_status: {
                    type: 'SetVariable'
                    inputs: {
                      name: 'processingStatus'
                      value: 'InvalidVendor'
                    }
                    runAfter: {}
                  }
                  Notify_invalid_vendor: {
                    type: 'ApiConnection'
                    inputs: {
                      host: {
                        connection: {
                          name: '''@parameters('$connections')['purchaseOrderOutlook']['connectionId']'''
                        }
                      }
                      method: 'post'
                      path: '/v2/Mail'
                      body: {
                        To: '''@triggerBody()?['RequesterEmail']'''
                        Subject: '''@concat('Purchase order rejected: ', triggerBody()?['OrderId'])'''
                        Body: '''@concat('Purchase order ', triggerBody()?['OrderId'], ' was rejected because vendor ', triggerBody()?['VendorId'], ' does not exist or is inactive.')'''
                      }
                      retryPolicy: {
                        type: 'fixed'
                        count: 3
                        interval: 'PT10S'
                      }
                    }
                    runAfter: {
                      Set_invalid_vendor_status: [
                        'Succeeded'
                      ]
                    }
                  }
                  Stop_invalid_vendor: {
                    type: 'Terminate'
                    inputs: {
                      runStatus: 'Succeeded'
                    }
                    runAfter: {
                      Notify_invalid_vendor: [
                        'Succeeded'
                      ]
                    }
                  }
                }
              }
              runAfter: {
                Set_vendor_eligibility: [
                  'Succeeded'
                ]
              }
            }
          }
          runAfter: {
            Initialize_errorMessage: [
              'Succeeded'
            ]
          }
        }
        Error_handling: {
          type: 'Scope'
          actions: {
            Set_error_context: {
              type: 'SetVariable'
              inputs: {
                name: 'errorMessage'
                value: '''@coalesce(string(first(result('Main_processing'))?['error']?['message']), 'Main processing scope failed or timed out.')'''
              }
              runAfter: {}
            }
            Log_processing_failure: {
              type: 'ApiConnection'
              inputs: {
                host: {
                  connection: {
                    name: '''@parameters('$connections')['purchaseOrderSql']['connectionId']'''
                  }
                }
                method: 'post'
                path: '''/v2/datasets/@{encodeURIComponent(encodeURIComponent(parameters('sqlServerName')))},@{encodeURIComponent(encodeURIComponent(parameters('sqlDatabaseName')))}/tables/@{encodeURIComponent(encodeURIComponent(parameters('errorLogTableName')))}/items'''
                body: {
                  OrderId: '''@triggerBody()?['OrderId']'''
                  ErrorMessage: '''@variables('errorMessage')'''
                  RunId: '''@workflow().run.id'''
                }
                retryPolicy: {
                  type: 'exponential'
                  count: 4
                  interval: 'PT5S'
                }
              }
              runAfter: {
                Set_error_context: [
                  'Succeeded'
                ]
              }
            }
            Alert_support_team: {
              type: 'ApiConnection'
              inputs: {
                host: {
                  connection: {
                    name: '''@parameters('$connections')['purchaseOrderOutlook']['connectionId']'''
                  }
                }
                method: 'post'
                path: '/v2/Mail'
                body: {
                  To: '''@parameters('supportTeamEmail')'''
                  Subject: '''@concat('Purchase order processing failure: ', triggerBody()?['OrderId'])'''
                  Body: '''@concat('OrderId: ', triggerBody()?['OrderId'], '<br/>RunId: ', workflow().run.id, '<br/>Error: ', variables('errorMessage'))'''
                }
                retryPolicy: {
                  type: 'fixed'
                  count: 3
                  interval: 'PT10S'
                }
              }
              runAfter: {
                Log_processing_failure: [
                  'Succeeded'
                ]
              }
            }
          }
          runAfter: {
            Main_processing: [
              'Failed'
              'TimedOut'
            ]
          }
        }
      }
    }
    parameters: {
      '$connections': {
        value: {
          purchaseOrderSql: {
            connectionId: sqlConnection.id
            connectionName: sqlConnectionName
            id: sqlApiId
            connectionProperties: {
              authentication: {
                type: 'ManagedServiceIdentity'
              }
            }
          }
          purchaseOrderServiceBus: {
            connectionId: serviceBusConnection.id
            connectionName: serviceBusConnectionName
            id: serviceBusApiId
            connectionProperties: {
              authentication: {
                type: 'ManagedServiceIdentity'
              }
            }
          }
          purchaseOrderOutlook: {
            connectionId: outlookConnection.id
            connectionName: outlookConnectionName
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
      vendorsTableName: {
        value: vendorsTableName
      }
      orderHeaderTableName: {
        value: orderHeaderTableName
      }
      orderLineTableName: {
        value: orderLineTableName
      }
      errorLogTableName: {
        value: errorLogTableName
      }
      fulfilmentQueueName: {
        value: fulfilmentQueueName
      }
      supportTeamEmail: {
        value: supportTeamEmail
      }
      approvalThreshold: {
        value: approvalThreshold
      }
      approvalTimeout: {
        value: approvalTimeout
      }
    }
  }
}
