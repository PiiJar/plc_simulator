const fs = require('fs');
let content = fs.readFileSync('src/App.jsx', 'utf8');

// remove setDisplayTransporterStates
content = content.replace(/setDisplayTransporterStates\(.*?\);\n?/g, '');
// remove timeMs: ... transporters: ... \};
content = content.replace(/timeMs: performance\.now\(\),\s*transporters: data\.transporters\s*\};\n?/g, '');
// remove let rafId... cancelAnimationFrame
const rafBlock = /\/\/ Interpolate\/extrapolate between polls for smoother motion\s*useEffect\(\(\) => \{\s*let rafId;\s*let lastRef = null;\s*const tick = \(\) => \{\s*if \(snapshot\.transporters !== lastRef\) \{\s*lastRef = snapshot\.transporters;\s*\}\s*rafId = requestAnimationFrame\(tick\);\s*\};\s*rafId = requestAnimationFrame\(tick\);\s*return \(\) => cancelAnimationFrame\(rafId\);\s*\}, \[\]\);\n?/g;
content = content.replace(rafBlock, '');

// Also to fix the malformed block from latestSnapshotRef deletion:
// we had:
//          setDisplayTransporterStates(data.transporters);
//            timeMs: performance.now(),
//            transporters: data.transporters
//          };
//        }
// Need to find this malformed section and fix it.
content = content.replace(/setTransporterStates\(data\.transporters\);\s*timeMs: performance.now\(\),\s*transporters: data\.transporters\s*\};\s*\}/, 'setTransporterStates(data.transporters);\n        }');

fs.writeFileSync('src/App.jsx', content);
