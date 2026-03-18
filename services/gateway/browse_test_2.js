const { OPCUAClient, MessageSecurityMode, SecurityPolicy, UserTokenType } = require("node-opcua");

async function main() {
    const endpointUrl = "opc.tcp://127.0.0.1:4840";
    console.log("Connecting to", endpointUrl);
    
    // First let's get endpoints to understand what the server requires
    const client = OPCUAClient.create({
        endpointMustExist: false
    });
    
    try {
        await client.connect(endpointUrl);
        const endpoints = await client.getEndpoints();
        console.log("Found " + endpoints.length + " endpoints.");
        for (const endpoint of endpoints) {
            console.log("- Endpoint:", endpoint.endpointUrl);
            console.log("  Security Mode:", endpoint.securityMode.toString());
            console.log("  Security Policy:", endpoint.securityPolicyUri);
            console.log("  User Token Policies:", endpoint.userIdentityTokens.map(t => t.policyId).join(", "));
        }
        await client.disconnect();
    } catch(e) {
        console.log("Failed to get endpoints:", e.message);
        process.exit(1);
    }
}
main();
