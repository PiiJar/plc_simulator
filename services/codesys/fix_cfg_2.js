const fs = require('fs');
const filePath = '/home/jarmo-piipponen/plc_simulator/services/codesys/CODESYSControl_User.cfg';
let data = fs.readFileSync(filePath, 'utf8');

data = data.replace('NetworkAdapter=\n', '');
data = data.replace('NetworkPort=4840\n', '');

fs.writeFileSync(filePath, data);
console.log('Fixed config.');
