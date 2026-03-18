const fs = require('fs');
let content = fs.readFileSync('/home/jarmo-piipponen/plc_simulator/services/gateway/opcua_adapter.js', 'utf8');

// replace create implementation entirely to ensure it connects unsecurely AND anonymously while testing
content = content.replace(/this\.client = OPCUAClient\.create\(\{[^}]+\}\);/s,
`const { OPCUAClient, MessageSecurityMode, SecurityPolicy } = require("node-opcua");
this.client = OPCUAClient.create({
      applicationName: 'PLCGateway',
      connectionStrategy: {
        initialDelay: 2000,
        maxDelay: 5000,
        maxRetry: 100,
      },
      securityMode: MessageSecurityMode.None,
      securityPolicy: SecurityPolicy.None,
      endpointMustExist: false
    });`);

// also remove the user token entirely since Codesys might reject it based on configuration
content = content.replace(/this\.session = await this\.client\.createSession\(\{[\s\S]*?\}\);/g, 'this.session = await this.client.createSession();');

fs.writeFileSync('/home/jarmo-piipponen/plc_simulator/services/gateway/opcua_adapter.js', content, 'utf8');
