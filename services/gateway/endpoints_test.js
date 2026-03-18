const { OPCUAClient } = require("node-opcua");

async function main() {
    const endpointUrl = "opc.tcp://127.0.0.1:4840";
    try {
        const endpoints = await OPCUAClient.getEndpoints(endpointUrl);
        endpoints.forEach((e, i) => {
            console.log(`[${i}] Endpoint: ${e.endpointUrl}`);
            console.log(`    Security Mode: ${e.securityMode.toString()}`);
            console.log(`    Security Policy: ${e.securityPolicyUri}`);
            console.log(`    Tokens: `, e.userIdentityTokens.map(t => t.policyId).join(", "));
        });
    } catch(err) {
        console.log("Failed to get endpoints:", err.message);
    }
}
main();
