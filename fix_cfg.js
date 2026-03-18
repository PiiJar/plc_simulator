const fs = require('fs');
let content = fs.readFileSync('/home/jarmo-piipponen/plc_simulator/services/codesys/CODESYSControl_User.cfg', 'utf8');

// Ensure CmpOPCUAServer is explicitly loaded in ComponentManager
if (!content.includes('Component.7=CmpOPCUAServer')) {
    content = content.replace(/\[ComponentManager\]\n(Component\.\d+=[^\n]+\n)+/m, 
    match => match + "Component.7=CmpOPCUAServer\n");
}

fs.writeFileSync('/home/jarmo-piipponen/plc_simulator/services/codesys/CODESYSControl_User.cfg', content, 'utf8');
