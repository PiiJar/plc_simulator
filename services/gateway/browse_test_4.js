const { OPCUAClient } = require("node-opcua");

async function main() {
    const endpointUrl = "opc.tcp://172.19.31.7:4840";
    console.log("Connecting manually to", endpointUrl, "to inspect endpoints deeply...");
    
    const client = OPCUAClient.create({ endpointMustExist: false, connectionStrategy: { maxRetry: 1 } });
    try {
        await client.connect(endpointUrl);
        const endpoints = await client.getEndpoints();
        endpoints.forEach(e => {
             console.log(`- ${e.endpointUrl} | SecMode: ${e.securityMode.toString()}`);
             if (e.userIdentityTokens) {
                 e.userIdentityTokens.forEach(t => console.log(`   -> Token: ${t.policyId}`));
             } else {
                 console.log("   -> NO IDENTITY TOKENS AT ALL");
             }
        });
        await client.disconnect();
    } catch(e) {
        console.log("\nFAILURE: ", e.message);
    }
}
main();
