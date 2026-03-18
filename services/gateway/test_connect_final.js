const { OPCUAClient, MessageSecurityMode, SecurityPolicy } = require("node-opcua");

async function main() {
    const endpointUrl = "opc.tcp://172.19.31.7:4840";
    console.log("FINAL TEST: Attempting connection with explicit overrides");
    
    const client = OPCUAClient.create({
        endpointMustExist: false,
        securityMode: MessageSecurityMode.SignAndEncrypt,
        securityPolicy: SecurityPolicy.Basic256Sha256,
        connectionStrategy: { maxRetry: 1, initialDelay: 100 },
        // Bypass local certificate verification
        verifyServerCertificate: false
    });

    try {
        console.log("1. TCP Socket connecting...");
        await client.connect(endpointUrl);
        console.log("2. Connected. Creating secure session with credentials...");
        
        const session = await client.createSession({
            userName: "PiiJar",
            password: "!T0s1v41k33!"
        });
        console.log("3. BINGO! Session successfully created over secure connection!");
        
        await session.close();
        await client.disconnect();
    } catch(e) {
        console.log("\nFAILURE: ", e.message);
    }
}
main();
