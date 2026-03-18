const { OPCUAClient, UserTokenType, MessageSecurityMode, SecurityPolicy } = require("node-opcua");

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
        const session = await client.createSession();
        console.log("Session created anonymously!");
        await session.close();
        await client.disconnect();
    } catch(err) {
        console.log("Anonymous failed: ", err.message);
        
        try {
             const session2 = await client.createSession({
                  userName: "Administrator",
                  password: "1"
             });
             console.log("Logged in as Administrator/1!");
             await session2.close();
        } catch(err2) {
             console.log("Admin failed: ", err2.message);
        }
        await client.disconnect();
    }
}
main();
