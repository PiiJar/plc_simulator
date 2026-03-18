const { OPCUAClient, MessageSecurityMode, SecurityPolicy } = require("node-opcua");

async function main() {
    const endpointUrl = "opc.tcp://172.19.31.7:4840";
    
    const client = OPCUAClient.create({
        endpointMustExist: false,
        securityMode: MessageSecurityMode.None,
        securityPolicy: SecurityPolicy.None,
        connectionStrategy: { maxRetry: 1, initialDelay: 100 }
    });

    try {
        console.log("1. Connecting...");
        await client.connect(endpointUrl);
        console.log("2. Connected. Creating Anonymous session...");
        
        const session = await client.createSession();
        console.log("3. Session created!");
        
        await session.close();
        await client.disconnect();
    } catch(e) {
        console.log("\nFAILURE: ", e.message);
        process.exit(1);
    }
}
main();
