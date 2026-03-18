const fs = require('fs');
let content = fs.readFileSync('/home/jarmo-piipponen/plc_simulator/services/gateway/opcua_adapter.js', 'utf8');

// Ensure UserTokenType is imported
if (!content.includes('UserTokenType')) {
    content = content.replace(/const {([^}]+)} = require\(['"]node-opcua['"]\);/, "const {$1, UserTokenType} = require('node-opcua');");
}

// Replace the createSession call
content = content.replace(/this\.session = await this\.client\.createSession\(\{ userName: process\.env\.OPCUA_USER \|\| "PiiJar", password: process\.env\.OPCUA_PASSWORD \|\| "!T0s1v41k33!" \}\);/, 
`this.session = await this.client.createSession({
        type: UserTokenType.UserName,
        userName: process.env.OPCUA_USER || "PiiJar",
        password: process.env.OPCUA_PASSWORD || "!T0s1v41k33!"
      });`);

fs.writeFileSync('/home/jarmo-piipponen/plc_simulator/services/gateway/opcua_adapter.js', content, 'utf8');
