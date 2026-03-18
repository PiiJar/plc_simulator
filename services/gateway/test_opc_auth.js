const { OPCUAClient, MessageSecurityMode, SecurityPolicy } = require("node-opcua");

async function main() {
    const endpointUrl = "opc.tcp://127.0.0.1:4840";
    const client = OPCUAClient.create({
        endpointMustExist: false,
        securityMode: MessageSecurityMode.None,
        securityPolicy: SecurityPolicy.None,
    });
    
    try {
        await client.connect(endpointUrl);
        console.log("connected", endpointUrl);
        const session = await client.createSession({
             userName: "PiiJar",
             password: "!T0s1v41k33!"
        });
        console.log("Logged in with PiiJar successfully!");
        await session.close();
        await client.disconnect();
    } catch(err) {
        console.log("Auth failed: ", err.message);
        await client.disconnect();
    }
}
main();
