const { OPCUAClient, MessageSecurityMode, SecurityPolicy } = require("node-opcua");

async function main() {
    const endpointUrl = "opc.tcp://172.19.31.7:4840";
    
    // Exact copy of browse_test_3.js instantiation
    const client = OPCUAClient.create({
        endpointMustExist: false,
        connectionStrategy: { maxRetry: 1, initialDelay: 100 }
    });

    try {
        console.log("1. Connecting...");
        await client.connect(endpointUrl);
        console.log("2. Connected. Creating session with PiiJar...");
        
        const session = await client.createSession({
            userName: "PiiJar",
            password: "!T0s1v41k33!"
        });
        console.log("3. Session created!");
        
        await session.close();
        await client.disconnect();
    } catch(e) {
        console.log("\nFAILURE: ", e.message);
        process.exit(1);
    }
}
main();
