const { OPCUAClient, MessageSecurityMode, SecurityPolicy } = require("node-opcua");

async function main() {
    const endpointUrl = "opc.tcp://172.19.31.7:4840";
    console.log("Connecting manually to", endpointUrl, "to see errors in terminal...");
    
    const client = OPCUAClient.create({
        endpointMustExist: false,
        connectionStrategy: {
            maxRetry: 1,
            initialDelay: 100,
            maxDelay: 200
        }
    });

    try {
        await client.connect(endpointUrl);
        console.log("SUCCESS: Port 4840 is open and node-opcua connected to it!");
        
        console.log("Attempting to read endpoints...");
        const endpoints = await client.getEndpoints();
        console.log(`Found ${endpoints.length} endpoints:`);
        endpoints.forEach(e => {
             console.log(`- ${e.endpointUrl} | SecMode: ${e.securityMode.toString()} | SecPolicy: ${e.securityPolicyUri}`);
             if (e.userIdentityTokens) {
                 e.userIdentityTokens.forEach(t => console.log(`   -> Token: ${t.policyId} (${t.tokenType.toString()})`));
             }
        });
        
        console.log("\nAttempting Anonymous Session Create...");
        const session = await client.createSession();
        console.log("SUCCESS: Anonymous session created!");
        
        await session.close();
        await client.disconnect();
    } catch(e) {
        console.log("\nFAILURE: ", e.message);
        process.exit(1);
    }
}
main();
