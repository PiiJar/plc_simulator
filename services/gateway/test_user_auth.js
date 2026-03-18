const { OPCUAClient, MessageSecurityMode, SecurityPolicy } = require("node-opcua");

async function main() {
    const endpointUrl = "opc.tcp://172.19.31.7:4840";
    console.log("Connecting to", endpointUrl, "with username/password...");
    
    const client = OPCUAClient.create({
        endpointMustExist: false,
        securityMode: MessageSecurityMode.None,
        securityPolicy: SecurityPolicy.None,
        connectionStrategy: { maxRetry: 1, initialDelay: 1000 }
    });

    try {
        await client.connect(endpointUrl);
        console.log("Connected to server!");
        
        const session = await client.createSession({
            userName: "PiiJar",
            password: "!T0s1v41k33!"
        });
        console.log("SUCCESS: Session created with PiiJar!");
        
        await session.close();
        await client.disconnect();
    } catch(e) {
        console.log("\nFAILURE: ", e.message);
        process.exit(1);
    }
}
main();
