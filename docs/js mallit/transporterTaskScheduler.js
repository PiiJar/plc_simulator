/**
 * TransporterTaskScheduler - V0.1
 * 
 * Laskee erän aikataulun käsittelyohjelman mukaan.
 * Yksinkertaistettu versio: yksi erä, yksi nostin.
 * 
 * @module transporterTaskScheduler
 */

const fs = require('fs');
const path = require('path');



// ═══════════════════════════════════════════════════════════════════════════════
// VAKIOT (PLC-yhteensopivat)
// ═══════════════════════════════════════════════════════════════════════════════

const MAX_BATCHES = 50;
const MAX_STATIONS = 30;

// ═══════════════════════════════════════════════════════════════════════════════
// AIKATAULUTAULUKOT
// ═══════════════════════════════════════════════════════════════════════════════

const schedule = {
    // 2D-taulukot: [batch_idx][station_idx] - ajat sekunteina
    entry_time: Array.from({ length: MAX_BATCHES }, () => new Array(MAX_STATIONS).fill(0)),
    exit_time: Array.from({ length: MAX_BATCHES }, () => new Array(MAX_STATIONS).fill(0)),
    
    // 1D-taulukot: tunnisteet
    batch_ids: new Array(MAX_BATCHES).fill(0),
    station_ids: new Array(MAX_STATIONS).fill(0),
    
    // Laskurit
    batch_count: 0,
    station_count: 0
};

// ═══════════════════════════════════════════════════════════════════════════════
// RINNAKKAISET ASEMAT - APUFUNKTIOT
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Etsi rinnakkaiset asemat stagelle käsittelyohjelman perusteella
 * Rinnakkaiset asemat ovat välillä [MinStat, MaxStat] ja kuuluvat samaan ryhmään (group)
 * 
 * @param {object} programStage - Käsittelyohjelman stage {min_station, max_station}
 * @param {array} stations - Kaikki asemat
 * @returns {array} Rinnakkaiset asemat (sama group kuin min_station, välillä min-max)
 */
function getParallelStations(programStage, stations) {
    const minStat = parseInt(programStage.min_station, 10);
    const maxStat = parseInt(programStage.max_station, 10);
    
    // Tarkista validit arvot
    if (!Number.isFinite(minStat) || !Number.isFinite(maxStat)) {
        return [];
    }
    
    // Jos min == max, ei rinnakkaisia
    if (minStat === maxStat) {
        const station = stations.find(s => s.number === minStat);
        return station ? [station] : [];
    }
    
    // Etsi min_station ja sen group
    const minStation = stations.find(s => s.number === minStat);
    if (!minStation) {
        console.warn(`[PARALLEL] MinStation ${minStat} not found`);
        return [];
    }
    
    const targetGroup = minStation.group;
    
    // Etsi kaikki asemat väliltä [minStat, maxStat] joilla sama group
    const parallelStations = stations.filter(s => 
        s.number >= minStat && 
        s.number <= maxStat && 
        s.group === targetGroup
    );
    
    // Järjestä asemanumeron mukaan
    parallelStations.sort((a, b) => a.number - b.number);
    
    if (parallelStations.length > 1) {
        console.log(`[PARALLEL] Stage MinStat=${minStat} MaxStat=${maxStat} group=${targetGroup}: found ${parallelStations.length} parallel stations: [${parallelStations.map(s => s.number).join(', ')}]`);
    }
    
    return parallelStations;
}

/**
 * Valitse paras rinnakkaisasema kriteerien perusteella:
 * 1. Tarkista linjassa olevien erien AIKATAULUT - onko asema vapaa oikealla ajanhetkellä
 * 2. Jos useampi vapaa, valitaan pisimpään tyhjänä ollut
 * 
 * @param {array} parallelStations - Rinnakkaiset asemat (getParallelStations:n tulos)
 * @param {Set} occupiedStations - Varatut asemat (asemalla on erä NYT)
 * @param {Map} stationIdleSince - Asemien vapautumisajat (stationNumber → simTimeMs)
 * @param {number} currentTimeSec - Nykyinen simulaatioaika sekunteina
 * @param {Object} scheduleContext - Aikataulukonteksti: { lineSchedules, stageNum, entryTime, exitTime }
 * @returns {object} Valittu asema
 */
function selectBestParallelStation(parallelStations, occupiedStations, stationIdleSince, currentTimeSec, scheduleContext) {
    if (!parallelStations || parallelStations.length === 0) {
        return null;
    }
    
    if (parallelStations.length === 1) {
        return parallelStations[0];
    }
    
    const { lineSchedules, stageNum, entryTime, exitTime } = scheduleContext || {};
    
    // DEBUG: Logita rinnakkaisasema-valinta
    console.log(`[PARALLEL-DEBUG] Stage ${stageNum}: parallelStations=[${parallelStations.map(s => s.number).join(',')}], lineSchedules=${lineSchedules?.length || 0}, entry=${entryTime?.toFixed(1)}, exit=${exitTime?.toFixed(1)}`);
    
    // 1. Tarkista mitkä asemat ovat varattuja AIKATAULUJEN perusteella (ei vain nykyisen sijainnin)
    const scheduledOccupied = new Set();
    
    if (lineSchedules && lineSchedules.length > 0 && entryTime !== undefined && exitTime !== undefined) {
        for (const lineSchedule of lineSchedules) {
            if (!lineSchedule?.stages) continue;
            
            for (const lStage of lineSchedule.stages) {
                // Tarkista päällekkäisyys ajassa
                const overlapStart = Math.max(entryTime, lStage.entry_time_s);
                const overlapEnd = Math.min(exitTime, lStage.exit_time_s);
                
                // Tarkista onko tämä asema rinnakkaisasemien joukossa
                const isParallelCandidate = parallelStations.some(s => s.number === lStage.station);
                
                if (overlapEnd > overlapStart && isParallelCandidate) {
                    // Aikapäällekkäisyys rinnakkaisasemalla → tämä asema on varattu
                    console.log(`[PARALLEL-DEBUG] Stage ${stageNum}: Station ${lStage.station} OCCUPIED by B${lineSchedule.batch_id} (overlap ${overlapStart.toFixed(1)}-${overlapEnd.toFixed(1)})`);
                    scheduledOccupied.add(lStage.station);
                }
            }
        }
    }
    
    // 2. Suodata pois asemat jotka ovat varattuja:
    //    - occupiedStations: fyysisesti varattu NYT (erä on asemalla)
    //    - scheduledOccupied: aikataulun mukaan varattu samaan aikaan
    //    Molemmat tarkistukset tarvitaan: fyysinen estää päällekkäisyydet kun
    //    aikataulutietoa ei ole (lineSchedules=0), ja aikataulupohjainen
    //    estää tulevat päällekkäisyydet.
    const freeStations = parallelStations.filter(s => 
        !occupiedStations.has(s.number) && !scheduledOccupied.has(s.number)
    );
    
    if (freeStations.length === 0) {
        // Kokeile pelkällä aikataulupohjaisella (fyysisesti varattu voi vapautua ennen saapumista)
        const freeBySchedule = parallelStations.filter(s => !scheduledOccupied.has(s.number));
        if (freeBySchedule.length > 0) {
            console.log(`[PARALLEL] Stage ${stageNum}: All physically occupied, but ${freeBySchedule.length} schedule-free: [${freeBySchedule.map(s=>s.number).join(',')}] (phys: [${[...occupiedStations].join(',')}], sched: [${[...scheduledOccupied].join(',')}])`);
            // Käytä aikataulupohjaista vapaata asemaa
            const fallback = freeBySchedule[0];
            return fallback;
        }
        // Kaikki varattuja molempien mukaan
        console.log(`[PARALLEL] Stage ${stageNum}: All ${parallelStations.length} parallel stations occupied (phys: [${[...occupiedStations].join(',')}], sched: [${[...scheduledOccupied].join(',')}]), using first: ${parallelStations[0].number}`);
        return parallelStations[0];
    }
    
    if (freeStations.length === 1) {
        console.log(`[PARALLEL] Stage ${stageNum}: Only one free station: ${freeStations[0].number} (phys occupied: [${[...occupiedStations].join(',')}], sched occupied: [${[...scheduledOccupied].join(',')}])`);
        return freeStations[0];
    }
    
    // 3. Valitse pisimpään tyhjänä ollut (pienin stationIdleSince arvo)
    let oldest = freeStations[0];
    let oldestIdleTime = stationIdleSince?.get(oldest.number) ?? 0;  // 0 = ei koskaan käytetty
    
    for (const station of freeStations) {
        const idleTime = stationIdleSince?.get(station.number) ?? 0;
        // Pienempi aika = vapautunut aiemmin = ollut pidempään tyhjänä
        if (idleTime < oldestIdleTime) {
            oldest = station;
            oldestIdleTime = idleTime;
        }
    }
    
    const idleDuration = currentTimeSec - (oldestIdleTime / 1000);
    console.log(`[PARALLEL] Stage ${stageNum}: Selected station ${oldest.number} (idle ${idleDuration.toFixed(1)}s) from ${freeStations.length} schedule-free stations (occupied by schedule: [${[...scheduledOccupied].join(',')}])`);
    
    return oldest;
}

// ═══════════════════════════════════════════════════════════════════════════════
// APUFUNKTIOT
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Laske akselin siirtoaika kiihdytyksellä/jarrutuksella
 * @param {number} distance - Matka (mm)
 * @param {number} maxSpeed - Maksiminopeus (mm/s)
 * @param {number} accelTime - Kiihdytysaika (s)
 * @param {number} decelTime - Jarrutusaika (s)
 * @returns {number} Siirtoaika (s)
 */
function calculateAxisTime(distance, maxSpeed, accelTime, decelTime) {
    if (distance <= 0 || maxSpeed <= 0) return 0;
    if (accelTime <= 0) accelTime = 0.001;
    if (decelTime <= 0) decelTime = 0.001;
    
    // Laske kiihtyvyys/hidastuvuus: a = v_max / t
    const accel = maxSpeed / accelTime;
    const decel = maxSpeed / decelTime;
    
    // Kiihdytyksen aikana kuljettu matka: s = 0.5 * a * t^2 = 0.5 * v_max * t_acc
    const accelDist = 0.5 * accel * accelTime * accelTime;
    const decelDist = 0.5 * decel * decelTime * decelTime;
    
    if (distance < accelDist + decelDist) {
        // Lyhyt matka - kolmioprofiili (ei ehditä täysnopeuteen)
        // Ratkaisu: t_acc = sqrt(2 * d / a) kun symmetrinen
        // Epäsymmetriselle: käytä suhteellista jakoa
        // t_a = sqrt(d * (2*a_d) / (a_a * (a_a + a_d)))
        // t_d = sqrt(d * (2*a_a) / (a_d * (a_a + a_d)))
        // Yksinkertaistettu: skaalaa matkan suhteessa
        const ratio = distance / (accelDist + decelDist);
        // Kolmioprofiilissa: t = sqrt(ratio) * (t_acc + t_dec) kun nopeus skaalautuu
        // Tarkempi fysiikka: v_peak = sqrt(2 * d * a_a * a_d / (a_a + a_d))
        // t_total = v_peak/a_a + v_peak/a_d = v_peak * (a_a + a_d) / (a_a * a_d)
        const sumAccel = accel + decel;
        const vPeak = Math.sqrt(2 * distance * accel * decel / sumAccel);
        const tAccel = vPeak / accel;
        const tDecel = vPeak / decel;
        return tAccel + tDecel;
    } else {
        // Normaali trapetsiprofiili: kiihdytys + tasainen + jarrutus
        const cruiseDist = distance - accelDist - decelDist;
        const cruiseTime = cruiseDist / maxSpeed;
        return accelTime + cruiseTime + decelTime;
    }
}

/**
 * Tarkista onko asema märkä
 * @param {number} stationKind - Aseman kind (0=dry, 1=wet)
 * @returns {boolean} true jos märkä
 */
function isWetStation(stationKind) {
    return stationKind === 1;
}

/**
 * Tarkista onko asema poikittaissiirtokuljetin
 * @param {number} stationOp - Aseman operation
 * @returns {boolean} true jos poikittaissiirtokuljetin (operation 10)
 */
function isCrossTransporterOp(stationOp) {
    return stationOp === 10;
}

/**
 * Etsi poikittaissiirtokuljettimen "toinen pää" - samaan ryhmään kuuluva asema toisella linjalla.
 * 
 * Käytetään kun nostoasema ja laskuasema ovat eri linjoilla JA nostoasema on tyyppiä 10/11.
 * Palauttaa aseman, joka on samassa group:ssa kuin nostoasema mutta samalla linjalla (y_position) 
 * kuin laskuasema.
 * 
 * @param {object} liftStation - Nostoasema (tyyppiä 10 tai 11)
 * @param {object} sinkStation - Laskuasema (eri linjalla)
 * @param {array} stations - Kaikki asemat
 * @returns {object|null} Löydetty "toinen pää" -asema tai null jos ei löydy
 */
function findCrossTransporterEndStation(liftStation, sinkStation, stations) {
    if (!liftStation || !sinkStation || !stations || stations.length === 0) {
        return null;
    }
    
    const liftOp = liftStation.operation;
    
    // Tarkista että nostoasema on poikittaissiirtokuljetin
    if (!isCrossTransporterOp(liftOp)) {
        return null;
    }
    
    const liftY = liftStation.y_position || 0;
    const sinkY = sinkStation.y_position || 0;
    
    // Tarkista että asemat ovat eri linjoilla (eri y_position)
    if (liftY === sinkY) {
        return null;
    }
    
    const liftGroup = liftStation.group;
    
    // Etsi samaan ryhmään kuuluvat asemat, jotka ovat tyyppiä 10/11 ja samalla linjalla kuin laskuasema
    const candidates = stations.filter(s => 
        s.group === liftGroup &&                           // Sama ryhmä
        s.number !== liftStation.number &&                  // Ei sama asema
        isCrossTransporterOp(s.operation) &&                   // Myös poikittaissiirtokuljetin
        (s.y_position || 0) === sinkY                       // Samalla linjalla kuin laskuasema
    );
    
    if (candidates.length === 0) {
        console.log(`[CROSS-TRANSPORTER] No matching end station found for group=${liftGroup} on line y=${sinkY}`);
        return null;
    }
    
    if (candidates.length === 1) {
        console.log(`[CROSS-TRANSPORTER] Found end station ${candidates[0].number} for lift=${liftStation.number} (group=${liftGroup})`);
        return candidates[0];
    }
    
    // Jos useampia vaihtoehtoja, valitse lähinnä laskuasemaa oleva (x_position)
    candidates.sort((a, b) => {
        const distA = Math.abs((a.x_position || 0) - (sinkStation.x_position || 0));
        const distB = Math.abs((b.x_position || 0) - (sinkStation.x_position || 0));
        return distA - distB;
    });
    
    console.log(`[CROSS-TRANSPORTER] Found ${candidates.length} candidates for group=${liftGroup}, selected ${candidates[0].number} (closest to sink=${sinkStation.number})`);
    return candidates[0];
}

/**
 * Laske 2D-nostimen nostoaika
 * @param {number} stationKind - Aseman kind (0=dry, 1=wet)
 * @param {object} physics - Nostimen fysiikkaparametrit
 * @returns {number} Nostoaika (s)
 */
function calculateLiftTime2D(stationKind, physics) {
    const zTotal = physics.z_total_distance_mm || 1200;
    const zSlowDry = physics.z_slow_distance_dry_mm || 300;
    const zSlowWet = physics.z_slow_distance_wet_mm || 800;
    const zSlowEnd = physics.z_slow_end_distance_mm || 50;
    const zSlowSpeed = physics.z_slow_speed_mm_s || 50;
    const zFastSpeed = physics.z_fast_speed_mm_s || 200;
    
    const slowStart = (stationKind === 1) ? zSlowWet : zSlowDry;
    const slowEndStart = zTotal - zSlowEnd;
    
    const tSlowUp = slowStart / zSlowSpeed;
    const tFastUp = Math.max(0, slowEndStart - slowStart) / zFastSpeed;
    const tSlowTop = zSlowEnd / zSlowSpeed;
    
    return tSlowUp + tFastUp + tSlowTop;
}

/**
 * Laske 2D-nostimen laskuaika
 * @param {number} stationKind - Aseman kind (0=dry, 1=wet)
 * @param {object} physics - Nostimen fysiikkaparametrit
 * @returns {number} Laskuaika (s)
 */
function calculateSinkTime2D(stationKind, physics) {
    const zTotal = physics.z_total_distance_mm || 1200;
    const zSlowDry = physics.z_slow_distance_dry_mm || 300;
    const zSlowWet = physics.z_slow_distance_wet_mm || 800;
    const zSlowSpeed = physics.z_slow_speed_mm_s || 50;
    const zFastSpeed = physics.z_fast_speed_mm_s || 200;
    
    const slowStart = (stationKind === 1) ? zSlowWet : zSlowDry;
    
    const tFastDown = Math.max(0, zTotal - slowStart) / zFastSpeed;
    const tSlowDown = slowStart / zSlowSpeed;
    
    return tFastDown + tSlowDown;
}

/**
 * Laske 3D-nostimen nostoaika (2D3z ja 3D käyttävät tätä)
 * 
 * Sekvenssi spesifikaation mukaan:
 * 1. device_delay (lisätään erikseen calculateTransferTime:ssa)
 * 2. drip_tray_delay (lisätään erikseen)
 * 3. Fast down: z_idle → z_slow_end
 * 4. Slow down: z_slow_end → 0
 * 5. catcher_delay
 * 6. Slow up: 0 → z_speed_change_limit (wet/dry)
 * 7. Fast up: z_speed_change_limit → (z_total - z_slow_end)
 * 8. Slow up: (z_total - z_slow_end) → z_total
 * 9. dropping_time (lisätään erikseen)
 * 10. drip_tray_delay (close drip tray - lisätään erikseen)
 * 
 * @param {number} stationKind - Aseman kind (0=dry, 1=wet)
 * @param {object} physics - Nostimen fysiikkaparametrit (physics_3D)
 * @returns {number} Z-liikkeen aika (s) - ilman device_delay, drip_tray_delay, dropping_time
 */
function calculateLiftTime3D(stationKind, physics) {
    const zTotal = physics.z_total_distance_mm || 4000;
    const zIdle = physics.z_idle_height_mm || 100;
    const zSlowEnd = physics.z_slow_end_distance_mm || 50;
    const zSpeedChangeLimitDry = physics.z_speed_change_limit_dry_mm || 300;
    const zSpeedChangeLimitWet = physics.z_speed_change_limit_wet_mm || 800;
    const zSlowSpeed = physics.z_slow_speed_mm_s || 50;
    const zFastSpeed = physics.z_fast_speed_mm_s || 200;
    const catcherDelay = physics.catcher_delay_s || 0;
    
    // Valitse speed change limit aseman kind:n mukaan
    const zSpeedChangeLimit = (stationKind === 1) ? zSpeedChangeLimitWet : zSpeedChangeLimitDry;
    
    // 3. Fast down: z_idle → z_slow_end
    const fastDown = Math.max(0, zIdle - zSlowEnd) / Math.max(zFastSpeed, 1e-6);
    
    // 4. Slow down: z_slow_end → 0
    const slowDown = zSlowEnd / Math.max(zSlowSpeed, 1e-6);
    
    // 6. Slow up: 0 → z_speed_change_limit
    const slowUp1 = zSpeedChangeLimit / Math.max(zSlowSpeed, 1e-6);
    
    // 7. Fast up: z_speed_change_limit → (z_total - z_slow_end)
    const fastUp = Math.max(0, zTotal - zSpeedChangeLimit - zSlowEnd) / Math.max(zFastSpeed, 1e-6);
    
    // 8. Slow up: (z_total - z_slow_end) → z_total
    const slowUp2 = zSlowEnd / Math.max(zSlowSpeed, 1e-6);
    
    return fastDown + slowDown + catcherDelay + slowUp1 + fastUp + slowUp2;
}

/**
 * Laske 3D-nostimen laskuaika (2D3z ja 3D käyttävät tätä)
 * 
 * Sekvenssi spesifikaation mukaan:
 * 1. device_delay (lisätään erikseen)
 * 2. drip_tray_delay (lisätään erikseen)
 * 3. Fast down: z_total → z_speed_change_limit
 * 4. Slow down: z_speed_change_limit → 0
 * 5. catcher_delay
 * 6. Fast up: 0 → z_idle
 * 7. drip_tray_delay (close drip tray - lisätään erikseen)
 * 
 * @param {number} stationKind - Aseman kind (0=dry, 1=wet)
 * @param {object} physics - Nostimen fysiikkaparametrit (physics_3D)
 * @returns {number} Z-liikkeen aika (s) - ilman device_delay, drip_tray_delay
 */
function calculateSinkTime3D(stationKind, physics) {
    const zTotal = physics.z_total_distance_mm || 4000;
    const zIdle = physics.z_idle_height_mm || 100;
    const zSpeedChangeLimitDry = physics.z_speed_change_limit_dry_mm || 300;
    const zSpeedChangeLimitWet = physics.z_speed_change_limit_wet_mm || 800;
    const zSlowSpeed = physics.z_slow_speed_mm_s || 50;
    const zFastSpeed = physics.z_fast_speed_mm_s || 200;
    const catcherDelay = physics.catcher_delay_s || 0;
    
    // Valitse speed change limit aseman kind:n mukaan
    const zSpeedChangeLimit = (stationKind === 1) ? zSpeedChangeLimitWet : zSpeedChangeLimitDry;
    
    // 3. Fast down: z_total → z_speed_change_limit
    const fastDown = Math.max(0, zTotal - zSpeedChangeLimit) / Math.max(zFastSpeed, 1e-6);
    
    // 4. Slow down: z_speed_change_limit → 0
    const slowDown = zSpeedChangeLimit / Math.max(zSlowSpeed, 1e-6);
    
    // 6. Fast up: 0 → z_idle
    const fastUp = zIdle / Math.max(zFastSpeed, 1e-6);
    
    return fastDown + slowDown + catcherDelay + fastUp;
}

/**
 * Laske täysi siirtoaika asemalta asemalle
 * @param {object} fromStation - Lähtöasema
 * @param {object} toStation - Kohdeasema
 * @param {object} transporter - Nostin (sisältää physics_2D/3D)
 * @returns {object} Siirtoajan erittely
 */
function calculateTransferTime(fromStation, toStation, transporter, movementTimes = null) {
    // Optional fast-path: use precomputed movement-only timing table (line 100, 2D).
    // Falls back to dynamic calculation if lookup is missing.
    try {
        const transporterId = transporter && transporter.id != null ? String(transporter.id) : null;
        const fromNum = fromStation && fromStation.number != null ? String(fromStation.number) : null;
        const toNum = toStation && toStation.number != null ? String(toStation.number) : null;

        if (
            movementTimes &&
            transporter &&
            transporter.model === '2D' &&
            transporterId &&
            fromNum &&
            toNum
        ) {
            const tTimes = movementTimes.transporters && movementTimes.transporters[transporterId];

            // New format: lift_s + travel_s + sink_s
            let p2 = NaN;
            let p3 = NaN;
            let p4 = NaN;
            if (tTimes && tTimes.lift_s && tTimes.sink_s && tTimes.travel_s) {
                // Esilasketut movement_times: lisää dropping_time ja drip_tray_delay mukaan
                // HUOM: Nostoaseman device_delay (kannet) EI lisätä phase2:een,
                // koska kannet avataan nostoasemalla käsittelyajan aikana (menee päällekkäin).
                // Laskuaseman device_delay lisätään phase4:ään, koska kannet avataan vasta nostimen saavuttua.
                const fromDroppingTime = fromStation.dropping_time || 0;
                const toDeviceDelay = toStation.device_delay || 0;
                // drip_tray_delay lisätään SEKÄ nostoon (phase2) ETTÄ laskuun (phase4)
                const dripDelay = transporter.physics_2D?.drip_tray_delay_s || 5.0;
                p2 = Number(tTimes.lift_s[fromNum]) + fromDroppingTime + dripDelay;
                p3 = tTimes.travel_s[fromNum] ? Number(tTimes.travel_s[fromNum][toNum]) : NaN;
                p4 = Number(tTimes.sink_s[toNum]) + dripDelay + toDeviceDelay;
            }

            // Legacy format: phase_2 + phase_3 + phase_4
            if (!(Number.isFinite(p2) && Number.isFinite(p3) && Number.isFinite(p4))) {
                p2 = tTimes && tTimes.phase_2 ? Number(tTimes.phase_2[fromNum]) : NaN;
                p3 = tTimes && tTimes.phase_3 && tTimes.phase_3[fromNum] ? Number(tTimes.phase_3[fromNum][toNum]) : NaN;
                p4 = tTimes && tTimes.phase_4 ? Number(tTimes.phase_4[toNum]) : NaN;
            }

            if (Number.isFinite(p2) && Number.isFinite(p3) && Number.isFinite(p4)) {
                const total = p2 + p3 + p4;
                const xDistance = Math.abs((toStation.x_position || 0) - (fromStation.x_position || 0));

                return {
                    total_s: total,
                    phase2_lift_s: p2,
                    phase3_travel_s: p3,
                    phase3_x_travel_s: p3,
                    phase3_y_travel_s: 0,
                    phase4_sink_s: p4,
                    details: {
                        source: 'precomputed_movement_times',
                        // keep legacy keys so debug/printing does not crash
                        fromDeviceDelay: 0,
                        liftTime: p2,
                        fromDroppingTime: 0,
                        dripDelay: 0,
                        xDistance,
                        xTime: p3,
                        toDeviceDelay: 0,
                        sinkTime: p4
                    }
                };
            }
        }
    } catch (_) {
        // ignore and fall back
    }

    // Valitse fysiikkaparametrit nostimen mallin mukaan
    const model = transporter.model || '2D';
    const is3D = model === '3D' || model === '2D3z';
    const physics = is3D ? (transporter.physics_3D || transporter.physics_2D || {}) : (transporter.physics_2D || {});
    
    // X-akselin parametrit
    const xAccelTime = physics.x_acceleration_time_s || 2.0;
    const xDecelTime = physics.x_deceleration_time_s || 2.0;
    const xMaxSpeed = physics.x_max_speed_mm_s || 300;
    const dripDelay = physics.drip_tray_delay_s || 5.0;
    
    // Y-akselin parametrit (vain 3D-nostimille)
    const yAccelTime = physics.y_acceleration_time_s || 2.0;
    const yDecelTime = physics.y_deceleration_time_s || 2.0;
    const yMaxSpeed = physics.y_max_speed_mm_s || 300;
    
    // 1. NOSTO
    // HUOM: Nostoaseman device_delay (kannet) EI lisätä phase2:een,
    // koska kannet avataan nostoasemalla käsittelyajan aikana (menee päällekkäin).
    const fromKind = Number(fromStation.kind) || 0;
    const fromDroppingTime = fromStation.dropping_time || 0;
    
    // Valitse nostoajan laskenta mallin mukaan
    const liftTime = is3D 
        ? calculateLiftTime3D(fromKind, physics) 
        : calculateLiftTime2D(fromKind, physics);
    
    // 3D-nostimella drip_tray_delay lisätään sekä alkuun että loppuun
    const phase2 = is3D
        ? dripDelay + liftTime + fromDroppingTime + dripDelay
        : liftTime + fromDroppingTime + dripDelay;
    
    console.log(`[PHASE2-SCHED] Station=${fromStation.number} kind=${fromKind} model=${model} lift=${liftTime.toFixed(1)}s dropping=${fromDroppingTime}s drip=${dripDelay}s TOTAL=${phase2.toFixed(1)}s (device_delay overlaps with treatment)`);
    
    // 2. VAAKASIIRTO (X-akseli)
    const xDistance = Math.abs((toStation.x_position || 0) - (fromStation.x_position || 0));
    const xTime = calculateAxisTime(xDistance, xMaxSpeed, xAccelTime, xDecelTime);
    
    // Y-akseli (3D-nostimille)
    const yDistance = Math.abs((toStation.y_position || 0) - (fromStation.y_position || 0));
    const yTime = is3D ? calculateAxisTime(yDistance, yMaxSpeed, yAccelTime, yDecelTime) : 0;
    
    // X ja Y liikkeet tapahtuvat samanaikaisesti, joten kokonaisaika on pidempi kahdesta
    const phase3 = Math.max(xTime, yTime);
    
    // 3. LASKU
    // HUOM: Tippakouru (drip_tray) avataan MYÖS ennen laskua, samoin kuin ennen nostoa
    // Simulaatiossa: z_stage = 'drip_tray_delay_sink', z_timer = dripTrayDelay
    const toKind = Number(toStation.kind) || 0;
    const toDeviceDelay = toStation.device_delay || 0;
    
    // Valitse laskuajan laskenta mallin mukaan
    const sinkTime = is3D
        ? calculateSinkTime3D(toKind, physics)
        : calculateSinkTime2D(toKind, physics);
    
    // phase4 = tippakouru auki + device_delay + varsinainen lasku
    const phase4 = dripDelay + toDeviceDelay + sinkTime;
    
    // Kokonaisaika
    const total = phase2 + phase3 + phase4;
    
    console.log(`[CALC-TRANSFER] ${fromStation.number}→${toStation.number}: phase2=${phase2.toFixed(1)}s phase3=${phase3.toFixed(1)}s phase4=${phase4.toFixed(1)}s (drip=${dripDelay}s) TOTAL=${total.toFixed(1)}s`);
    
    return {
        total_s: total,
        phase2_lift_s: phase2,
        phase3_travel_s: phase3,
        phase3_x_travel_s: xTime,
        phase3_y_travel_s: yTime,
        phase4_sink_s: phase4,
        // Erittely debuggausta varten
        details: {
            model,
            fromDeviceDelay,
            liftTime,
            fromDroppingTime,
            dripDelay,
            xDistance,
            xTime,
            yDistance,
            yTime,
            toDeviceDelay,
            sinkTime
        }
    };
}

/**
 * Laske siirtoaika poikittaissiirtokuljettimen huomioiden.
 * 
 * Jos nostoasema ja laskuasema ovat eri linjoilla JA nostoasema on tyyppiä 10/11:
 * 1. Etsitään poikittaissiirtokuljettimen "toinen pää" (samalla linjalla kuin laskuasema)
 * 2. Siirtoaika lasketaan tuosta toisesta päästä laskuasemaan
 * 3. Palautetaan myös tieto crossEndStation:sta (käytetään nostinvalinnassa)
 * 
 * @param {object} fromStation - Nostoasema
 * @param {object} toStation - Laskuasema
 * @param {object} transporter - Nostin
 * @param {array} stations - Kaikki asemat (tarvitaan toisen pään etsintään)
 * @param {object} movementTimes - Esilasketut siirtoajat (optional)
 * @returns {object} { transferTime, crossEndStation, isCrossTransfer }
 */
function calculateTransferTimeWithCrossCheck(fromStation, toStation, transporter, stations, movementTimes = null) {
    const result = {
        transferTime: { total_s: 0, details: null },
        crossEndStation: null,
        isCrossTransfer: false
    };
    
    if (!fromStation || !toStation) {
        return result;
    }
    
    // Sama asema - ei siirtoa
    if (fromStation.number === toStation.number) {
        return result;
    }
    
    // Tarkista onko kyseessä poikittaissiirto
    const crossEndStation = findCrossTransporterEndStation(fromStation, toStation, stations);
    
    if (crossEndStation) {
        // Poikittaissiirto: laske siirtoaika toisesta päästä laskuasemaan
        console.log(`[CROSS-TRANSFER] ${fromStation.number}→${toStation.number} via cross-transporter: using ${crossEndStation.number}→${toStation.number} for transfer time`);
        
        result.crossEndStation = crossEndStation;
        result.isCrossTransfer = true;
        result.transferTime = calculateTransferTime(crossEndStation, toStation, transporter, movementTimes);
        
        // Lisää tieto poikittaissiirrosta detaileihin
        if (result.transferTime.details) {
            result.transferTime.details.crossTransfer = true;
            result.transferTime.details.crossEndStation = crossEndStation.number;
            result.transferTime.details.originalLiftStation = fromStation.number;
        }
    } else {
        // Normaali siirto samalla linjalla
        result.transferTime = calculateTransferTime(fromStation, toStation, transporter, movementTimes);
    }
    
    return result;
}

/**
 * Laske pelkkä vaakasiirtoaika (nostin jo ylhäällä, ei Z-liikettä)
 * @param {object} fromStation - Lähtöasema
 * @param {object} toStation - Kohdeasema
 * @param {object} transporter - Nostin
 * @returns {number} Siirtoaika sekunteina
 */
function calculateHorizontalTravelTime(fromStation, toStation, transporter) {
    if (!fromStation || !toStation) return 0;
    
    const physics = transporter.physics_2D || {};
    const xDistance = Math.abs((toStation.x_position || 0) - (fromStation.x_position || 0));
    const xMaxSpeed = physics.x_max_speed_mm_s || 300;
    const xAccelTime = physics.x_acceleration_time_s || 2.0;
    const xDecelTime = physics.x_deceleration_time_s || 2.0;
    
    return calculateAxisTime(xDistance, xMaxSpeed, xAccelTime, xDecelTime);
}

/**
 * Hakee esilasketun vaakasiirtoajan (tyhjänä siirtyminen konfliktintunnistukseen)
 * Käyttää esilaskettuja travel_s[from][to] arvoja jos saatavilla,
 * muuten laskee calculateHorizontalTravelTime():lla.
 * 
 * HUOM: Tyhjänä siirtymisessä EI tarvita device_delay, dropping_time tai drip_tray_delay,
 * koska nosturi ei nosta/laske erää - se vain siirtyy asemalta toiselle.
 * 
 * @param {object} fromStation - Lähtöasema
 * @param {object} toStation - Kohdeasema
 * @param {object} transporter - Nostin
 * @param {object} movementTimes - Esilasketut siirtoajat (movement_times.json)
 * @returns {number} Siirtoaika sekunteina
 */
function getPrecomputedTravelTime(fromStation, toStation, transporter, movementTimes = null) {
    if (!fromStation || !toStation) return 0;
    
    // Yritä hakea esilaskettu arvo
    if (movementTimes && transporter) {
        const transporterId = String(transporter.id);
        const fromNum = String(fromStation.number);
        const toNum = String(toStation.number);
        
        const tTimes = movementTimes.transporters?.[transporterId];
        if (tTimes?.travel_s?.[fromNum]?.[toNum] != null) {
            const travelTime = Number(tTimes.travel_s[fromNum][toNum]);
            if (Number.isFinite(travelTime)) {
                return travelTime;
            }
        }
    }
    
    // Fallback: laske dynaamisesti
    return calculateHorizontalTravelTime(fromStation, toStation, transporter);
}

/**
 * Vaihtaa sama-asema-tehtävien järjestyksen (swap)
 * 
 * Jos nostin laskee erän asemalle ja seuraava tehtävä on nostaa eri erä
 * samalta asemalta, järjestys vaihdetaan: nosto ensin, lasku sitten.
 * 
 * @param {Array} tasks - Tehtävälista (muokataan in-place)
 * @returns {object} Tulokset: { swapCount }
 */
function swapSameStationTasks(tasks) {
    if (!tasks || tasks.length === 0) {
        return { swapCount: 0 };
    }
    
    let swapCount = 0;
    
    // Käy läpi nostimittain
    const transporterIds = [...new Set(tasks.map(t => t.transporter_id))];
    
    for (const transporterId of transporterIds) {
        if (transporterId === null) continue;
        
        // Hae nostimen tehtävät ja järjestä alkuajan mukaan
        const transporterTasks = tasks
            .filter(t => t.transporter_id === transporterId)
            .sort((a, b) => a.task_start_time - b.task_start_time);
        
        // Käy läpi parit
        for (let i = 0; i < transporterTasks.length - 1; i++) {
            let prevTask = transporterTasks[i];
            let nextTask = transporterTasks[i + 1];
            
            // Tarkista sama-asema-tilanne: prev laskee samalle asemalle mistä next nostaa
            if (prevTask.batch_id !== nextTask.batch_id &&
                prevTask.sink_station_id === nextTask.lift_station_id) {
                
                swapCount++;
                console.log(`[swapSameStationTasks] SWAP: T${transporterId} B${prevTask.batch_id} sink@${prevTask.sink_station_id} ⇄ B${nextTask.batch_id} lift@${nextTask.lift_station_id}`);

                // ═══════════════════════════════════════════════════════════════
                // SWAP VAIN JÄRJESTYS - validateTaskTiming hoitaa aikojen korjauksen
                // ═══════════════════════════════════════════════════════════════

                // Swap paikallisessa listassa (jotta seuraava iteraatio käyttää oikeaa järjestystä)
                [transporterTasks[i], transporterTasks[i + 1]] = [transporterTasks[i + 1], transporterTasks[i]];

                // Swap myös alkuperäisessä tasks-taulukossa
                const globalPrevIdx = tasks.indexOf(prevTask);
                const globalNextIdx = tasks.indexOf(nextTask);
                if (globalPrevIdx !== -1 && globalNextIdx !== -1) {
                    [tasks[globalPrevIdx], tasks[globalNextIdx]] = [tasks[globalNextIdx], tasks[globalPrevIdx]];
                }
                
                // Päivitä viittaukset swapin jälkeen seuraavaa iteraatiota varten
                prevTask = transporterTasks[i];
                nextTask = transporterTasks[i + 1];
            }
        }
    }
    
    return { swapCount };
}

/**
 * Analysoi tehtävälistan konfliktit ja joustovarat (EI MUUTA MITÄÄN)
 * 
 * Käy läpi tehtäväparit nostimittain ja kerää:
 * - Konfliktit (nostin ei ehdi siirtyä)
 * - Joustovarat (calc-min alas, max-calc ylös)
 * - Kokonaiskuva optimointipäätöksiä varten
 * 
 * @param {Array} tasks - Tehtävälista (EI muokata)
 * @param {Array} batches - Erälista (EI muokata)
 * @param {Array} transporters - Nostimet
 * @param {Array} stations - Asemat
 * @returns {object} Analyysi: { conflicts, summary }
 */
/**
 * Analysoi tehtäväkonfliktiit globaalissa aikajärjestyksessä.
 * 
 * UUDISTETTU VERSIO (v3.4):
 * - Globaali tehtäväjärjestys (kaikki nostimet yhdessä)
 * - Pysähtyy heti ensimmäisen konfliktin löytyessä
 * - Kerää checkedTasks-listan joustovaroineen ratkaisua varten
 * - Tukee kahta konfliktityyppiä: TASK_SEQUENCE ja TRANSPORTER_COLLISION
 * 
 * @param {Array} tasks - Tehtävälista
 * @param {Array} batches - Erälista (käytetään flex-laskentaan)
 * @param {Array} transporters - Nostimet (X-alueet, nopeudet)
 * @param {Array} stations - Asemat (X-koordinaatit)
 * @param {Object} options - Optiot: movementTimes, conflictMarginSec, debug
 * @returns {Object} { hasConflict, checkedTasks, conflict }
 */
function analyzeTaskConflicts(tasks, batches, transporters, stations, options = {}) {
    // Tyhjä lista → ei konflikteja
    if (!tasks || tasks.length === 0) {
        return { 
            hasConflict: false, 
            checkedTasks: [], 
            conflict: null 
        };
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // 1. KÄYTÄ ANNETTUA JÄRJESTYSTÄ SELLAISENAAN
    //    SWAP (phase 6003) on jo järjestänyt tehtävät oikein (nosto ennen laskua).
    //    EI SAA järjestää uudelleen task_start_time mukaan - se kumoaisi SWAP:n.
    // ═══════════════════════════════════════════════════════════════════════════════
    const sortedTasks = [...tasks]
        .filter(t => t.transporter_id !== null);
    
    // DEBUG: Näytä suodatuksen tulos
    const nullCount = tasks.filter(t => t.transporter_id === null).length;
    if (nullCount > 0) {
        console.log(`[ANALYZE-BUG] WARNING: ${nullCount}/${tasks.length} tasks have transporter_id=null and are FILTERED OUT!`);
    }
    console.log(`[ANALYZE-DEBUG] Input: ${tasks.length} tasks, After filter: ${sortedTasks.length} tasks`);
    
    if (sortedTasks.length === 0) {
        return { hasConflict: false, checkedTasks: [], conflict: null };
    }
    
    // DEBUG: Näytä tehtävien jakautuminen (jos pyydetty)
    if (options.debugOnce) {
        const transporterIds = [...new Set(sortedTasks.map(t => t.transporter_id))];
        console.log(`[ANALYZE-DEBUG] transporterIds: [${transporterIds.map(id => 'T'+id).join(', ')}]`);
        console.log(`[ANALYZE-DEBUG] Globaali järjestys: ${sortedTasks.length} tehtävää`);
        for (const t of sortedTasks.slice(0, 10)) {
            console.log(`[ANALYZE-DEBUG]   B${t.batch_id}s${t.stage} T${t.transporter_id}: ${t.task_start_time?.toFixed(1)}s - ${t.task_finished_time?.toFixed(1)}s`);
        }
    }
    
    // Luo hakutaulut
    const batchById = new Map();
    for (const b of (Array.isArray(batches) ? batches : [])) {
        const id = Number(b && b.batch_id);
        if (Number.isFinite(id)) batchById.set(id, b);
    }
    
    const transporterById = new Map();
    for (const t of transporters) {
        transporterById.set(t.id, t);
    }
    
    // Luo nostinkohtaiset tehtävälistat (edellinen tehtävä -hakuun)
    // ═══════════════════════════════════════════════════════════════════════════════
    // KRIITTINEN: EI SAA JÄRJESTÄÄ AIKAJÄRJESTYKSEEN!
    // SWAP-vaihe (6003) on jo järjestänyt tehtävät oikein (nosto ennen laskua).
    // Aikajärjestys kumoaisi SWAP:n työn ja aiheuttaisi vääriä konflikteja.
    // ═══════════════════════════════════════════════════════════════════════════════
    const tasksByTransporter = new Map();
    for (const t of sortedTasks) {
        if (!tasksByTransporter.has(t.transporter_id)) {
            tasksByTransporter.set(t.transporter_id, []);
        }
        tasksByTransporter.get(t.transporter_id).push(t);
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // 2. checkedTasks-LISTA: Kerätään tarkastetut tehtävät joustovaroineen
    // ═══════════════════════════════════════════════════════════════════════════════
    const checkedTasks = [];
    const DEFICIT_TOLERANCE = 1.0; // 1s toleranssi
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // 3. KÄYDÄÄN LÄPI TEHTÄVÄT AIKAJÄRJESTYKSESSÄ
    // ═══════════════════════════════════════════════════════════════════════════════
    for (let i = 0; i < sortedTasks.length; i++) {
        const currentTask = sortedTasks[i];
        const transporter = transporterById.get(currentTask.transporter_id);
        if (!transporter) continue;
        
        // Hae asemien X-koordinaatit tehtävän X-alueen laskentaa varten
        const liftStation = findStation(currentTask.lift_station_id, stations);
        const sinkStation = findStation(currentTask.sink_station_id, stations);
        const x_min = Math.min(
            liftStation?.x_position_mm ?? 0, 
            sinkStation?.x_position_mm ?? 0
        );
        const x_max = Math.max(
            liftStation?.x_position_mm ?? 0, 
            sinkStation?.x_position_mm ?? 0
        );
        
        // ═══════════════════════════════════════════════════════════════════════════════
        // 4. JOUSTOVAROJEN LASKENTA (GLOBAALI)
        //    theory_flex = tehtävän oma jousto
        //    gap = etäisyys edelliseen/seuraavaan tehtävään AIKAJANALLA (kaikki erät)
        //    todellinen flex = min(theory, gap)
        // ═══════════════════════════════════════════════════════════════════════════════
        const calc_time = currentTask.calc_time_s || 0;
        const min_time = currentTask.min_time_s || 0;
        const max_time = currentTask.max_time_s || 0;
        const theory_flex_down = Math.max(0, calc_time - min_time);
        const theory_flex_up = Math.max(0, max_time - calc_time);
        
        // Gap edelliseen tehtävään AIKAJANALLA (mikä tahansa erä)
        let gap_to_prev = Infinity;
        if (i > 0) {
            const prevOnTimeline = sortedTasks[i - 1];
            gap_to_prev = currentTask.task_start_time - prevOnTimeline.task_finished_time;
        }
        
        // Gap seuraavaan tehtävään AIKAJANALLA (mikä tahansa erä)
        let gap_to_next = Infinity;
        if (i < sortedTasks.length - 1) {
            const nextOnTimeline = sortedTasks[i + 1];
            gap_to_next = nextOnTimeline.task_start_time - currentTask.task_finished_time;
        }
        
        // Todellinen jousto = min(teoria, gap)
        const flex_down = Math.max(0, Math.min(theory_flex_down, gap_to_prev));
        const flex_up = Math.max(0, Math.min(theory_flex_up, gap_to_next));
        
        // ═══════════════════════════════════════════════════════════════════════════════
        // 4b. LISÄÄ TEHTÄVÄ checkedTasks:iin HETI (kaikki tehtävät konfliktiin asti)
        // ═══════════════════════════════════════════════════════════════════════════════
        const task_key = `B${currentTask.batch_id}_s${currentTask.stage}`;
        checkedTasks.push({
            task_key: task_key,
            batch_id: currentTask.batch_id,
            stage: currentTask.stage,
            transporter_id: currentTask.transporter_id,
            start_time: currentTask.task_start_time,
            end_time: currentTask.task_finished_time,
            flex_down: flex_down,
            flex_up: flex_up,
            x_min: x_min,
            x_max: x_max,
            theory_flex_down: theory_flex_down,
            theory_flex_up: theory_flex_up,
            gap_to_prev: gap_to_prev,
            gap_to_next: gap_to_next,
            isConflict: false  // Merkitään ei-konfliktoivaksi (päivitetään myöhemmin jos konflikti)
        });
        
        // ═══════════════════════════════════════════════════════════════════════════════
        // 5. TASK_SEQUENCE TARKISTUS: Sama nostin, ehtiikö edelliseltä tehtävältä?
        // ═══════════════════════════════════════════════════════════════════════════════
        const transporterTasks = tasksByTransporter.get(currentTask.transporter_id);
        const taskIndexInTransporter = transporterTasks.findIndex(t => 
            t.batch_id === currentTask.batch_id && t.stage === currentTask.stage
        );
        
        if (taskIndexInTransporter > 0) {
            const prevTaskSameTransporter = transporterTasks[taskIndexInTransporter - 1];
            
            // Hae siirtymäaika
            const fromStation = findStation(prevTaskSameTransporter.sink_station_id, stations);
            const toStation = findStation(currentTask.lift_station_id, stations);
            
            if (fromStation && toStation) {
                const movementTimes = options?.movementTimes || null;
                const baseTravelTime = getPrecomputedTravelTime(fromStation, toStation, transporter, movementTimes);
                const marginSec = options?.conflictMarginSec ?? 0;
                const travelTime = baseTravelTime + marginSec;
                
                // Tarkista väli
                const availableGap = currentTask.task_start_time - prevTaskSameTransporter.task_finished_time;
                const deficit = travelTime - availableGap;
                
                // DEBUG: Logita eri erien parit
                if (prevTaskSameTransporter.batch_id !== currentTask.batch_id && options.debug) {
                    console.log(`[CONFLICT-CHECK] T${currentTask.transporter_id}: B${prevTaskSameTransporter.batch_id}s${prevTaskSameTransporter.stage} → B${currentTask.batch_id}s${currentTask.stage}: gap=${availableGap.toFixed(1)}s, travel=${travelTime.toFixed(1)}s, deficit=${deficit.toFixed(1)}s`);
                }
                
                // KONFLIKTI LÖYTYI → pysähdy ja palauta heti
                if (deficit > DEFICIT_TOLERANCE) {
                    const task_key = `B${currentTask.batch_id}_s${currentTask.stage}`;
                    const blocked_by = `B${prevTaskSameTransporter.batch_id}_s${prevTaskSameTransporter.stage}`;
                    
                    console.log(`[ANALYZE] TASK_SEQUENCE KONFLIKTI: ${task_key} estetty (${blocked_by}), deficit=${deficit.toFixed(1)}s`);
                    console.log(`[ANALYZE]   prev: ${blocked_by} end=${prevTaskSameTransporter.task_finished_time.toFixed(1)}s`);
                    console.log(`[ANALYZE]   curr: ${task_key} start=${currentTask.task_start_time.toFixed(1)}s`);
                    console.log(`[ANALYZE]   gap=${availableGap.toFixed(1)}s, travel=${travelTime.toFixed(1)}s → deficit=${deficit.toFixed(1)}s`);
                    
                    // Merkitse viimeinen tehtävä (juuri lisätty kohdassa 4b) konfliktiksi
                    const lastCheckedTask = checkedTasks[checkedTasks.length - 1];
                    if (lastCheckedTask) {
                        lastCheckedTask.isConflict = true;
                    }
                    
                    const conflictObj = {
                        conflictType: 'TASK_SEQUENCE',
                        task_key: task_key,
                        batch_id: currentTask.batch_id,
                        stage: currentTask.stage,
                        transporter_id: currentTask.transporter_id,
                        planned_start: currentTask.task_start_time,
                        planned_end: currentTask.task_finished_time,
                        flex_down: flex_down,
                        flex_up: flex_up,
                        blocked_by: blocked_by,
                        blocked_by_batch_id: prevTaskSameTransporter.batch_id,
                        blocked_by_stage: prevTaskSameTransporter.stage,
                        blocked_by_end: prevTaskSameTransporter.task_finished_time,
                        deficit: deficit,
                        travel_time: travelTime,
                        available_gap: availableGap,
                        x_min: x_min,
                        x_max: x_max
                    };
                    
                    // Yhteensopivuuskerros: generoi vanhat kentät (DEPRECATED)
                    const legacyConflicts = buildLegacyConflictsFromCheckedTasksWithConflict(
                        checkedTasks,
                        currentTask,
                        prevTaskSameTransporter,
                        travelTime,
                        availableGap,
                        deficit,
                        sortedTasks,
                        transporters,
                        stations,
                        options
                    );
                    
                    return {
                        hasConflict: true,
                        checkedTasks: checkedTasks,
                        conflict: conflictObj,
                        // VANHAT KENTÄT (DEPRECATED)
                        conflicts: legacyConflicts.conflicts,
                        summary: legacyConflicts.summary
                    };
                }
            }
        }
        
        // ═══════════════════════════════════════════════════════════════════════════════
        // 5b. CROSS_TRANSPORTER_HANDOFF: Saman erän peräkkäiset staget eri nostimilla
        //     Kun T2 vie erän handoff-asemalle, ehtiikö T1 hakea sen sieltä?
        //     Tarkistetaan vastaanottavan nostimen idle-jaksoista.
        //
        //     Jos T1 ei ehdi → konflikti kohdistuu currentTask:iin (T2:n delivery),
        //     jolloin resolver viivästää edellistä stagea → erä odottaa T2:n alueella.
        // ═══════════════════════════════════════════════════════════════════════════════
        {
            // Etsi saman erän seuraava tehtävä (stage + 1)
            const nextBatchTask = sortedTasks.find(t =>
                t.batch_id === currentTask.batch_id &&
                t.stage === currentTask.stage + 1 &&
                t.transporter_id !== null
            );
            
            if (nextBatchTask &&
                nextBatchTask.transporter_id !== null &&
                currentTask.transporter_id !== nextBatchTask.transporter_id) {
                
                // Handoff-tilanne: T2 (currentTask) vie asemalle, T1 (nextBatchTask) hakee
                const receivingTransporterId = nextBatchTask.transporter_id;
                const receivingTransporter = transporterById.get(receivingTransporterId);
                const handoffStation = findStation(currentTask.sink_station_id, stations);
                
                if (receivingTransporter && handoffStation) {
                    // Laske vastaanottavan nostimen (T1) idle-jaksot tehtävälistasta
                    const receiverTasks = tasksByTransporter.get(receivingTransporterId) || [];
                    
                    // Etsi T1:n edellinen tehtävä ennen handoff-pickupia
                    // = T1:n viimeisin tehtävä joka päättyy ennen nextBatchTask:n alkua
                    let receiverPrevTask = null;
                    for (const rt of receiverTasks) {
                        if (rt.batch_id === nextBatchTask.batch_id && rt.stage === nextBatchTask.stage) continue;
                        if (rt.task_finished_time <= nextBatchTask.task_start_time) {
                            if (!receiverPrevTask || rt.task_finished_time > receiverPrevTask.task_finished_time) {
                                receiverPrevTask = rt;
                            }
                        }
                    }
                    
                    {
                        // Laske T1:n siirtymäaika handoff-asemalle
                        const movementTimes = options?.movementTimes || null;
                        let travelTime;
                        let receiverAvailableTime;
                        let fromLabel;

                        if (receiverPrevTask) {
                            // T1:llä on edellinen tehtävä → matka sen sink-asemalta
                            const fromStation = findStation(receiverPrevTask.sink_station_id, stations);
                            travelTime = getPrecomputedTravelTime(
                                fromStation, handoffStation, receivingTransporter, movementTimes
                            );
                            receiverAvailableTime = receiverPrevTask.task_finished_time;
                            fromLabel = `station ${receiverPrevTask.sink_station_id}`;
                        } else {
                            // T1:llä ei edellistä tehtävää → matka nykyisestä positiosta
                            // Hae nostimen ajonaikainen x_position transporterStates-datasta
                            const transporterStates = options?.transporterStates || [];
                            const receiverState = transporterStates.find(ts => ts.id === receivingTransporterId);
                            const receiverX = receiverState?.state?.x_position ?? receiverState?.x_position ?? 0;
                            // Luo virtuaalinen station-objekti nostimen positiosta
                            const virtualFromStation = { number: `T${receivingTransporterId}_pos`, x_position: receiverX };
                            travelTime = calculateHorizontalTravelTime(virtualFromStation, handoffStation, receivingTransporter);
                            receiverAvailableTime = 0; // T1 on vapaa heti alusta
                            fromLabel = `current pos x=${receiverX}`;
                        }
                        
                        // T1 on handoff-asemalla aikaisintaan:
                        const receiverEarliestArrival = receiverAvailableTime + travelTime;
                        
                        // T2:n delivery valmis:
                        const deliveryDone = currentTask.task_finished_time;
                        
                        // Deficit = kuinka paljon T1 myöhästyy
                        const handoffDeficit = receiverEarliestArrival - deliveryDone;
                        
                        if (handoffDeficit > DEFICIT_TOLERANCE) {
                            const task_key = `B${currentTask.batch_id}_s${currentTask.stage}`;
                            const blocked_by = `B${nextBatchTask.batch_id}_s${nextBatchTask.stage}`;
                            
                            console.log(`[ANALYZE] CROSS_TRANSPORTER_HANDOFF: ${task_key} T${currentTask.transporter_id}→T${receivingTransporterId}`);
                            console.log(`[ANALYZE]   delivery done=${deliveryDone.toFixed(1)}s, receiver T${receivingTransporterId} earliest@handoff=${receiverEarliestArrival.toFixed(1)}s`);
                            if (receiverPrevTask) {
                                console.log(`[ANALYZE]   receiver prev: B${receiverPrevTask.batch_id}s${receiverPrevTask.stage} end=${receiverPrevTask.task_finished_time.toFixed(1)}s @station ${receiverPrevTask.sink_station_id}`);
                                console.log(`[ANALYZE]   travel ${receiverPrevTask.sink_station_id}→${currentTask.sink_station_id}: ${travelTime.toFixed(1)}s, deficit=${handoffDeficit.toFixed(1)}s`);
                            } else {
                                console.log(`[ANALYZE]   receiver T${receivingTransporterId} at ${fromLabel}, no previous tasks`);
                                console.log(`[ANALYZE]   travel to ${currentTask.sink_station_id}: ${travelTime.toFixed(1)}s, deficit=${handoffDeficit.toFixed(1)}s`);
                            }
                            
                            // Merkitse viimeinen tehtävä (juuri lisätty kohdassa 4b) konfliktiksi
                            const lastCheckedTask = checkedTasks[checkedTasks.length - 1];
                            if (lastCheckedTask) {
                                lastCheckedTask.isConflict = true;
                            }
                            
                            // Konflikti kohdistuu currentTask:iin (T2:n delivery)
                            // blocked_by on T1:n edellinen tehtävä (syy miksi T1 ei ehdi)
                            const conflictObj = {
                                conflictType: 'CROSS_TRANSPORTER_HANDOFF',
                                task_key: task_key,
                                batch_id: currentTask.batch_id,
                                stage: currentTask.stage,
                                transporter_id: currentTask.transporter_id,
                                planned_start: currentTask.task_start_time,
                                planned_end: currentTask.task_finished_time,
                                flex_down: flex_down,
                                flex_up: flex_up,
                                blocked_by: receiverPrevTask ? `B${receiverPrevTask.batch_id}_s${receiverPrevTask.stage}` : `T${receivingTransporterId}_home`,
                                blocked_by_batch_id: receiverPrevTask?.batch_id ?? null,
                                blocked_by_stage: receiverPrevTask?.stage ?? null,
                                blocked_by_end: receiverPrevTask?.task_finished_time ?? 0,
                                receiving_transporter_id: receivingTransporterId,
                                deficit: handoffDeficit,
                                travel_time: travelTime,
                                available_gap: deliveryDone - (receiverPrevTask?.task_finished_time ?? 0),
                                x_min: x_min,
                                x_max: x_max
                            };
                            
                            // Yhteensopivuuskerros: käytetään collision-formaattia
                            const legacyBlocker = receiverPrevTask
                                ? checkedTasks.find(ct => ct.batch_id === receiverPrevTask.batch_id && ct.stage === receiverPrevTask.stage) || checkedTasks[checkedTasks.length - 1]
                                : checkedTasks[checkedTasks.length - 1];
                            const legacyConflicts = buildLegacyConflictsFromCheckedTasksWithCollision(
                                checkedTasks,
                                currentTask,
                                legacyBlocker,
                                handoffDeficit,
                                sortedTasks,
                                transporters,
                                stations,
                                options
                            );
                            
                            return {
                                hasConflict: true,
                                checkedTasks: checkedTasks,
                                conflict: conflictObj,
                                conflicts: legacyConflicts.conflicts,
                                summary: legacyConflicts.summary
                            };
                        }
                    }
                }
            }
        }
        
        // ═══════════════════════════════════════════════════════════════════════════════
        // 6. TRANSPORTER_COLLISION TARKISTUS: Eri nostimet, sama X-alue, sama aika
        //    Tarkistus tehdään aikaisempia (jo tarkistettuja) tehtäviä vastaan
        // ═══════════════════════════════════════════════════════════════════════════════
        for (const checkedTask of checkedTasks) {
            // Ohita sama nostin (se on jo tarkistettu TASK_SEQUENCE:ssä)
            if (checkedTask.transporter_id === currentTask.transporter_id) continue;
            
            // Tarkista X-alueen päällekkäisyys
            const x_overlap_start = Math.max(x_min, checkedTask.x_min);
            const x_overlap_end = Math.min(x_max, checkedTask.x_max);
            const hasXOverlap = x_overlap_start < x_overlap_end;
            
            if (!hasXOverlap) continue;
            
            // Tarkista ajan päällekkäisyys
            const time_overlap_start = Math.max(currentTask.task_start_time, checkedTask.start_time);
            const time_overlap_end = Math.min(currentTask.task_finished_time, checkedTask.end_time);
            const hasTimeOverlap = time_overlap_start < time_overlap_end;
            
            if (!hasTimeOverlap) continue;
            
            // TRANSPORTER_COLLISION löytyi!
            const deficit = time_overlap_end - time_overlap_start + (options?.collisionMarginSec ?? 2);
            const task_key = `B${currentTask.batch_id}_s${currentTask.stage}`;
            
            console.log(`[ANALYZE] TRANSPORTER_COLLISION: ${task_key} vs ${checkedTask.task_key}, X=[${x_overlap_start}-${x_overlap_end}], time_overlap=${(time_overlap_end - time_overlap_start).toFixed(1)}s`);
            
            // Merkitse viimeinen tehtävä (juuri lisätty kohdassa 4b) konfliktiksi
            const lastCheckedTask = checkedTasks[checkedTasks.length - 1];
            if (lastCheckedTask) {
                lastCheckedTask.isConflict = true;
            }
            
            const conflictObj = {
                conflictType: 'TRANSPORTER_COLLISION',
                task_key: task_key,
                batch_id: currentTask.batch_id,
                stage: currentTask.stage,
                transporter_id: currentTask.transporter_id,
                planned_start: currentTask.task_start_time,
                planned_end: currentTask.task_finished_time,
                flex_down: flex_down,
                flex_up: flex_up,
                blocked_by: checkedTask.task_key,
                blocked_by_batch_id: checkedTask.batch_id,
                blocked_by_stage: checkedTask.stage,
                blocked_by_transporter_id: checkedTask.transporter_id,
                deficit: deficit,
                x_min: x_overlap_start,
                x_max: x_overlap_end,
                time_overlap_start: time_overlap_start,
                time_overlap_end: time_overlap_end
            };
            
            // Yhteensopivuuskerros: generoi vanhat kentät (DEPRECATED)
            // TRANSPORTER_COLLISION:lle käytetään checkedTask:ia edellisen tehtävän tilalla
            const legacyConflicts = buildLegacyConflictsFromCheckedTasksWithCollision(
                checkedTasks,
                currentTask,
                checkedTask,
                deficit,
                sortedTasks,
                transporters,
                stations,
                options
            );
            
            return {
                hasConflict: true,
                checkedTasks: checkedTasks,
                conflict: conflictObj,
                // VANHAT KENTÄT (DEPRECATED)
                conflicts: legacyConflicts.conflicts,
                summary: legacyConflicts.summary
            };
        }
        
        // ═══════════════════════════════════════════════════════════════════════════════
        // 7. EI KONFLIKTIA → Lisää checkedTasks-listaan
        // ═══════════════════════════════════════════════════════════════════════════════
        checkedTasks.push({
            task_key: `B${currentTask.batch_id}_s${currentTask.stage}`,
            batch_id: currentTask.batch_id,
            stage: currentTask.stage,
            transporter_id: currentTask.transporter_id,
            start_time: currentTask.task_start_time,
            end_time: currentTask.task_finished_time,
            flex_down: flex_down,
            flex_up: flex_up,
            x_min: x_min,
            x_max: x_max,
            // Säilytetään myös alkuperäiset teoria-arvot debuggausta varten
            theory_flex_down: theory_flex_down,
            theory_flex_up: theory_flex_up,
            gap_to_prev: gap_to_prev,
            gap_to_next: gap_to_next
        });
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // 8. KAIKKI OK → Ei konflikteja
    // ═══════════════════════════════════════════════════════════════════════════════
    if (options.debug) {
        console.log(`[ANALYZE] Ei konflikteja, ${checkedTasks.length} tehtävää tarkistettu`);
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // 9. YHTEENSOPIVUUSKERROS: Generoi vanhan rakenteen tiedot (conflicts, summary)
    //    DEPRECATED: Poistetaan kun kaikki kutsut on päivitetty uuteen rakenteeseen
    // ═══════════════════════════════════════════════════════════════════════════════
    const legacyConflicts = buildLegacyConflictsFromCheckedTasks(
        checkedTasks, 
        sortedTasks, 
        transporters, 
        stations, 
        options
    );
    
    return {
        // UUSI RAKENNE (v3.4)
        hasConflict: false,
        checkedTasks: checkedTasks,
        conflict: null,
        
        // VANHAT KENTÄT (DEPRECATED - poistetaan myöhemmin)
        conflicts: legacyConflicts.conflicts,
        summary: legacyConflicts.summary
    };
}

/**
 * DEPRECATED: Generoi vanhan rakenteen (conflicts, summary) checkedTasks:sta
 * Tämä on yhteensopivuuskerros siirtymäkautta varten.
 * Poistetaan kun kaikki kutsut on päivitetty uuteen rakenteeseen.
 */
function buildLegacyConflictsFromCheckedTasks(checkedTasks, sortedTasks, transporters, stations, options) {
    const conflicts = [];
    
    // Luo nostinkohtaiset tehtävälistat
    const tasksByTransporter = new Map();
    for (const t of checkedTasks) {
        if (!tasksByTransporter.has(t.transporter_id)) {
            tasksByTransporter.set(t.transporter_id, []);
        }
        tasksByTransporter.get(t.transporter_id).push(t);
    }
    
    // Käy läpi jokaisen nostimen tehtäväparit
    for (const [transporterId, tasks] of tasksByTransporter) {
        // Järjestä tehtävät aikajärjestykseen
        tasks.sort((a, b) => a.start_time - b.start_time);
        
        for (let i = 0; i < tasks.length - 1; i++) {
            const prevTask = tasks[i];
            const nextTask = tasks[i + 1];
            
            const transporter = transporters.find(t => t.id === transporterId);
            if (!transporter) continue;
            
            // Hae alkuperäiset task-objektit siirtoajan laskentaa varten
            const originalPrevTask = sortedTasks.find(t => 
                t.batch_id === prevTask.batch_id && t.stage === prevTask.stage
            );
            const originalNextTask = sortedTasks.find(t => 
                t.batch_id === nextTask.batch_id && t.stage === nextTask.stage
            );
            if (!originalPrevTask || !originalNextTask) continue;
            
            const fromStation = findStation(originalPrevTask.sink_station_id, stations);
            const toStation = findStation(originalNextTask.lift_station_id, stations);
            if (!fromStation || !toStation) continue;
            
            const movementTimes = options?.movementTimes || null;
            const baseTravelTime = getPrecomputedTravelTime(fromStation, toStation, transporter, movementTimes);
            const marginSec = options?.conflictMarginSec ?? 0;
            const travelTime = baseTravelTime + marginSec;
            
            const availableGap = nextTask.start_time - prevTask.end_time;
            const deficit = travelTime - availableGap;
            
            conflicts.push({
                transporter_id: transporterId,
                pair_index: i,
                prevTask: {
                    batch_id: prevTask.batch_id,
                    stage: prevTask.stage,
                    lift_station: originalPrevTask.lift_station_id,
                    sink_station: originalPrevTask.sink_station_id,
                    start_time: prevTask.start_time,
                    finished_time: prevTask.end_time,
                    calc_time_s: originalPrevTask.calc_time_s || 0,
                    min_time_s: originalPrevTask.min_time_s || 0,
                    max_time_s: originalPrevTask.max_time_s || 0,
                    flex_down: prevTask.flex_down,
                    flex_up: prevTask.flex_up
                },
                nextTask: {
                    batch_id: nextTask.batch_id,
                    stage: nextTask.stage,
                    lift_station: originalNextTask.lift_station_id,
                    sink_station: originalNextTask.sink_station_id,
                    start_time: nextTask.start_time,
                    finished_time: nextTask.end_time,
                    calc_time_s: originalNextTask.calc_time_s || 0,
                    min_time_s: originalNextTask.min_time_s || 0,
                    max_time_s: originalNextTask.max_time_s || 0,
                    flex_down: nextTask.flex_down,
                    flex_up: nextTask.flex_up
                },
                timing: {
                    travel_time: travelTime,
                    available_gap: availableGap,
                    deficit: deficit,
                    is_conflict: deficit > 1.0
                }
            });
        }
    }
    
    // Laske yhteenveto
    const actualConflicts = conflicts.filter(c => c.timing.is_conflict);
    const summary = {
        totalPairs: conflicts.length,
        totalConflicts: actualConflicts.length,
        totalDeficit: actualConflicts.reduce((sum, c) => sum + c.timing.deficit, 0),
        totalFlexDown: conflicts.reduce((sum, c) => sum + c.prevTask.flex_down, 0),
        totalFlexUp: conflicts.reduce((sum, c) => sum + c.nextTask.flex_up, 0),
        conflictsByTransporter: {}
    };
    
    for (const c of actualConflicts) {
        const tid = c.transporter_id;
        if (!summary.conflictsByTransporter[tid]) {
            summary.conflictsByTransporter[tid] = { count: 0, totalDeficit: 0 };
        }
        summary.conflictsByTransporter[tid].count++;
        summary.conflictsByTransporter[tid].totalDeficit += c.timing.deficit;
    }
    
    return { conflicts, summary };
}

/**
 * DEPRECATED: Generoi vanhan rakenteen TASK_SEQUENCE konfliktin kanssa
 */
function buildLegacyConflictsFromCheckedTasksWithConflict(
    checkedTasks,
    currentTask,
    prevTask,
    travelTime,
    availableGap,
    deficit,
    sortedTasks,
    transporters,
    stations,
    options
) {
    // Ensin generoi conflicts-lista jo tarkistetuista pareista
    const base = buildLegacyConflictsFromCheckedTasks(
        checkedTasks,
        sortedTasks,
        transporters,
        stations,
        options
    );
    
    // Lisää konflikti-pari listaan
    const conflictPair = {
        transporter_id: currentTask.transporter_id,
        pair_index: base.conflicts.length,
        prevTask: {
            batch_id: prevTask.batch_id,
            stage: prevTask.stage,
            lift_station: prevTask.lift_station_id,
            sink_station: prevTask.sink_station_id,
            start_time: prevTask.task_start_time,
            finished_time: prevTask.task_finished_time,
            calc_time_s: prevTask.calc_time_s || 0,
            min_time_s: prevTask.min_time_s || 0,
            max_time_s: prevTask.max_time_s || 0,
            flex_down: Math.max(0, (prevTask.calc_time_s || 0) - (prevTask.min_time_s || 0)),
            flex_up: Math.max(0, (prevTask.max_time_s || 0) - (prevTask.calc_time_s || 0))
        },
        nextTask: {
            batch_id: currentTask.batch_id,
            stage: currentTask.stage,
            lift_station: currentTask.lift_station_id,
            sink_station: currentTask.sink_station_id,
            start_time: currentTask.task_start_time,
            finished_time: currentTask.task_finished_time,
            calc_time_s: currentTask.calc_time_s || 0,
            min_time_s: currentTask.min_time_s || 0,
            max_time_s: currentTask.max_time_s || 0,
            flex_down: Math.max(0, (currentTask.calc_time_s || 0) - (currentTask.min_time_s || 0)),
            flex_up: Math.max(0, (currentTask.max_time_s || 0) - (currentTask.calc_time_s || 0))
        },
        timing: {
            travel_time: travelTime,
            available_gap: availableGap,
            deficit: deficit,
            is_conflict: true
        }
    };
    
    base.conflicts.push(conflictPair);
    
    // Päivitä summary
    base.summary.totalPairs = base.conflicts.length;
    base.summary.totalConflicts = 1;
    base.summary.totalDeficit = deficit;
    if (!base.summary.conflictsByTransporter[currentTask.transporter_id]) {
        base.summary.conflictsByTransporter[currentTask.transporter_id] = { count: 0, totalDeficit: 0 };
    }
    base.summary.conflictsByTransporter[currentTask.transporter_id].count = 1;
    base.summary.conflictsByTransporter[currentTask.transporter_id].totalDeficit = deficit;
    
    return base;
}

/**
 * DEPRECATED: Generoi vanhan rakenteen TRANSPORTER_COLLISION konfliktin kanssa
 */
function buildLegacyConflictsFromCheckedTasksWithCollision(
    checkedTasks,
    currentTask,
    collidingCheckedTask,
    deficit,
    sortedTasks,
    transporters,
    stations,
    options
) {
    // Ensin generoi conflicts-lista jo tarkistetuista pareista
    const base = buildLegacyConflictsFromCheckedTasks(
        checkedTasks,
        sortedTasks,
        transporters,
        stations,
        options
    );
    
    // Hae alkuperäiset task-objektit
    const collidingOriginal = sortedTasks.find(t =>
        t.batch_id === collidingCheckedTask.batch_id && t.stage === collidingCheckedTask.stage
    );
    
    // TRANSPORTER_COLLISION esitetään samassa formaatissa kuin TASK_SEQUENCE
    // vaikka semantiikka on erilainen
    const conflictPair = {
        transporter_id: currentTask.transporter_id,
        pair_index: base.conflicts.length,
        prevTask: {
            batch_id: collidingCheckedTask.batch_id,
            stage: collidingCheckedTask.stage,
            lift_station: collidingOriginal?.lift_station_id,
            sink_station: collidingOriginal?.sink_station_id,
            start_time: collidingCheckedTask.start_time,
            finished_time: collidingCheckedTask.end_time,
            calc_time_s: collidingOriginal?.calc_time_s || 0,
            min_time_s: collidingOriginal?.min_time_s || 0,
            max_time_s: collidingOriginal?.max_time_s || 0,
            flex_down: collidingCheckedTask.flex_down,
            flex_up: collidingCheckedTask.flex_up
        },
        nextTask: {
            batch_id: currentTask.batch_id,
            stage: currentTask.stage,
            lift_station: currentTask.lift_station_id,
            sink_station: currentTask.sink_station_id,
            start_time: currentTask.task_start_time,
            finished_time: currentTask.task_finished_time,
            calc_time_s: currentTask.calc_time_s || 0,
            min_time_s: currentTask.min_time_s || 0,
            max_time_s: currentTask.max_time_s || 0,
            flex_down: Math.max(0, (currentTask.calc_time_s || 0) - (currentTask.min_time_s || 0)),
            flex_up: Math.max(0, (currentTask.max_time_s || 0) - (currentTask.calc_time_s || 0))
        },
        timing: {
            travel_time: 0,  // Ei siirtymäaikaa, vaan törmäys
            available_gap: 0,
            deficit: deficit,
            is_conflict: true
        }
    };
    
    base.conflicts.push(conflictPair);
    
    // Päivitä summary
    base.summary.totalPairs = base.conflicts.length;
    base.summary.totalConflicts = 1;
    base.summary.totalDeficit = deficit;
    if (!base.summary.conflictsByTransporter[currentTask.transporter_id]) {
        base.summary.conflictsByTransporter[currentTask.transporter_id] = { count: 0, totalDeficit: 0 };
    }
    base.summary.conflictsByTransporter[currentTask.transporter_id].count = 1;
    base.summary.conflictsByTransporter[currentTask.transporter_id].totalDeficit = deficit;
    
    return base;
}

/**
 * UUSI KONFLIKTINRATKAISUALGORITMI (v3.4)
 * 
 * Ratkaisee konfliktin iteratiivisesti TAAKSEPÄIN checkedTasks-listaa käyttäen.
 * Dokumentaatio: StateMachine_Detailed_Design.md osio 7.0.3
 * 
 * ALGORITMI:
 * 1. Aloita konfliktikohdasta (deficit = X sekuntia)
 * 2. Tarkista konfliktoivan tehtävän flex_up (viivästys)
 *    - Jos flex_up >= deficit → RATKAISU OK
 *    - Jos flex_up < deficit → käytä koko flex_up, jatka edelliseen pariin
 * 3. Siirry edelliseen pariin (checkedTasks), tarkista flex_down (aikaistus)
 *    - Jos flex_down >= jäljellä oleva deficit → RATKAISU OK
 *    - Jos flex_down < deficit → käytä koko flex_down, jatka edelliseen
 * 4. Toista kunnes ratkaistu tai reservit loppuivat
 * 
 * @param {Object} conflict - analyzeTaskConflicts():n palauttama konflikti-objekti
 * @param {Array} checkedTasks - analyzeTaskConflicts():n palauttama OK-tehtävien lista
 * @param {Array} tasks - Tehtävälista (muokataan in-place propagoinnissa)
 * @param {Array} batches - Erälista (muokataan in-place propagoinnissa)
 * @param {Object} options - { lockedStages, currentTimeSec }
 * @returns {Object} { solved, actions[], failReason?, ... }
 */
function resolveConflict(conflict, checkedTasks, tasks, batches, options = {}) {
    if (!conflict) {
        return { solved: true, actions: [], reason: 'NO_CONFLICT' };
    }
    
    const lockedStages = options.lockedStages || {};
    const currentTimeSec = options.currentTimeSec || 0;
    
    let remainingDeficit = conflict.deficit;
    const actions = [];  // Kerätään tehdyt muutokset
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // KONFLIKTI ON PARI: prevTask (blocked_by) ja nextTask (conflict)
    // - AIKAISTUS kohdistuu prevTask:n erään (blocked_by_batch_id)
    // - VIIVÄSTYS kohdistuu nextTask:n erään (conflict.batch_id)
    // ═══════════════════════════════════════════════════════════════════════════════
    const prevBatchId = conflict.blocked_by_batch_id;
    const prevStage = conflict.blocked_by_stage;
    const nextBatchId = conflict.batch_id;
    const nextStage = conflict.stage;
    
    console.log(`[resolveConflict] Konflikti: B${prevBatchId}s${prevStage} → B${nextBatchId}s${nextStage}, deficit=${remainingDeficit.toFixed(1)}s`);
    
    // RAPORTOINTI: Kirjaa konflikti

    
    // ═══════════════════════════════════════════════════════════════════════════════
    // VAIHE 1: Yritä AIKAISTUSTA ensin (prevTask:n erän flex_down ketjussa)
    // - Aikaistus on parempi vaihtoehto koska nopeuttaa läpimenoaikaa
    // - Kohdistuu prevTask:n erään (blocked_by_batch_id)
    // - Rajoittuu ketjun min(flex_down) arvoon ("pullonkaula")
    // ═══════════════════════════════════════════════════════════════════════════════
    
    // Hae prevTask:n erän tehtävät checkedTasks:sta (jo tarkastetut, joustovarat laskettu)
    const prevBatchTasks = checkedTasks
        .filter(t => t.batch_id === prevBatchId && t.stage <= prevStage)
        .sort((a, b) => a.stage - b.stage);  // Nouseva järjestys
    
    console.log(`[resolveConflict] prevBatch B${prevBatchId} chain: [${prevBatchTasks.map(t => `s${t.stage}:${t.flex_down.toFixed(1)}s`).join(', ')}]`);
    
    // RAPORTOINTI: Kirjaa prevBatch ketju (flex_down)

    
    // ═══════════════════════════════════════════════════════════════════════════════
    // KORJAUS: nextBatch:n tehtävät EIVÄT ole checkedTasks:ssa koska konflikti
    // keskeyttää analyysin! Haetaan tehtävät suoraan tasks-listasta (combinedTasks)
    // ja lasketaan jousto-arvot manuaalisesti.
    // ═══════════════════════════════════════════════════════════════════════════════
    let nextBatchTasks = checkedTasks
        .filter(t => t.batch_id === nextBatchId && t.stage <= nextStage)
        .sort((a, b) => a.stage - b.stage)  // Nouseva järjestys
        .map(t => ({
            ...t,
            // KRIITTINEN: Konfliktiparin nextTask:lle käytetään theory_flex_up!
            // Gap-rajoitus ei päde koska viivästys SIIRTÄÄ tehtävää eteenpäin.
            // Uudet konfliktit syntyvät viivästyksen jälkeen ja käsitellään seuraavilla kierroksilla.
            flex_up: t.theory_flex_up !== undefined ? t.theory_flex_up : t.flex_up
        }));
    
    // Jos nextBatchTasks on tyhjä, hae tehtävät tasks-listasta (combinedTasks)
    if (nextBatchTasks.length === 0 && tasks && tasks.length > 0) {
        console.log(`[resolveConflict] nextBatch B${nextBatchId} EI checkedTasks:ssa - haetaan tasks:sta`);
        
        // Hae erän tiedot jousto-laskentaa varten
        const batch = batches.find(b => b.batch_id === nextBatchId);
        
        // Hae tehtävät tasks-listasta ja laske jousto
        const rawTasks = tasks
            .filter(t => t.batch_id === nextBatchId && t.stage <= nextStage)
            .sort((a, b) => a.stage - b.stage);
        
        for (const task of rawTasks) {
            // Lasketaan teoria-jousto taskista
            const calc_time = task.calc_time_s || 0;
            const min_time = task.min_time_s || 0;
            const max_time = task.max_time_s || 0;
            const theory_flex_down = Math.max(0, calc_time - min_time);
            const theory_flex_up = Math.max(0, max_time - calc_time);
            
            nextBatchTasks.push({
                batch_id: task.batch_id,
                stage: task.stage,
                flex_down: theory_flex_down,
                flex_up: theory_flex_up,
                start_time: task.task_start_time,
                end_time: task.task_finished_time
            });
        }
        
        console.log(`[resolveConflict] Haettu ${nextBatchTasks.length} tehtävää tasks:sta B${nextBatchId}:lle`);
    }
    
    console.log(`[resolveConflict] nextBatch B${nextBatchId} chain: [${nextBatchTasks.map(t => `s${t.stage}:flex_up=${t.flex_up.toFixed(1)}s,theory=${t.theory_flex_up?.toFixed(1) ?? 'N/A'}`).join(', ')}]`);
    
    // RAPORTOINTI: Kirjaa nextBatch ketju (flex_up)

    
    // ═══════════════════════════════════════════════════════════════════════════════
    // VAIHE 1: AIKAISTUS (CHAIN_BACKWARD) - Dokumentin mukaan: suffix-etupainotteinen
    //
    // Dokumentti StateMachine_Detailed_Design.md, kohta 5.6 DEPARTURE_CHECK:
    // 1) Tarkista prevTask:in flex_down. Jos = 0 → siirry viivästykseen
    // 2) Käy saman erän edelliset staget taaksepäin, etsi pullonkaula
    //    (pienin nollasta poikkeava < konfliktikohdan oma flex_down)
    // 3) Siirrä erän "loppupää" (konfliktistagesta eteenpäin) aikaisemmaksi
    // 4) Käytä konflikti-stagen omaa flex_down:ia (suffix) jos vielä tarvitaan
    // 5) Jos deficit ei täyty → jatka viivästykseen
    // ═══════════════════════════════════════════════════════════════════════════════
    
    // Hae konfliktikohdan (prevStage) oma flex_down
    const conflictPrevTask = prevBatchTasks.find(t => t.stage === prevStage);
    const conflictFlexDown = conflictPrevTask ? conflictPrevTask.flex_down : 0;
    
    console.log(`[resolveConflict] Conflict stage B${prevBatchId}s${prevStage} flex_down=${conflictFlexDown.toFixed(1)}s`);
    
    // Vaihe 1: Jos konflikti-stagen flex_down = 0 → siirry suoraan viivästykseen
    let earlierBlocked = false;
    if (conflictFlexDown <= 0) {
        console.log(`[resolveConflict] Conflict stage flex_down=0 → proceed to delay`);
        earlierBlocked = true;
    }
    
    // Tarkista lukitukset - jos KONFLIKTI-STAGE on lukittu VIIVÄSTÄ:lle, aikaistus ei ole sallittu.
    // KORJAUS: Tarkistetaan VAIN konflikti-stage (prevStage), ei koko ketjua.
    // Aikaistus kohdistuu vain stageille >= prevStage (propagateEarlierToBatch),
    // joten aiempien stagejen lukitukset eivät vaikuta.
    if (!earlierBlocked) {
        const conflictStageKey = `B${prevBatchId}s${prevStage}`;
        if (lockedStages[conflictStageKey] === 'DELAY') {
            console.log(`[resolveConflict] Advance blocked: ${conflictStageKey} locked DELAY`);
            earlierBlocked = true;
        }
    }
    
    if (!earlierBlocked) {
        // Vaihe 2: Käy staget taaksepäin, etsi pullonkaula (Δchain)
        // "pienin nollasta poikkeava, joka on pienempi kuin konfliktikohdan oma flex_down"
        let chainFlexDown = Infinity;  // Ketjun pullonkaula
        
        // Käy läpi stageja (paitsi konflikti-stage itse) ja etsi pullonkaula
        for (const t of prevBatchTasks) {
            if (t.stage < prevStage) {  // Vain edelliset staget, EI konflikti-stage
                if (t.flex_down > 0 && t.flex_down < chainFlexDown && t.flex_down < conflictFlexDown) {
                    chainFlexDown = t.flex_down;
                }
            }
        }
        
        // Jos ei löytynyt pullonkaulaa ketjusta, käytä 0 (ei ketjuaikaistusta)
        if (chainFlexDown === Infinity) {
            chainFlexDown = 0;
        }
        
        console.log(`[resolveConflict] Chain bottleneck Δchain=${chainFlexDown.toFixed(1)}s`);
        
        // Cap: sama logiikka kuin DELAY-vaiheissa (90% jos asemalla, 50% muuten)
        const prevBatchForAdvanceCap = batches.find(b => b.batch_id === prevBatchId);
        const isPrevOnStationForAdvance = prevBatchForAdvanceCap && prevBatchForAdvanceCap.stage === prevStage;
        const advanceCapFactor = isPrevOnStationForAdvance ? 0.9 : 0.5;
        
        // Vaihe 3: Sovella ketjuaikaistus (Δchain)
        if (chainFlexDown > 0) {
            const cappedChainFlex = chainFlexDown * advanceCapFactor;
            const chainEarlierAmount = Math.min(cappedChainFlex, remainingDeficit);
            remainingDeficit -= chainEarlierAmount;
            
            // Aikaistus kohdistuu konfliktistageen ja siitä eteenpäin ("loppupää")
            actions.push({
                action: 'ADVANCE',
                batch_id: prevBatchId,
                stage: prevStage,
                to_stage: prevStage,
                amount: chainEarlierAmount,
                lockKey: `B${prevBatchId}s${prevStage}`,
                lockDirection: 'ADVANCE'
            });
            
            console.log(`[resolveConflict] CHAIN_ADVANCE B${prevBatchId}s${prevStage} -${chainEarlierAmount.toFixed(1)}s (flex_down=${chainFlexDown.toFixed(1)}s, cap=${(advanceCapFactor*100).toFixed(0)}%, remaining: ${remainingDeficit.toFixed(1)}s)`);
            

        }
        
        // Vaihe 4: Käytä konflikti-stagen omaa flex_down:ia (suffix) jos vielä tarvitaan
        if (remainingDeficit > 0.1 && conflictFlexDown > chainFlexDown) {
            const suffixFlexDown = conflictFlexDown - chainFlexDown;  // Jäljellä oleva jousto
            const cappedSuffixFlex = suffixFlexDown * advanceCapFactor;
            const suffixEarlierAmount = Math.min(cappedSuffixFlex, remainingDeficit);
            
            if (suffixEarlierAmount > 0) {
                remainingDeficit -= suffixEarlierAmount;
                
                // Jos ketjuaikaistus on jo lisätty, päivitä sen määrää
                const existingAction = actions.find(a => 
                    a.action === 'ADVANCE' && a.batch_id === prevBatchId && a.stage === prevStage
                );
                
                if (existingAction) {
                    existingAction.amount += suffixEarlierAmount;
                    console.log(`[resolveConflict] SUFFIX_ADVANCE B${prevBatchId}s${prevStage} add -${suffixEarlierAmount.toFixed(1)}s (total: ${existingAction.amount.toFixed(1)}s, remaining: ${remainingDeficit.toFixed(1)}s)`);
                } else {
                    actions.push({
                        action: 'ADVANCE',
                        batch_id: prevBatchId,
                        stage: prevStage,
                        to_stage: prevStage,
                        amount: suffixEarlierAmount,
                        lockKey: `B${prevBatchId}s${prevStage}`,
                        lockDirection: 'ADVANCE'
                    });
                    console.log(`[resolveConflict] SUFFIX_ADVANCE B${prevBatchId}s${prevStage} -${suffixEarlierAmount.toFixed(1)}s (remaining: ${remainingDeficit.toFixed(1)}s)`);
                }
            }
        }
        
        // Tarkista onko deficit katettu aikaistuksella
        if (remainingDeficit <= 0.1) {
            const totalEarlier = actions.filter(a => a.action === 'ADVANCE').reduce((s, a) => s + a.amount, 0);
            applyResolutionActions(actions, tasks, batches, currentTimeSec);
            return { 
                solved: true, 
                actions, 
                reason: 'ADVANCE_SUFFICIENT',
                totalDelay: 0,
                totalEarlier: totalEarlier
            };
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // VAIHE 2: DELAY next (konflikti-stage)
    // - Viivästä nextin konflikti-stagea (flex_up) → next alkaa myöhemmin → gap kasvaa
    // - Cap: 90% jos erä on asemalla, 50% muuten (TASKS saa loput)
    // ═══════════════════════════════════════════════════════════════════════════════
    const conflictNextTask = nextBatchTasks.find(t => t.stage === nextStage);
    
    if (conflictNextTask && remainingDeficit > 0.1) {
        const stageKey = `B${nextBatchId}s${nextStage}`;
        const isLocked = lockedStages[stageKey] === 'ADVANCE';
        
        if (isLocked) {
            console.log(`[resolveConflict] Delay blocked: ${stageKey} locked ADVANCE`);
        } else if (conflictNextTask.flex_up > 0) {
            // Cap: 90% if batch is currently ON this station, 50% otherwise
            const nextBatch = batches.find(b => b.batch_id === nextBatchId);
            const isOnStation = nextBatch && nextBatch.stage === nextStage;
            const capFactor = isOnStation ? 0.9 : 0.5;
            const maxDelay = conflictNextTask.flex_up * capFactor;
            const delayAmount = Math.min(maxDelay, remainingDeficit);
            remainingDeficit -= delayAmount;
            
            actions.push({
                action: 'DELAY',
                batch_id: nextBatchId,
                stage: nextStage,
                amount: delayAmount,
                lockKey: stageKey,
                lockDirection: 'DELAY'
            });
            
            console.log(`[resolveConflict] DELAY B${nextBatchId}s${nextStage} +${delayAmount.toFixed(1)}s (flex_up=${conflictNextTask.flex_up.toFixed(1)}s, cap=${(capFactor*100).toFixed(0)}%, remaining: ${remainingDeficit.toFixed(1)}s)`);

        } else {
            console.log(`[resolveConflict] Conflict stage B${nextBatchId}s${nextStage} flex_up=0, cannot delay`);
        }
    } else if (!conflictNextTask) {
        console.log(`[resolveConflict] Conflict stage B${nextBatchId}s${nextStage} not found in nextBatchTasks`);
    }
    
    // Tarkista ratkeaminen VAIHE 2:n jälkeen
    if (remainingDeficit <= 0.1) {
        applyResolutionActions(actions, tasks, batches, currentTimeSec);
        const totalEarlier = actions.filter(a => a.action === 'ADVANCE').reduce((s, a) => s + a.amount, 0);
        const totalDelay = actions.filter(a => a.action === 'DELAY').reduce((s, a) => s + a.amount, 0);
        const reason = totalEarlier > 0 ? 'COMBINED_SUFFICIENT' : 'DELAY_SUFFICIENT';
        return { solved: true, actions, reason, totalDelay, totalEarlier };
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // VAIHE 3: DELAY next:n edellinen stage (nextStage - 1)
    // - Tarkista VAIN yksi edeltävä stage ja sen flex_up
    // - Cap: 90% jos erä on asemalla, 50% muuten
    // ═══════════════════════════════════════════════════════════════════════════════
    if (remainingDeficit > 0.1 && nextStage > 0) {
        const prevNextStage = nextStage - 1;
        const prevNextTask = nextBatchTasks.find(t => t.stage === prevNextStage);
        
        if (prevNextTask) {
            const walkKey = `B${nextBatchId}s${prevNextStage}`;
            const isWalkLocked = lockedStages[walkKey] === 'ADVANCE';
            
            if (isWalkLocked) {
                console.log(`[resolveConflict] Stage ${walkKey} locked, skipping`);
            } else {
                // Käytä theory_flex_up jos saatavilla (gap-rajoitus ei päde viivästykseen)
                const walkFlexUp = prevNextTask.theory_flex_up !== undefined
                    ? prevNextTask.theory_flex_up
                    : prevNextTask.flex_up || 0;
                
                if (walkFlexUp > 0) {
                    // Cap: 90% if batch is currently ON this station, 50% otherwise
                    const walkBatch = batches.find(b => b.batch_id === nextBatchId);
                    const isWalkOnStation = walkBatch && walkBatch.stage === prevNextStage;
                    const walkCapFactor = isWalkOnStation ? 0.9 : 0.5;
                    const maxWalkDelay = walkFlexUp * walkCapFactor;
                    const delayAmount = Math.min(maxWalkDelay, remainingDeficit);
                    remainingDeficit -= delayAmount;
                    
                    actions.push({
                        action: 'DELAY',
                        batch_id: nextBatchId,
                        stage: prevNextStage,
                        propagateFromStage: nextStage,
                        amount: delayAmount,
                        lockKey: walkKey,
                        lockDirection: 'DELAY'
                    });
                    
                    console.log(`[resolveConflict] PRECEDING_DELAY B${nextBatchId}s${prevNextStage} +${delayAmount.toFixed(1)}s (flex_up=${walkFlexUp.toFixed(1)}s, cap=${(walkCapFactor*100).toFixed(0)}%, remaining: ${remainingDeficit.toFixed(1)}s)`);

                } else {
                    console.log(`[resolveConflict] B${nextBatchId}s${prevNextStage} flex_up=0, skipping`);
                }
            }
        }
    }
    
    // Tarkista ratkeaminen VAIHE 3:n jälkeen
    if (remainingDeficit <= 0.1) {
        applyResolutionActions(actions, tasks, batches, currentTimeSec);
        const totalEarlier = actions.filter(a => a.action === 'ADVANCE').reduce((s, a) => s + a.amount, 0);
        const totalDelay = actions.filter(a => a.action === 'DELAY').reduce((s, a) => s + a.amount, 0);
        const reason = totalEarlier > 0 ? 'COMBINED_SUFFICIENT' : 'DELAY_SUFFICIENT';
        return { solved: true, actions, reason, totalDelay, totalEarlier };
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // VAIHE 4: VIIMEISENÄ KEINONA - Viivästä PREV:iä niin paljon, että se menee
    //          NEXT:in jälkeen (= pakotettu swap)
    //
    // Ehdot:
    //   - Parit EIVÄT ole swapattuja (swap-ehto: prev.sink === next.lift)
    //   - Prev:n flex_up riittää siirtämään sen nextin finished_time:n jälkeen
    //
    // Tämä kääntää tehtävien järjestyksen: prev → next muuttuu next → prev,
    // jolloin alkuperäinen konflikti poistuu (mutta uusi konflikti voi syntyä
    // käänteisessä suunnassa - se käsitellään seuraavalla iteraatiolla).
    // ═══════════════════════════════════════════════════════════════════════════════
    if (remainingDeficit > 0.1) {
        // Tarkista swap-ehto: Jos prev.sink === next.lift, parit on jo swapattu
        // (tai swapattavissa) → ei viivästetä previä
        const prevTaskInTasks = tasks.find(t => t.batch_id === prevBatchId && t.stage === prevStage);
        const nextTaskInTasks = tasks.find(t => t.batch_id === nextBatchId && t.stage === nextStage);
        
        const isSwappable = prevTaskInTasks && nextTaskInTasks &&
            prevTaskInTasks.sink_station_id === nextTaskInTasks.lift_station_id;
        
        if (isSwappable) {
            console.log(`[resolveConflict] VAIHE 4: Swap-ehto pätee (prev.sink=${prevTaskInTasks.sink_station_id} === next.lift=${nextTaskInTasks.lift_station_id}), ei viivästetä previä`);
        } else {
            // Laske kuinka paljon prev:iä pitäisi viivästää jotta se menee nextin ohi
            const conflictPrevForDelay = prevBatchTasks.find(t => t.stage === prevStage);
            if (conflictPrevForDelay) {
                const prevDelayFlexUp = conflictPrevForDelay.theory_flex_up !== undefined
                    ? conflictPrevForDelay.theory_flex_up
                    : conflictPrevForDelay.flex_up || 0;
                
                const prevStageKey = `B${prevBatchId}s${prevStage}`;
                const isPrevLocked = lockedStages[prevStageKey] === 'ADVANCE';
                
                if (isPrevLocked) {
                    console.log(`[resolveConflict] VAIHE 4: ${prevStageKey} locked ADVANCE, cannot delay prev`);
                } else if (prevDelayFlexUp > 0) {
                    // Cap: 90% if batch is currently ON this station, 50% otherwise
                    const prevBatchForCap = batches.find(b => b.batch_id === prevBatchId);
                    const isPrevOnStation = prevBatchForCap && prevBatchForCap.stage === prevStage;
                    const prevCapFactor = isPrevOnStation ? 0.9 : 0.5;
                    const maxPrevDelay = prevDelayFlexUp * prevCapFactor;
                    const delayAmount = Math.min(maxPrevDelay, remainingDeficit);
                    remainingDeficit -= delayAmount;
                    
                    actions.push({
                        action: 'DELAY',
                        batch_id: prevBatchId,
                        stage: prevStage,
                        amount: delayAmount,
                        lockKey: prevStageKey,
                        lockDirection: 'DELAY'
                    });
                    
                    console.log(`[resolveConflict] DELAY_PREV_PAST_NEXT B${prevBatchId}s${prevStage} +${delayAmount.toFixed(1)}s (flex_up=${prevDelayFlexUp.toFixed(1)}s, remaining: ${remainingDeficit.toFixed(1)}s)`);

                } else {
                    console.log(`[resolveConflict] VAIHE 4: B${prevBatchId}s${prevStage} flex_up=0, cannot delay prev`);
                }
            }
        }
    }
    
    // Tarkista ratkeaminen VAIHE 4:n jälkeen
    if (remainingDeficit <= 0.1) {
        applyResolutionActions(actions, tasks, batches, currentTimeSec);
        const totalEarlier = actions.filter(a => a.action === 'ADVANCE').reduce((s, a) => s + a.amount, 0);
        const totalDelay = actions.filter(a => a.action === 'DELAY').reduce((s, a) => s + a.amount, 0);
        const reason = totalEarlier > 0 ? 'COMBINED_SUFFICIENT' : 'DELAY_PREV_PAST_NEXT';
        return { solved: true, actions, reason, totalDelay, totalEarlier };
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // VAIHE 5: Reservit loppuivat → EPÄONNISTUI
    // ═══════════════════════════════════════════════════════════════════════════════
    
    // Käytetään silti mitä saatiin (vähentää deficitiä)
    if (actions.length > 0) {
        applyResolutionActions(actions, tasks, batches, currentTimeSec);
    }
    
    const totalUsed = conflict.deficit - remainingDeficit;
    console.warn(`[resolveConflict] FAILED: deficit=${conflict.deficit.toFixed(1)}s, used=${totalUsed.toFixed(1)}s, missing=${remainingDeficit.toFixed(1)}s`);
    
    return {
        solved: false,
        actions,
        reason: 'RESERVES_EXHAUSTED',
        deficit: conflict.deficit,
        used: totalUsed,
        missing: remainingDeficit,
        totalDelay: actions.filter(a => a.action === 'DELAY').reduce((s, a) => s + a.amount, 0),
        totalEarlier: actions.filter(a => a.action === 'ADVANCE').reduce((s, a) => s + a.amount, 0)
    };
}

/**
 * Soveltaa ratkaisu-actionit tasks/batches -listoihin.
 * 
 * AIKAISTUS: Siirtää kaikki tehtävät (stage >= from_stage) aikaisemmaksi
 * VIIVÄSTYS: Venyttää stage:n loppuaikaa ja siirtää myöhemmät alkamaan myöhemmin
 */
function applyResolutionActions(actions, tasks, batches, currentTimeSec = 0) {
    for (const action of actions) {
        if (action.action === 'DELAY') {
            const fromStage = action.propagateFromStage || action.stage;
            propagateDelayToBatch(tasks, batches, action.batch_id, fromStage, action.amount, false);
        }
        else if (action.action === 'ADVANCE') {
            propagateEarlierToBatch(tasks, batches, action.batch_id, action.stage, action.amount, currentTimeSec);
        }
    }
}

/**
 * DEPRECATED: Ratkaisee VAIN ENSIMMÄISEN konfliktin (vanha malli)
 * Käytä mieluummin solveAllConflictsWithChainFlex() uudessa koodissa.
 * - Vain VIIVÄSTÄ (ei aikaistusta - se aiheuttaa oskillaatiota)
 * - HÄLYTYS lopettaa iteroinnin (stopIteration: true)
 * 
 * @param {object} analysis - analyzeTaskConflicts():n tulos
 * @param {Array} tasks - Tehtävälista (muokataan in-place)
 * @param {Array} batches - Erälista (muokataan in-place)
 * @param {Array} skippedConflicts - Lista skipattavista konflikteista (konfliktinimillä)
 * @param {Object} lockedStages - Map lukituista stageista: {"B1s6": "AIKAISTA"} estää VIIVÄSTÄ samalle stagelle
 * @param {number} currentTimeSec - Nykyhetki sekunteina (ei saa aikaistaa menneisyyteen)
 * @returns {object} { decision, conflict, stopIteration, skipConflict, lockStage } 
 */
function resolveFirstConflict(analysis, tasks, batches, skippedConflicts = [], lockedStages = {}, currentTimeSec = 0) {
    if (!analysis || !analysis.conflicts) {
        return { decision: null };
    }
    
    // Hae konfliktit (aikajärjestyksessä), ohita skipatut
    const actualConflicts = analysis.conflicts.filter(c => {
        if (!c.timing.is_conflict) return false;
        // Ohita skipatut konfliktit (tunnistetaan prevTask ja nextTask batch_id + stage)
        const key = `${c.prevTask.batch_id}s${c.prevTask.stage}-${c.nextTask.batch_id}s${c.nextTask.stage}`;
        if (skippedConflicts.includes(key)) {
            return false;
        }
        return true;
    });
    if (actualConflicts.length === 0) {
        return { decision: null };
    }
    
    const conflict = actualConflicts[0];
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // OSKILLAATION ESTO: Tarkista onko stage lukittu vastakkaiseen suuntaan
    // ═══════════════════════════════════════════════════════════════════════════════
    const prevStageKey = `B${conflict.prevTask.batch_id}s${conflict.prevTask.stage}`;
    const nextStageKey = `B${conflict.nextTask.batch_id}s${conflict.nextTask.stage}`;
    
    // Jos prevTask (AIKAISTA kohde) on jo lukittu VIIVÄSTÄ:lle → ei voi aikaistaa
    const prevLocked = lockedStages[prevStageKey];
    // Jos nextTask (VIIVÄSTÄ kohde) on jo lukittu AIKAISTA:lle → ei voi viivästää
    const nextLocked = lockedStages[nextStageKey];
    
    // Laske flex rajoitukset perustuen lukituksiin
    let prevFlexAvailable = true;  // Voiko prevTaskia aikaistaa?
    let nextFlexAvailable = true;  // Voiko nextTaskia viivästää?
    
    if (prevLocked === 'DELAY') {
        prevFlexAvailable = false;
        console.log(`[resolveFirstConflict] ${prevStageKey} locked DELAY, cannot advance`);
    }
    if (nextLocked === 'ADVANCE') {
        nextFlexAvailable = false;
        console.log(`[resolveFirstConflict] ${nextStageKey} locked ADVANCE, cannot delay`);
    }
    // Tallenna konfliktin avain mahdollista skippausta varten
    const conflictKey = `${conflict.prevTask.batch_id}s${conflict.prevTask.stage}-${conflict.nextTask.batch_id}s${conflict.nextTask.stage}`;
    
    // Luo lookup nykytilan hakua varten
    const batchById = new Map();
    for (const batch of batches) {
        batchById.set(batch.batch_id, batch);
    }
    
    // Hae NYKYISET taskit
    const prevTaskNow = tasks.find(t => 
        t.batch_id === conflict.prevTask.batch_id && 
        t.stage === conflict.prevTask.stage
    );
    const nextTaskNow = tasks.find(t => 
        t.batch_id === conflict.nextTask.batch_id && 
        t.stage === conflict.nextTask.stage
    );
    
    if (!prevTaskNow || !nextTaskNow) {
        console.warn(`[resolveFirstConflict] Tasks not found: B${conflict.prevTask.batch_id}s${conflict.prevTask.stage} / B${conflict.nextTask.batch_id}s${conflict.nextTask.stage}`);
        return { decision: null };
    }
    
    // Laske deficit NYKYTILASTA
    const travelTime = conflict.timing.travel_time;
    const availableGap = nextTaskNow.task_start_time - prevTaskNow.task_finished_time;
    const deficit = travelTime - availableGap;
    
    // Jos deficit <= 1.0s (toleranssi), konflikti on käytännössä ratkaistu
    const DEFICIT_TOLERANCE = 1.0;
    if (deficit <= DEFICIT_TOLERANCE) {
        if (deficit > 0) {
            console.log(`[resolveFirstConflict] Konflikti OK (deficit=${deficit.toFixed(2)}s < toleranssi)`);
        }
        return { decision: null, resolved: true };
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // JOUSTOVARAT (flex_down = aikaistus, flex_up = viivästys)
    // ═══════════════════════════════════════════════════════════════════════════════
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // JOUSTOVARAT - käytetään konfliktissa tallennettuja STAGE-KOHTAISIA arvoja
    // Nämä tulevat task-objekteista, ei batchin nykyisestä stagesta
    // ═══════════════════════════════════════════════════════════════════════════════
    
    // PREV TASK: flex_down = calc_time - min_time (kuinka paljon voi aikaistaa)
    const prevFlexDown = conflict.prevTask.flex_down || 0;
    const prevFlexUp = conflict.prevTask.flex_up || 0;
    
    // NEXT TASK: flex_up = max_time - calc_time (kuinka paljon voi viivästää)
    const nextFlexDown = conflict.nextTask.flex_down || 0;
    const nextFlexUp = conflict.nextTask.flex_up || 0;
    
    const prevStage = conflict.prevTask.stage;
    const nextStage = conflict.nextTask.stage;
    let decision = null;
    
    console.log(`[resolveFirstConflict] B${conflict.prevTask.batch_id}s${prevStage}→B${conflict.nextTask.batch_id}s${nextStage}: deficit=${deficit.toFixed(1)}s, prev_flex_down=${prevFlexDown.toFixed(1)}s, next_flex_up=${nextFlexUp.toFixed(1)}s`);
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // STRATEGIA: Yritä ensin AIKAISTUSTA, sitten VIIVÄSTYSTÄ
    // ═══════════════════════════════════════════════════════════════════════════════
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // OSKILLAATION ESTO: Rajoita flex-arvoja lukitusten perusteella
    // ═══════════════════════════════════════════════════════════════════════════════
    const effectivePrevFlexDown = prevFlexAvailable ? prevFlexDown : 0;
    const effectiveNextFlexUp = nextFlexAvailable ? nextFlexUp : 0;
    
    // Jos MOLEMMAT ovat estetty lukitusten vuoksi → skipaa konflikti kokonaan
    if (!prevFlexAvailable && !nextFlexAvailable) {
        console.warn(`[resolveFirstConflict] ⚠ LOCKED: ${prevStageKey} and ${nextStageKey} locked in opposite directions → skipping conflict`);
        return { 
            decision: {
                action: 'ALERT_LOCKED',
                reason: `Conflict skipped: ${prevStageKey} locked DELAY and ${nextStageKey} locked ADVANCE`,
                deficit: deficit
            }, 
            conflict, 
            stopIteration: false, 
            skipConflict: conflictKey 
        };
    }
    
    // TAPAUS 1: Aikaistus riittää (prevTask voi nopeuttaa) JA ei ole lukittu
    if (effectivePrevFlexDown >= deficit) {
        propagateEarlierToBatch(tasks, batches, conflict.prevTask.batch_id, prevStage, deficit, currentTimeSec);
        decision = {
            action: 'ADVANCE',
            batch_id: conflict.prevTask.batch_id,
            stage: prevStage,
            amount: deficit,
            deficit: deficit,
            flexUsed: deficit,
            flexRemaining: prevFlexDown - deficit,
            reason: `Advanced previous batch -${deficit.toFixed(2)}s`
        };
        console.log(`[resolveFirstConflict] ADVANCE: B${conflict.prevTask.batch_id} stage${prevStage} -${deficit.toFixed(2)}s (flex_down=${prevFlexDown.toFixed(2)}s)`);
        return { decision, conflict, stopIteration: false, lockStage: { key: prevStageKey, direction: 'ADVANCE' } };
    }
    
    // TAPAUS 2: Viivästys riittää (nextTask voi odottaa) JA ei ole lukittu
    if (effectiveNextFlexUp >= deficit) {
        propagateDelayToBatch(tasks, batches, conflict.nextTask.batch_id, nextStage, deficit, false);
        decision = {
            action: 'DELAY',
            batch_id: conflict.nextTask.batch_id,
            stage: nextStage,
            amount: deficit,
            deficit: deficit,
            flexUsed: deficit,
            flexRemaining: nextFlexUp - deficit,
            reason: `Delayed next batch +${deficit.toFixed(2)}s`
        };
        console.log(`[resolveFirstConflict] DELAY: B${conflict.nextTask.batch_id} stage${nextStage} +${deficit.toFixed(2)}s (flex_up=${nextFlexUp.toFixed(2)}s)`);
        return { decision, conflict, stopIteration: false, lockStage: { key: nextStageKey, direction: 'DELAY' } };
    }
    
    // TAPAUS 3: Yhdistelmä - käytä molempia (aikaistus + viivästys), huomioi lukitukset
    const totalFlex = effectivePrevFlexDown + effectiveNextFlexUp;
    if (totalFlex >= deficit) {
        // Käytä ensin koko aikaistus (jos sallittu), sitten loput viivästyksenä
        const earlierAmount = effectivePrevFlexDown;
        const delayAmount = deficit - earlierAmount;
        
        // Kerää lukitukset (molemmille jos käytetään)
        const locks = [];
        if (earlierAmount > 0) {
            propagateEarlierToBatch(tasks, batches, conflict.prevTask.batch_id, prevStage, earlierAmount, currentTimeSec);
            locks.push({ key: prevStageKey, direction: 'ADVANCE' });
        }
        if (delayAmount > 0) {
            propagateDelayToBatch(tasks, batches, conflict.nextTask.batch_id, nextStage, delayAmount, false);
            locks.push({ key: nextStageKey, direction: 'DELAY' });
        }
        
        decision = {
            action: 'COMBINED',
            prevBatch: conflict.prevTask.batch_id,
            prevStage: prevStage,
            earlierAmount: earlierAmount,
            nextBatch: conflict.nextTask.batch_id,
            nextStage: nextStage,
            delayAmount: delayAmount,
            deficit: deficit,
            reason: `Combined: B${conflict.prevTask.batch_id} -${earlierAmount.toFixed(2)}s + B${conflict.nextTask.batch_id} +${delayAmount.toFixed(2)}s`
        };
        console.log(`[resolveFirstConflict] COMBINED: B${conflict.prevTask.batch_id} -${earlierAmount.toFixed(2)}s, B${conflict.nextTask.batch_id} +${delayAmount.toFixed(2)}s`);
        return { decision, conflict, stopIteration: false, lockStages: locks };
    }
    
    // TAPAUS 4: Ei riitä → HÄLYTYS (käytetään kaikki mitä on, huomioi lukitukset)
    const usedEarlier = effectivePrevFlexDown;
    const usedDelay = effectiveNextFlexUp;
    const stillMissing = deficit - usedEarlier - usedDelay;
    
    const locks = [];
    if (usedEarlier > 0) {
        propagateEarlierToBatch(tasks, batches, conflict.prevTask.batch_id, prevStage, usedEarlier, currentTimeSec);
        locks.push({ key: prevStageKey, direction: 'ADVANCE' });
    }
    if (usedDelay > 0) {
        propagateDelayToBatch(tasks, batches, conflict.nextTask.batch_id, nextStage, usedDelay, false);
        locks.push({ key: nextStageKey, direction: 'DELAY' });
    }
    
    decision = {
        action: 'ALERT',
        deficit: deficit,
        usedEarlier: usedEarlier,
        usedDelay: usedDelay,
        missing: stillMissing,
        prevTask: { batch_id: conflict.prevTask.batch_id, stage: prevStage },
        nextTask: { batch_id: conflict.nextTask.batch_id, stage: nextStage },
        reason: `Flex insufficient! Missing ${stillMissing.toFixed(2)}s (used: advance ${usedEarlier.toFixed(2)}s + delay ${usedDelay.toFixed(2)}s)`
    };
    
    console.warn(`[resolveFirstConflict] ALERT: B${conflict.prevTask.batch_id}→B${conflict.nextTask.batch_id}, deficit=${deficit.toFixed(2)}s, used ${(usedEarlier + usedDelay).toFixed(2)}s, MISSING ${stillMissing.toFixed(2)}s`);
    
    // JATKA ITEROINTIA - tätä konfliktia ei voida ratkaista täysin, SKIPAA seuraavalla kierroksella
    // conflictKey: käytetään tunnistamaan tämä konflikti skipattavaksi
    // lockStages: lukitaan muutetut staget jotta ei tule oskillaatiota
    return { decision, conflict, stopIteration: false, skipConflict: conflictKey, lockStages: locks };
}

/**
 * Ratkaisee KAIKKI konfliktit kerralla (vanha tapa, ei käytössä iteratiivisessa mallissa)
 * 
 * @param {object} analysis - analyzeTaskConflicts():n tulos (käytetään konfliktien tunnistamiseen)
 * @param {Array} tasks - Tehtävälista (muokataan in-place)
 * @param {Array} batches - Erälista (muokataan in-place)
 * @returns {object} Tulokset: { decisions, totalEarlier, totalDelayed, alerts }
 */
function resolveTaskConflicts(analysis, tasks, batches) {
    if (!analysis || !analysis.conflicts) {
        return { decisions: [], totalEarlier: 0, totalDelayed: 0, alerts: [] };
    }
    
    const decisions = [];
    let totalEarlier = 0;
    let totalDelayed = 0;
    const alerts = [];
    
    // Luo batch lookup (käytetään dynaamiseen flex-laskentaan)
    const batchById = new Map();
    for (const batch of batches) {
        batchById.set(batch.batch_id, batch);
    }
    
    // Käsittele vain varsinaiset konfliktit
    const actualConflicts = analysis.conflicts.filter(c => c.timing.is_conflict);
    
    for (const conflict of actualConflicts) {
        // DYNAAMINEN FLEX-LASKENTA: Haetaan NYKYISET batch-ajat
        // (aikaisemmat päätökset ovat voineet muuttaa näitä)
        const prevBatch = batchById.get(conflict.prevTask.batch_id);
        const nextBatch = batchById.get(conflict.nextTask.batch_id);
        
        // Laske flex-arvot NYKYTILASTA
        const prevCalc = prevBatch?.calc_time_s || 0;
        const prevMin = prevBatch?.min_time_s || 0;
        const prevMax = prevBatch?.max_time_s || 0;
        const prevFlexDown = Math.max(0, prevCalc - prevMin);
        
        const nextCalc = nextBatch?.calc_time_s || 0;
        const nextMax = nextBatch?.max_time_s || 0;
        const nextFlexUp = Math.max(0, nextMax - nextCalc);
        
        // Deficit pysyy samana (laskettu task-ajoista ANALYZE:ssa)
        // TODO: Voisi laskea myös uudelleen task-ajoista jos ne muuttuvat
        const deficit = conflict.timing.deficit;
        
        let decision = null;
        
        // PRIORITEETTI 1: Aikaista edellistä (nopeuttaa läpimenoaikaa)
        if (prevFlexDown >= deficit) {
            propagateEarlyToBatch(tasks, batches, conflict.prevTask.batch_id, conflict.prevTask.stage, deficit);
            decision = {
                action: 'ADVANCE',
                batch_id: conflict.prevTask.batch_id,
                stage: conflict.prevTask.stage,
                amount: deficit,
                reason: 'Previous task advanced, throughput improved'
            };
            totalEarlier += deficit;
            console.log(`[resolveTaskConflicts] ADVANCE: B${conflict.prevTask.batch_id} stage${conflict.prevTask.stage} -${deficit.toFixed(2)}s`);
        }
        // PRIORITEETTI 2: Jaa jousto
        else if (prevFlexDown > 0 && (prevFlexDown + nextFlexUp) >= deficit) {
            const earlyAmount = prevFlexDown;
            const delayAmount = deficit - prevFlexDown;
            
            propagateEarlyToBatch(tasks, batches, conflict.prevTask.batch_id, conflict.prevTask.stage, earlyAmount);
            propagateDelayToBatch(tasks, batches, conflict.nextTask.batch_id, conflict.nextTask.stage, delayAmount, false);
            
            decision = {
                action: 'SPLIT',
                earlier: { batch_id: conflict.prevTask.batch_id, stage: conflict.prevTask.stage, amount: earlyAmount },
                delayed: { batch_id: conflict.nextTask.batch_id, stage: conflict.nextTask.stage, amount: delayAmount },
                reason: 'Flex split: advance + delay'
            };
            totalEarlier += earlyAmount;
            totalDelayed += delayAmount;
            console.log(`[resolveTaskConflicts] SPLIT: B${conflict.prevTask.batch_id} -${earlyAmount.toFixed(2)}s, B${conflict.nextTask.batch_id} +${delayAmount.toFixed(2)}s`);
        }
        // PRIORITEETTI 3: Viivästä seuraavaa
        else if (nextFlexUp >= deficit) {
            propagateDelayToBatch(tasks, batches, conflict.nextTask.batch_id, conflict.nextTask.stage, deficit, false);
            decision = {
                action: 'DELAY',
                batch_id: conflict.nextTask.batch_id,
                stage: conflict.nextTask.stage,
                amount: deficit,
                reason: 'Advance not possible, delaying later task'
            };
            totalDelayed += deficit;
            console.log(`[resolveTaskConflicts] DELAY: B${conflict.nextTask.batch_id} stage${conflict.nextTask.stage} +${deficit.toFixed(2)}s`);
        }
        // VIRHE: Jousto ei riitä
        else {
            const available = prevFlexDown + nextFlexUp;
            decision = {
                action: 'ALERT',
                deficit: deficit,
                available: available,
                prevTask: conflict.prevTask,
                nextTask: conflict.nextTask,
                reason: `MaxTime exceeded! Missing ${deficit.toFixed(2)}s, flex only ${available.toFixed(2)}s`
            };
            alerts.push(decision);
            console.warn(`[resolveTaskConflicts] ALERT: Conflict B${conflict.prevTask.batch_id}→B${conflict.nextTask.batch_id}, deficit=${deficit.toFixed(2)}s, available=${available.toFixed(2)}s`);
        }
        
        if (decision) {
            decisions.push(decision);
        }
    }
    
    return { decisions, totalEarlier, totalDelayed, alerts };
}

/**
 * Propagoi aikaistus erän kaikkiin tuleviin tehtäviin
 * 
 * TOIMINTAPERIAATE:
 * 1. AIKAISTETAAN saman erän TEHTÄVIÄ tästä stagesta eteenpäin (start/finish ajat)
 * 2. Päivitetään erän calc_time_s (pienenee → nopeutuu)
 * 
 * @param {Array} tasks - Kaikki tehtävät (muokataan in-place)
 * @param {Array} batches - Kaikki erät (muokataan in-place)
 * @param {number} batchId - Aikaistettavan erän ID
 * @param {number} fromStage - Mistä stagesta alkaen aikaistetaan
 * @param {number} earlyS - Aikaistus sekunteina (positiivinen luku)
 */
function propagateEarlyToBatch(tasks, batches, batchId, fromStage, earlyS) {
    if (earlyS <= 0) return;
    
    // 1. Aikaista kaikki saman erän tehtävät tästä stagesta eteenpäin
    for (const task of tasks) {
        if (task.batch_id === batchId && task.stage >= fromStage) {
            task.task_start_time -= earlyS;
            task.task_finished_time -= earlyS;
        }
    }
    
    // 2. Päivitä erän calc_time_s (jos erä löytyy ja on oikeassa stagessa)
    const batch = batches.find(b => b && b.batch_id === batchId);
    if (batch) {
        const currentCalc = Number(batch.calc_time_s) || 0;
        const minTime = Number(batch.min_time_s) || 0;
        // Varmista ettei mene alle minimin
        batch.calc_time_s = Math.max(minTime, currentCalc - earlyS);
    }
}

/**
 * Validoi tehtävien siirtymäajat ja lisää viivästykset tarvittaessa
 * 
 * Tarkistaa että nostin ehtii siirtyä edellisen tehtävän laskuasemalta
 * seuraavan tehtävän nostoasemalle. Jos ei ehdi, viivästää seuraavaa tehtävää.
 * 
 * @param {Array} tasks - Tehtävälista (muokataan in-place)
 * @param {Array} batches - Erälista (muokataan in-place aikataulujen osalta)
 * @param {Array} transporters - Nostimet
 * @param {Array} stations - Asemat
 * @param {object} options - Asetukset: { movementTimes }
 * @returns {object} Tulokset: { totalDelays, programStretches }
 */
function validateTaskTiming(tasks, batches, transporters, stations, options = {}) {
    if (!tasks || tasks.length === 0) {
        return { totalDelays: 0, programStretches: [] };
    }
    
    const movementTimes = options?.movementTimes || null;
    const transporterIds = [...new Set(tasks.map(t => t.transporter_id))];
    let totalDelays = 0;
    
    const delayByBatchStage = new Map();
    
    const recordStretchDelay = (batchId, stage, delayS) => {
        const bId = Number(batchId);
        const st = Number(stage);
        const d = Number(delayS);
        if (!Number.isFinite(bId) || !Number.isFinite(st) || !Number.isFinite(d)) return;
        if (st < 1 || d <= 0) return;
        const key = `${bId}:${st}`;
        const prev = delayByBatchStage.get(key) || 0;
        delayByBatchStage.set(key, prev + d);
    };

    const batchById = new Map();
    for (const b of (Array.isArray(batches) ? batches : [])) {
        const id = Number(b && b.batch_id);
        if (Number.isFinite(id)) batchById.set(id, b);
    }
    
    for (const transporterId of transporterIds) {
        if (transporterId === null) continue;
        
        const transporter = transporters.find(t => t.id === transporterId);
        if (!transporter) continue;
        
        // Hae nostimen tehtävät SÄILYTTÄEN swap-järjestys (EI sorttia!)
        // Järjestys tulee swapSameStationTasks-funktiolta
        const transporterTasks = tasks.filter(t => t.transporter_id === transporterId);
        
        // Käy läpi parit
        for (let i = 0; i < transporterTasks.length - 1; i++) {
            const prevTask = transporterTasks[i];
            const nextTask = transporterTasks[i + 1];
            
            const fromStation = findStation(prevTask.sink_station_id, stations);
            const toStation = findStation(nextTask.lift_station_id, stations);
            
            if (!fromStation || !toStation) continue;
            
            // Hae siirtymäaika esilasketuista arvoista (tai laske fallbackina)
            const travelTime = getPrecomputedTravelTime(fromStation, toStation, transporter, movementTimes);
            
            // Tarkista väli
            const availableGap = nextTask.task_start_time - prevTask.task_finished_time;
            
            if (availableGap < travelTime) {
                const delay = travelTime - availableGap;
                const stretchStage = nextTask.stage;
                
                console.log(`[validateTaskTiming] T${transporterId} DELAY: B${nextTask.batch_id} stage${stretchStage} +${delay.toFixed(1)}s`);
                
                // Viivästä tehtäviä
                propagateDelayToBatch(tasks, batches, nextTask.batch_id, nextTask.stage, delay, false);

                if (stretchStage >= 1) {
                    recordStretchDelay(nextTask.batch_id, stretchStage, delay);
                }
                
                totalDelays += delay;
            }
        }
    }

    // Build programStretches output
    const programStretches = [];
    for (const [key, sumDelay] of delayByBatchStage.entries()) {
        if (!Number.isFinite(sumDelay) || sumDelay <= 0) continue;
        const [batchIdStr, stageStr] = String(key).split(':');
        const batchId = Number(batchIdStr);
        const stage = Number(stageStr);
        if (!Number.isFinite(batchId) || !Number.isFinite(stage) || stage < 1) continue;
        programStretches.push({ batchId, stage, delayS: sumDelay });

        const batch = batchById.get(batchId);
        const batchUnitLocV = (options?.units || []).find(u => u.batch_id === batchId);
        const batchLocV = batchUnitLocV ? batchUnitLocV.location : (batch ? Number(batch.location) : NaN);
        const onStation = Number.isFinite(batchLocV) && batchLocV >= 100;
        const batchStage = batch ? Number(batch.stage) : NaN;
        if (batch && onStation && Number.isFinite(batchStage) && batchStage === stage) {
            const currentCalc = Number(batch.calc_time_s);
            const safeCurrent = Number.isFinite(currentCalc) ? Math.max(0, currentCalc) : 0;
            batch.calc_time_s = safeCurrent + sumDelay;
        }
    }
    
    return { totalDelays, programStretches };
}

/**
 * Validoi ja korjaa tehtävälista (LEGACY - käyttää uusia funktioita)
 * 
 * Varmistaa että:
 * 1. Tehtävät ovat suoritettavissa (nostin ehtii siirtyä)
 * 2. Sama asema: nosto ensin, lasku sitten (eri erille)
 * 
 * @param {Array} tasks - Tehtävälista (muokataan in-place)
 * @param {Array} batches - Erälista (muokataan in-place aikataulujen osalta)
 * @param {Array} transporters - Nostimet
 * @param {Array} stations - Asemat
 * @returns {object} Tulokset: { success, totalDelays, swapCount, tasksModified }
 */
function validateAndFixTaskList(tasks, batches, transporters, stations, opts = {}) {
    // Edellytys: kaikki tehtävät jaettu
    if (!tasks || tasks.length === 0) {
        return { success: true, totalDelays: 0, swapCount: 0, tasksModified: false, programStretches: [] };
    }
    
    const hasUnassigned = tasks.some(t => t.transporter_id === null);
    if (hasUnassigned) {
        console.log('[validateAndFixTaskList] Skipping - unassigned tasks exist');
        return { success: false, error: 'Unassigned tasks exist', totalDelays: 0, swapCount: 0, tasksModified: false, programStretches: [] };
    }
    
    // Käytä uusia pilkottuja funktioita
    const swapResult = swapSameStationTasks(tasks);
    const validationResult = validateTaskTiming(tasks, batches, transporters, stations);
    
    const tasksModified = swapResult.swapCount > 0 || validationResult.totalDelays > 0;
    
    if (tasksModified) {
        console.log(`[validateAndFixTaskList] Result: ${swapResult.swapCount} swaps, ${validationResult.totalDelays.toFixed(1)}s delays`);
    }
    
    return { 
        success: true, 
        totalDelays: validationResult.totalDelays,
        swapCount: swapResult.swapCount,
        tasksModified,
        programStretches: validationResult.programStretches
    };
}

/**
 * Propagoi AIKAISTUS erän kaikkiin tuleviin tehtäviin
 * 
 * TOIMINTAPERIAATE:
 * 1. Aikaistetaan saman erän TEHTÄVIÄ tästä stagesta eteenpäin (start/finish ajat)
 * 2. Päivitetään erän calc_time_s (pienenee → nopeutuu)
 * 
 * @param {Array} tasks - Kaikki tehtävät (muokataan in-place)
 * @param {Array} batches - Kaikki erät (muokataan in-place)
 * @param {number} batchId - Aikaistettavan erän ID
 * @param {number} fromStage - Mistä stagesta alkaen aikaistetaan
 * @param {number} earlierS - Aikaistus sekunteina (positiivinen arvo)
 * @param {number} currentTimeSec - Nykyhetki sekunteina (ei saa aikaistaa menneisyyteen)
 * @returns {object} { applied, clamped }
 */
function propagateEarlierToBatch(tasks, batches, batchId, fromStage, earlierS, currentTimeSec = 0) {
    if (earlierS <= 0) return { applied: 0, clamped: false };
    
    // Hae erän tiedot ja laske sallittu aikaistus
    const batch = batches.find(b => b && b.batch_id === batchId);
    let actualEarlier = earlierS;
    let clamped = false;
    
    if (batch) {
        const currentCalc = Number(batch.calc_time_s) || 0;
        const minTime = Number(batch.min_time_s) || 0;
        const availableFlex = Math.max(0, currentCalc - minTime);
        
        // Rajoita aikaistus sallittuun minimiin
        if (earlierS > availableFlex) {
            actualEarlier = availableFlex;
            clamped = true;
            console.warn(`[propagateEarlierToBatch] B${batchId}: Aikaistus rajoitettu ${earlierS.toFixed(1)}s → ${actualEarlier.toFixed(1)}s (min_time=${minTime}s, calc_time=${currentCalc.toFixed(1)}s)`);
        }
        
        // Päivitä erän calc_time_s (pienenee)
        if (actualEarlier > 0) {
            batch.calc_time_s = currentCalc - actualEarlier;
        }
    }
    
    // Aikaista kaikki saman erän tehtävät tästä stagesta eteenpäin
    // KRIITTINEN: Ei saa aikaistaa menneisyyteen!
    if (actualEarlier > 0) {
        for (const task of tasks) {
            if (task.batch_id === batchId && task.stage >= fromStage) {
                const newStartTime = task.task_start_time - actualEarlier;
                const newFinishedTime = task.task_finished_time - actualEarlier;
                
                // Estä menneisyyteen aikaistus: minimi on currentTimeSec + 1s
                if (newStartTime < currentTimeSec + 1) {
                    const maxAllowedEarlier = task.task_start_time - (currentTimeSec + 1);
                    if (maxAllowedEarlier > 0) {
                        task.task_start_time = currentTimeSec + 1;
                        task.task_finished_time -= maxAllowedEarlier;
                        console.warn(`[propagateEarlierToBatch] B${batchId} stage${task.stage}: Advance clamped ${actualEarlier.toFixed(1)}s → ${maxAllowedEarlier.toFixed(1)}s (cannot go to past, now=${currentTimeSec.toFixed(1)}s)`);
                    } else {
                        console.warn(`[propagateEarlierToBatch] B${batchId} stage${task.stage}: NOT ADVANCED - already in past (start=${task.task_start_time.toFixed(1)}s, now=${currentTimeSec.toFixed(1)}s)`);
                    }
                } else {
                    task.task_start_time = newStartTime;
                    task.task_finished_time = newFinishedTime;
                }
            }
        }
    }
    
    return { applied: actualEarlier, clamped };
}

/**
 * Propagoi viivästys erän kaikkiin tuleviin tehtäviin
 * 
 * TOIMINTAPERIAATE:
 * 1. Viivästetään saman erän TEHTÄVIÄ tästä stagesta eteenpäin (start/finish ajat)
 * 2. Päivitetään erän calc_time_s (kasvaa → hidastuu)
 * 
 * @param {Array} tasks - Kaikki tehtävät (muokataan in-place)
 * @param {Array} batches - Kaikki erät (muokataan in-place)
 * @param {number} batchId - Viivästettävän erän ID
 * @param {number} fromStage - Mistä stagesta alkaen viivästetään
 * @param {number} delayS - Viivästys sekunteina
 * @param {boolean} updateCalcTime - Päivitetäänkö calc_time_s (oletuksena false legacy-yhteensopivuus)
 */
function propagateDelayToBatch(tasks, batches, batchId, fromStage, delayS, updateCalcTime = false) {
    if (delayS <= 0) return { applied: 0, clamped: false };
    
    // 2. Hae erän tiedot ja laske sallittu viivästys
    const batch = batches.find(b => b && b.batch_id === batchId);
    let actualDelay = delayS;
    let clamped = false;
    
    if (batch) {
        // Päivitä batch.calc_time_s VAIN jos DELAY kohdistuu siihen stageen
        // jossa erä on NYT. batch.calc_time_s on nykyisen stagen aika,
        // ja RECALC_SCHEDULE lukee sen sieltä (remainingTime = calc - elapsed).
        // Muiden stagejen ajat menevät ohjelmaan (CHECK_UPDATE_PROGRAM).
        const batchCurrentStage = batch.stage === 90 ? 0 : (Number(batch.stage) || 0);
        const isCurrentStage = (fromStage === batchCurrentStage);
        
        if (isCurrentStage) {
            const currentCalc = Number(batch.calc_time_s) || 0;
            const maxTime = Number(batch.max_time_s) || Infinity;
            const availableFlex = Math.max(0, maxTime - currentCalc);
            
            // Rajoita viivästys sallittuun maksimiin (max_time_s on katto)
            if (delayS > availableFlex) {
                actualDelay = availableFlex;
                clamped = true;
                console.warn(`[propagateDelayToBatch] B${batchId}: Viivästys rajoitettu ${delayS.toFixed(1)}s → ${actualDelay.toFixed(1)}s (max_time=${maxTime}s, calc_time=${currentCalc.toFixed(1)}s)`);
            }
            
            if (actualDelay > 0) {
                batch.calc_time_s = currentCalc + actualDelay;
                console.log(`[propagateDelayToBatch] B${batchId}s${fromStage}: batch.calc_time_s ${currentCalc.toFixed(1)}→${batch.calc_time_s.toFixed(1)}s (erä on tällä asemalla)`);
            }
        }
    }
    
    // 1. Viivästä kaikki saman erän tehtävät tästä stagesta eteenpäin
    if (actualDelay > 0) {
        for (const task of tasks) {
            if (task.batch_id === batchId && task.stage >= fromStage) {
                task.task_start_time += actualDelay;
                task.task_finished_time += actualDelay;
            }
        }
    }
    
    return { applied: actualDelay, clamped };
}

/**
 * Etsi asema numeron perusteella
 * @param {number} stationNumber - Aseman numero
 * @param {Array} stations - Asemalista
 * @returns {object|null} Asema tai null
 */
function findStation(stationNumber, stations) {
    return stations.find(s => s.number === stationNumber) || null;
}

/**
 * Parsii ajan HH:MM:SS -> sekunteina
 * @param {string} timeStr - Aika muodossa "HH:MM:SS" tai "MM:SS"
 * @returns {number} Sekunnit
 */
function parseTimeToSeconds(timeStr) {
    if (!timeStr || typeof timeStr !== 'string') return 0;
    const parts = timeStr.split(':').map(Number);
    if (parts.length === 3) {
        return parts[0] * 3600 + parts[1] * 60 + parts[2];
    } else if (parts.length === 2) {
        return parts[0] * 60 + parts[1];
    }
    return 0;
}

/**
 * Muunna sekunnit aikamuotoon HH:MM:SS
 * @param {number} seconds - Sekunnit
 * @returns {string} Aika muodossa HH:MM:SS
 */
function formatSecondsToTime(seconds) {
    if (typeof seconds !== 'number' || isNaN(seconds)) return '00:00:00';
    const totalSec = Math.round(seconds);
    const hours = Math.floor(totalSec / 3600);
    const mins = Math.floor((totalSec % 3600) / 60);
    const secs = totalSec % 60;
    return `${String(hours).padStart(2, '0')}:${String(mins).padStart(2, '0')}:${String(secs).padStart(2, '0')}`;
}

// ═══════════════════════════════════════════════════════════════════════════════
// PÄÄFUNKTIOT
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Laske erän koko aikataulu
 * 
 * @param {object} batch - Erän tiedot (batch_id, location, treatment_program, stage)
 * @param {Array} program - Käsittelyohjelma (stages-lista)
 * @param {Array} stations - Asemat
 * @param {object} transporter - Nostin
 * @param {number} currentTimeSec - Nykyinen simulaatioaika (s)
 * @returns {object} Laskettu aikataulu
 */
function calculateBatchSchedule(
    batch,
    program,
    stations,
    transporter,
    currentTimeSec,
    isDelayed = false,
    transporterState = null,
    options = {}
) {
    console.log(`[CALC-SCHEDULE] batch_id=${batch?.batch_id}, stage=${batch?.stage}, location=${batch?.location}, program.length=${program?.length}`);

    const movementTimes = options && options.movementTimes ? options.movementTimes : null;
    const stationIdleSince = options && options.stationIdleSince ? options.stationIdleSince : new Map();
    const occupiedStations = options && options.occupiedStations ? options.occupiedStations : new Set();
    // Linjassa olevien erien aikataulut rinnakkaisaseman valintaan
    const lineSchedules = options && options.lineSchedules ? options.lineSchedules : [];
    const optUnits = options && options.units ? options.units : [];
    
    const result = {
        batch_id: batch.batch_id,
        calculated_at: currentTimeSec,
        stages: [],
        total_duration_s: 0,
        errors: [],
        isDelayed: isDelayed
    };
    
    if (!program || program.length === 0) {
        result.errors.push('Käsittelyohjelma puuttuu tai on tyhjä');
        console.log(`[CALC-SCHEDULE] ERROR: no program for batch ${batch?.batch_id}`);
        return result;
    }
    
    // Aloita nykyisestä vaiheesta
    // HUOM: batch.stage voi olla:
    // - 0-60: Erä prosessissa (käsittelyohjelman vaiheet)
    // - 90: Erä odottaa (Waiting)
    // - 61-89, 91+: Varattu tuleville ominaisuuksille
    let currentStage = (batch.stage !== undefined && batch.stage !== null) ? batch.stage : 0;
    
    // Odottava erä: stage 90 TAI stage 0 asemalla (juuri aktivoitu)
    // Stage 1-60 ovat kaikki prosessissa olevia eriä - samalla logiikalla
    const forceEntryTime = batch._forceEntryTime;
    const isWaitingBatch = currentStage === 90;
    
    // Stage 0 asemalla = juuri aktivoitu, lisää stage 0 scheduleen
    const batchUnitLoc = optUnits.length > 0
        ? (optUnits.find(u => u.batch_id === batch.batch_id)?.location ?? batch.location)
        : batch.location;
    const isStage0OnStation = currentStage === 0 && batchUnitLoc >= 100;
    
    // Jos stage 90, käsitellään kuten stage 0 (alkaa stage 1:stä)
    if (currentStage === 90) {
        currentStage = 0;
    }
    
    const currentLocation = batchUnitLoc;
    
    // Tarkista onko erä nostimessa (< 100) vai asemalla (>= 100)
    const isOnTransporter = currentLocation < 100;
    const isOnStation = currentLocation >= 100;

    if (currentStage === 0) {
        console.log(`[SCHEDULER] Calculating for Batch ${batch.batch_id} at Stage 0 (Start). Location: ${batchUnitLoc}, IsOnTransporter: ${isOnTransporter}`);
    }
    
    // Jos erä nostimessa, laske aikataulu SEURAAVASTA vaiheesta (stage + 1)
    // Jos erä asemalla, laske aikataulu NYKYISESTÄ vaiheesta (stage)
    let startStage = isOnTransporter ? currentStage + 1 : currentStage;
    
    // Jos startStage on 0 (esim. stage 90/0 asemalla), pakota se 1:ksi.
    // Tämä varmistaa, että loop alkaa stage 1:stä, ja nykyinen asema (Start)
    // käsitellään "batchStationDiffersFromProgram" -logiikalla (lisätään listan alkuun).
    if (startStage < 1) {
        startStage = 1;
    }
    
    // Etsi edellinen asema (mistä siirto alkaa)
    let prevStation = null;
    if (isOnStation) {
        // Erä asemalla -> prevStation = current station
        prevStation = findStation(currentLocation, stations);
        if (!prevStation) {
            result.errors.push(`Asemaa ${currentLocation} ei löydy`);
            return result;
        }
    } else if (isOnTransporter) {
        // Erä nostimessa -> etsi edellisen vaiheen asema (mistä nostettiin)
        const prevStageIdx = currentStage - 1; // stage on 1-based, array 0-based
        if (prevStageIdx >= 0 && prevStageIdx < program.length) {
            const prevStageStation = parseInt(program[prevStageIdx].min_station, 10);
            prevStation = findStation(prevStageStation, stations);
        } else if (currentStage === 0 && transporterState && transporterState.state) {
            // ERIKOISTAPAUS: Stage 0 nostimessa (juuri aloitettu)
            // Käytä nostimen lift_station_targetia lähtöasemana
            const liftStationId = transporterState.state.lift_station_target;
            if (liftStationId) {
                prevStation = findStation(liftStationId, stations);
            }
        }
    }
    
    // AIKATAULULOGIIKKA:
    // - Stage 0-60 (prosessissa): Erä on aktiivinen, aikataulu lasketaan currentTimeSec + remainingTime
    // - Stage 90 (odottava): Erä odottaa lähtölupaa, käytä forceEntryTime
    
    // Onko erä prosessissa (stage 0-60)?
    const isProcessingBatch = !isWaitingBatch;
    
    // prevExitTime = mistä seuraava vaihe alkaa
    let prevExitTime;
    
    if (isOnTransporter && transporterState) {
        // Erä nostimessa -> käytä nostimen arvioitua valmistumisaikaa
        const st = transporterState.state || {};
        const estFinish = Number(st.current_task_est_finish_s);
        if (Number.isFinite(estFinish) && estFinish > 0) {
            prevExitTime = estFinish;
        } else {
            prevExitTime = currentTimeSec;
        }
    } else if (isWaitingBatch && forceEntryTime !== undefined) {
        // Odottava erä (stage 90) -> käytä forceEntryTime
        prevExitTime = forceEntryTime;
        console.log(`[SCHEDULE] Batch ${batch.batch_id} stage=90 (waiting): forceEntryTime=${forceEntryTime.toFixed(1)}s`);
    } else {
        // Prosessissa oleva erä asemalla -> prevExitTime lasketaan ensimmäiselle stagelle erikseen
        prevExitTime = currentTimeSec;
    }
    
    // Kun erä on asemalla, käytä erän omia aikoja (batch.min_time_s, batch.calc_time_s) 
    // kyseiselle asemalle - riippumatta onko asema ohjelman mukainen vai ei
    const batchCalcTimeS = Number(batch.calc_time_s) || 0;
    const batchMinTimeS = Number(batch.min_time_s) || 0;
    const batchMaxTimeS = Number(batch.max_time_s) || 0;
    
    // JÄLJELLÄ OLEVA AIKA: calc_time_s on kokonaisaika, start_time on saapumisaika (ms)
    // Jäljellä = calc_time_s - (currentTimeSec - start_time/1000)
    // MINIMI 1s: Nostin ei voi siirtyä hakemaan erää historiassa, vaan aikaisintaan "hetken" päästä
    const batchStartTimeMs = Number(batch.start_time) || 0;
    const elapsedOnStation = currentTimeSec - (batchStartTimeMs / 1000);
    const remainingTimeS = Math.max(1, batchCalcTimeS - elapsedOnStation);
    
    // KORJAUS: usedEstFinish vaikuttaa VAIN ensimmäiseen stageen
    // Kun erä on nostimessa ja nostimella on arvioitu valmistumisaika,
    // ensimmäisen stagen entry_time = est_finish (ei lisätä siirtoaikaa, koska siirto on kesken)
    // Seuraavissa stageissa siirtoaika lisätään normaalisti.
    //
    // HUOM: Tarkistetaan vain onko estFinish olemassa ja positiivinen - EI verrta currentTimeSec:iin!
    // Jos verrattaisiin (estFinish > currentTimeSec), aikatalu "pomppisi" kun nostin lähestyy valmistumista,
    // koska silloin ehto muuttuisi false:ksi ja siirtoaika lisättäisiin vahingossa.
    let useEstFinishForFirstStage = false;
    if (isOnTransporter && transporterState) {
        const st = transporterState.state || {};
        const estFinish = Number(st.current_task_est_finish_s);
        // Riittää että estFinish on validi ja positiivinen - erä on yhä nostimessa
        if (Number.isFinite(estFinish) && estFinish > 0) {
            useEstFinishForFirstStage = true;
        }
    }
    let isFirstStageInLoop = true;
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // STAGE 0: Lisää scheduleen kun erä on stage 0:ssa (odottava TAI juuri aktivoitu)
    // 
    // Stage 0 ajat tulevat BATCH-TIEDOISTA (batch.calc_time_s, min_time_s, max_time_s).
    // DEPARTURE CALC -vaihe laskee nämä idle-sloteista ENNEN tätä funktiota:
    //   CalcTime = MinTime = pickup_time - start_time
    //   MaxTime = 2 × MinTime
    // Näin stage 0:n kesto vaikuttaa oikein stage 1+ ajoitukseen.
    // ═══════════════════════════════════════════════════════════════════════════════
    const isStage0Active = isStage0OnStation;
    
    if ((isWaitingBatch || isStage0Active) && isOnStation && prevStation) {
        // Ajat suoraan batch-tiedoista
        // Stage 0 oletus: calc=0 (erä lähtee heti), min=0, max=120s
        const calcTimeS = Number(batch.calc_time_s) || 0;
        const minTimeS = Number(batch.min_time_s) || 0;
        const maxTimeS = Number(batch.max_time_s) || 120;
        console.log(`[SCHEDULE-DEBUG] B${batch.batch_id}: batch.calc_time_s raw=${JSON.stringify(batch.calc_time_s)} → calcTimeS=${calcTimeS}`);
        
        // Entry time
        let stage0Entry;
        if (isStage0Active) {
            stage0Entry = (batch.start_time || 0) / 1000;
        } else {
            stage0Entry = forceEntryTime !== undefined ? forceEntryTime : currentTimeSec;
        }
        
        // Exit time = entry + calc_time (aktivoidulle: jäljellä oleva aika)
        let stage0Exit;
        if (isStage0Active) {
            const elapsedSec = Math.max(0, currentTimeSec - stage0Entry);
            const remainingSec = Math.max(1, calcTimeS - elapsedSec);
            stage0Exit = currentTimeSec + remainingSec;
        } else {
            stage0Exit = stage0Entry + calcTimeS;
        }
        
        result.stages.push({
            stage: 0,
            station: prevStation.number,
            station_name: prevStation.name || `Station ${prevStation.number}`,
            entry_time_s: Math.round(stage0Entry * 100) / 100,
            exit_time_s: Math.round(stage0Exit * 100) / 100,
            treatment_time_s: calcTimeS,
            transfer_time_s: 0,
            min_time_s: minTimeS,
            max_time_s: maxTimeS,
            min_exit_time_s: Math.round((stage0Entry + minTimeS) * 100) / 100,
            max_exit_time_s: Math.round((stage0Entry + maxTimeS) * 100) / 100,
            transfer_details: null
        });
        
        isFirstStageInLoop = false;
        prevExitTime = stage0Exit;
        
        console.log(`[SCHEDULE] B${batch.batch_id}: Stage 0 at station ${prevStation.number}, entry=${stage0Entry.toFixed(1)}s, exit=${stage0Exit.toFixed(1)}s, calc=${calcTimeS}s, min=${minTimeS}s, max=${maxTimeS}s, active=${isStage0Active}`);
    }
    
    // Käy läpi kaikki vaiheet alkaen start stagesta
    for (let stageIdx = startStage - 1; stageIdx < program.length; stageIdx++) {
        const stage = program[stageIdx];
        const stageNum = stageIdx + 1;
        
        // Parsii ajat (CSV käyttää alaviivallisia nimiä)
        const minTimeS = parseTimeToSeconds(stage.min_time);
        const maxTimeS = parseTimeToSeconds(stage.max_time);
        const calcTimeS = parseTimeToSeconds(stage.calc_time);
        
        // DEBUG: Logita calc_time joka stagelle (ensimmäiset 3 stagea)
        if (stageNum <= 3) {
            console.log(`[SCHEDULE-DEBUG] B${batch.batch_id} stage${stageNum}: calc_time=${stage.calc_time} (${calcTimeS}s)`);
        }
        
        // ═══════════════════════════════════════════════════════════════
        // RINNAKKAISET ASEMAT: Valitse kohde-asema
        // Jos stagella on rinnakkaisia asemia (MinStat != MaxStat, sama group),
        // valitaan vapaa asema joka EI OLE VARATTU linjalla olevien aikatauluissa
        // ═══════════════════════════════════════════════════════════════
        const parallelStations = getParallelStations(stage, stations);
        
        // Lasketaan ensin alustavat ajat (käyttäen ensimmäistä rinnakkaisasemaa)
        // jotta voidaan valita oikea asema aikataulujen perusteella
        let prelimStation = parallelStations.length > 0 ? parallelStations[0] : null;
        if (!prelimStation) {
            const minStatNum = parseInt(stage.min_station, 10);
            prelimStation = findStation(minStatNum, stations);
        }
        
        // Laske alustava siirtoaika (huomioi poikittaissiirtokuljetin)
        let prelimTransferResult = { transferTime: { total_s: 0, details: null }, crossEndStation: null, isCrossTransfer: false };
        if (prevStation && prelimStation && prevStation.number !== prelimStation.number) {
            prelimTransferResult = calculateTransferTimeWithCrossCheck(prevStation, prelimStation, transporter, stations, movementTimes);
        }
        const prelimTransferTime = prelimTransferResult.transferTime;
        
        // Laske alustavat entry/exit (tarvitaan rinnakkaisaseman valintaan)
        // Lasketaan ETEENPÄIN: Entry ensin, Exit = Entry + CalcTime
        let prelimEntryTime, prelimExitTime;
        const isFirstStageAndBatchOnStation = isFirstStageInLoop && isOnStation;
        
        if (isFirstStageAndBatchOnStation) {
            // Erä on asemalla - Entry = nykyhetki, Exit = nykyhetki + remainingTime
            prelimEntryTime = currentTimeSec;
            prelimExitTime = currentTimeSec + remainingTimeS;
        } else {
            prelimEntryTime = prevExitTime + prelimTransferTime.total_s;
            prelimExitTime = prelimEntryTime + calcTimeS;
        }
        
        // Valitse paras rinnakkaisasema (aikataulujen perusteella)
        let targetStation;
        let targetStationNum;
        
        if (parallelStations.length > 1) {
            // Rinnakkaisia asemia - valitse paras AIKATAULUJEN perusteella
            const occupiedStations = options?.occupiedStations || new Set();
            const stationIdleSince = options?.stationIdleSince || new Map();
            const lineSchedules = options?.lineSchedules || [];
            
            const scheduleContext = {
                lineSchedules: lineSchedules,
                stageNum: stageNum,
                entryTime: prelimEntryTime,
                exitTime: prelimExitTime
            };
            
            targetStation = selectBestParallelStation(
                parallelStations, 
                occupiedStations, 
                stationIdleSince, 
                currentTimeSec,
                scheduleContext
            );
            targetStationNum = targetStation?.number;
        } else if (parallelStations.length === 1) {
            // Vain yksi asema
            targetStation = parallelStations[0];
            targetStationNum = targetStation.number;
        } else {
            // Fallback: käytä min_station
            targetStationNum = parseInt(stage.min_station, 10);
            targetStation = findStation(targetStationNum, stations);
        }
        
        if (!targetStation) {
            result.errors.push(`Asemaa ${targetStationNum} ei löydy (stage ${stageNum})`);
            continue;
        }
        
        // Laske LOPULLINEN siirtoaika (valitulle asemalle) - huomioi poikittaissiirtokuljetin
        let transferResult = { transferTime: { total_s: 0, details: null }, crossEndStation: null, isCrossTransfer: false };
        if (prevStation && prevStation.number !== targetStationNum) {
            transferResult = calculateTransferTimeWithCrossCheck(prevStation, targetStation, transporter, stations, movementTimes);
        }
        const transferTime = transferResult.transferTime;
        
        // AIKATAULULOGIIKKA - Lasketaan ETEENPÄIN: Entry ensin, Exit = Entry + CalcTime
        // Kaikki ajat ovat ABSOLUUTTISIA (simulaatioaika)
        let entryTime, exitTime;
        
        if (isFirstStageAndBatchOnStation) {
            // ERÄ ON ASEMALLA - Entry = nykyhetki, Exit = nykyhetki + remainingTime (min 1s)
            entryTime = currentTimeSec;
            exitTime = currentTimeSec + remainingTimeS;
        } else if (isFirstStageInLoop && useEstFinishForFirstStage) {
            // ERÄ ON NOSTIMESSA: Siirto on jo käynnissä
            // Entry = estFinish (prevExitTime), ei lisätä siirtoaikaa uudelleen!
            entryTime = prevExitTime;
            exitTime = entryTime + calcTimeS;
        } else {
            // MUUT VAIHEET: Entry = edellinen exit + siirtoaika, Exit = Entry + CalcTime
            entryTime = prevExitTime + transferTime.total_s;
            exitTime = entryTime + calcTimeS;
        }
        
        // Tallenna vaihe
        const stageResult = {
            stage: stageNum,
            station: targetStationNum,
            station_name: targetStation.name,
            entry_time_s: Math.round(entryTime * 100) / 100,
            exit_time_s: Math.round(exitTime * 100) / 100,
            treatment_time_s: calcTimeS,
            transfer_time_s: Math.round(transferTime.total_s * 100) / 100,
            min_time_s: minTimeS,
            max_time_s: maxTimeS,
            transfer_details: transferTime.details
        };
        
        // Absoluuttiset min/max exit-ajat (UI:ta varten)
        // Kun erä on asemalla: laske jäljellä olevat ajat min:iin ja max:iin
        // Muuten: laske entry + min/max
        if (isFirstStageAndBatchOnStation && batchStartTimeMs > 0) {
            // Erä on asemalla - laske jäljellä olevat ajat
            const remainingToMin = Math.max(0, minTimeS - elapsedOnStation);
            const remainingToMax = Math.max(0, maxTimeS - elapsedOnStation);
            stageResult.min_exit_time_s = Math.round((currentTimeSec + remainingToMin) * 100) / 100;
            stageResult.max_exit_time_s = Math.round((currentTimeSec + remainingToMax) * 100) / 100;
        } else {
            // Tulevaisuuden stage - laske entry + min/max
            stageResult.min_exit_time_s = Math.round((entryTime + minTimeS) * 100) / 100;
            stageResult.max_exit_time_s = Math.round((entryTime + maxTimeS) * 100) / 100;
        }
        
        // Rinnakkaiset asemat: tallenna vaihtoehdot jos niitä on
        if (parallelStations.length > 1) {
            stageResult.parallel_stations = parallelStations.map(s => s.number);
            stageResult.selected_from_parallel = true;
        }
        
        // Poikittaissiirtokuljetin: tallenna "toinen pää" -asema tehtävälistaa varten
        if (transferResult.isCrossTransfer && transferResult.crossEndStation) {
            stageResult.cross_transfer = true;
            stageResult.cross_end_station = transferResult.crossEndStation.number;
        }
        
        result.stages.push(stageResult);
        
        // Päivitä edellinen
        prevExitTime = exitTime;
        prevStation = targetStation;
        isFirstStageInLoop = false; // Seuraavat staget eivät ole ensimmäisiä
    }
    
    // Kokonaiskesto (suhteellinen: viimeisen stagen exit_time, koska ensimmäisen entry=0)
    if (result.stages.length > 0) {
        result.total_duration_s = result.stages[result.stages.length - 1].exit_time_s;
    }
    
    return result;
}

/**
 * Tulosta aikataulu konsoliin (debug)
 * @param {object} scheduleResult - calculateBatchSchedule:n tulos
 */
function printSchedule(scheduleResult) {
    console.log('\n═══════════════════════════════════════════════════════════════════');
    console.log(`  ERÄN ${scheduleResult.batch_id} AIKATAULU`);
    console.log(`  Laskettu ajanhetkellä: ${scheduleResult.calculated_at}s`);
    console.log('═══════════════════════════════════════════════════════════════════');
    
    if (scheduleResult.errors.length > 0) {
        console.log('\n  VIRHEET:');
        scheduleResult.errors.forEach(e => console.log(`    - ${e}`));
    }
    
    console.log('\n  ┌────────┬─────────┬────────────┬────────────┬────────────┬────────────┐');
    console.log('  │ Stage  │ Asema   │ Entry (s)  │ Exit (s)   │ Käsittely  │ Siirto     │');
    console.log('  ├────────┼─────────┼────────────┼────────────┼────────────┼────────────┤');
    
    scheduleResult.stages.forEach(s => {
        const stage = String(s.stage).padStart(6);
        const station = String(s.station).padStart(7);
        const entry = String(s.entry_time_s.toFixed(1)).padStart(10);
        const exit = String(s.exit_time_s.toFixed(1)).padStart(10);
        const treatment = String(s.treatment_time_s).padStart(10);
        const transfer = String(s.transfer_time_s.toFixed(1)).padStart(10);
        console.log(`  │${stage} │${station} │${entry} │${exit} │${treatment} │${transfer} │`);
    });
    
    console.log('  └────────┴─────────┴────────────┴────────────┴────────────┴────────────┘');
    console.log(`\n  Kokonaiskesto: ${scheduleResult.total_duration_s.toFixed(1)}s (${(scheduleResult.total_duration_s / 60).toFixed(1)} min)`);
    console.log('═══════════════════════════════════════════════════════════════════\n');
}

/**
 * Tulosta siirron erittely (debug)
 * @param {object} stage - Vaiheen tiedot
 */
function printTransferDetails(stage) {
    if (!stage.transfer_details) {
        console.log(`  Stage ${stage.stage}: Ei siirtoa (sama asema)`);
        return;
    }
    
    const d = stage.transfer_details;
    console.log(`\n  Stage ${stage.stage} siirto → ${stage.station}:`);
    console.log(`    Nosto:`);
    console.log(`      - device_delay:    ${d.fromDeviceDelay.toFixed(2)}s`);
    console.log(`      - liftTime:        ${d.liftTime.toFixed(2)}s`);
    console.log(`      - dropping_time:   ${d.fromDroppingTime.toFixed(2)}s`);
    console.log(`      - drip_delay:      ${d.dripDelay.toFixed(2)}s`);
    console.log(`    Vaakasiirto:`);
    console.log(`      - X-etäisyys:      ${d.xDistance}mm`);
    console.log(`      - X-aika:          ${d.xTime.toFixed(2)}s`);
    console.log(`    Lasku:`);
    console.log(`      - device_delay:    ${d.toDeviceDelay.toFixed(2)}s`);
    console.log(`      - sinkTime:        ${d.sinkTime.toFixed(2)}s`);
    console.log(`    ────────────────────────────`);
    console.log(`    YHTEENSÄ:            ${stage.transfer_time_s.toFixed(2)}s`);
}

/**
 * Muodosta tehtävälista aikataulusta
 * 
 * Dokumentti: Exit_time on tehtävän nostoasema ja alkuaika,
 *             Entry_time seuraavalla asemalla on laskuasema ja loppuaika
 * 
 * @param {object} scheduleResult - calculateBatchSchedule:n tulos
 * @param {object} batch - Erän tiedot
 * @returns {Array} Tehtävälista
 */
/**
 * Check if a transporter can handle a task based on its work areas
 * @param {Object} transporter - Transporter object with task_areas
 * @param {number} liftStation - Lift station ID
 * @param {number} sinkStation - Sink station ID
 * @returns {boolean} True if transporter can handle both lift and sink
 */
function canTransporterHandleTask(transporter, liftStation, sinkStation) {
    if (!transporter || !transporter.task_areas) {
        return false;
    }
    
    // Check all task areas (line_100, line_200, etc.)
    for (const areaKey in transporter.task_areas) {
        const area = transporter.task_areas[areaKey];
        
        // Skip areas that are not configured (min = 0 AND max = 0)
        if (area.min_lift_station === 0 && area.max_lift_station === 0 &&
            area.min_sink_station === 0 && area.max_sink_station === 0) {
            continue;
        }
        
        // Check if both lift and sink stations are within this same area
        const canLift = liftStation >= area.min_lift_station && liftStation <= area.max_lift_station;
        const canSink = sinkStation >= area.min_sink_station && sinkStation <= area.max_sink_station;
        
        // If both are in this area, transporter can handle the task
        if (canLift && canSink) {
            return true;
        }
    }
    
    return false;
}

function createTaskListFromSchedule(scheduleResult, batch, transporters = []) {
    const tasks = [];
    
    if (!scheduleResult || !scheduleResult.stages || scheduleResult.stages.length === 0) {
        return tasks;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // TEHTÄVÄLISTA SCHEDULEN STAGEISTA
    // Schedule sisältää kaikki staget mukaan lukien stage 0 (jos erä on Start-asemalla).
    // Jokainen stage paitsi viimeinen luo siirtotehtävän seuraavaan stageen.
    // Stage 0:n ajat (min_time, calc_time, max_time) tulevat schedulesta,
    // johon ne on asetettu batchin arvoista (aktivoinnin yhteydessä).
    // 
    // KRIITTINEN FIX: Ohita jo suoritetut staget!
    // Jos erä on stagella N (N < 90), se on jo siirtynyt stageille 0..N-1.
    // Näiden tehtävien EI pidä olla enää tehtävälistalla, koska ne aiheuttavat
    // vääriä konflikteja departure-laskennassa.
    // Stage N:n tehtävä (siirto stagelle N+1) ON vielä tekemättä.
    // 
    // HUOM: Stage 90 = "odottaa linjalle pääsyä" - tämä EI tarkoita että 90 stagea
    // on suoritettu! Stage 90:n erille luodaan KAIKKI tehtävät (stage 0→13).
    // ═══════════════════════════════════════════════════════════════════════════════
    const batchCurrentStage = batch?.stage ?? 0;
    
    // Stage 90 on erikoistapaus: erä odottaa linjalle, ei ole suorittanut mitään stagea
    // Muille stageille: ohita jo suoritetut staget
    const skipBeforeStage = (batchCurrentStage === 90) ? 0 : batchCurrentStage;
    
    // Käy läpi kaikki vaiheet (paitsi viimeinen, josta ei enää siirretä)
    for (let i = 0; i < scheduleResult.stages.length - 1; i++) {
        const currentStage = scheduleResult.stages[i];
        const nextStage = scheduleResult.stages[i + 1];
        
        // KRIITTINEN: Ohita jo suoritetut staget (paitsi stage 90 -erille)
        // Tehtävä stagen X siirtoa varten luodaan kun currentStage.stage === X
        // Jos batch.stage > X (ja batch.stage < 90), erä on jo siirtynyt stagelta X → X+1
        if (currentStage.stage < skipBeforeStage) {
            continue; // Tämä tehtävä on jo suoritettu - ohita
        }
        
        // Nostoasema: jos seuraava stage on poikittaissiirto, käytä cross_end_station
        // (poikittaissiirtokuljetin siirtää erän "toiseen päähän", josta nostin nostaa)
        let liftStation = currentStage.station;
        const sinkStation = nextStage.station;
        
        // Tarkista onko seuraava siirto poikittaissiirto (cross_transfer on määritelty nextStage:ssa)
        // HUOM: cross_transfer ja cross_end_station ovat EDELLISESSÄ stagessa (sieltä lähtevä siirto)
        // koska siirtoaika lasketaan edellisestä stagesta seuraavaan
        // Mutta tässä vaiheessa meidän pitää tarkistaa NYKYINEN stage (currentStage) koska
        // siitä lähdetään siirtämään
        // --> Oikeastaan transfer_details on nykyisen stagen exit → seuraavan stagen entry
        //     Joten cross_transfer info on SEURAAVAN stagen transfer_details:ssa
        //     MUTTA: calculateBatchSchedule tallentaa sen stageResult-olioon, ei transferTime.details:iin
        //     Tarkistetaan nextStage.cross_transfer
        if (nextStage.cross_transfer && nextStage.cross_end_station) {
            liftStation = nextStage.cross_end_station;
            console.log(`[TASK-LIST] Stage ${currentStage.stage}→${nextStage.stage}: Cross-transfer detected, using lift_station=${liftStation} (was ${currentStage.station})`);
        }
        
        // Try to assign transporter based on work areas
        let assignedTransporterId = null;
        
        if (transporters && transporters.length > 0) {
            // Find transporters that can handle this task
            const capableTransporters = transporters.filter(t => 
                canTransporterHandleTask(t, liftStation, sinkStation)
            );
            
            // Debug: log task assignment for stages 6-8 (known problem area)
            if (currentStage.stage >= 6 && currentStage.stage <= 8) {
                console.log(`[TASK-ASSIGN] B${batch.batch_id}s${currentStage.stage}: lift=${liftStation}, sink=${sinkStation}, capable=[${capableTransporters.map(t => 'T'+t.id).join(',')}]`);
            }
            
            // If only one transporter can handle it, assign immediately
            if (capableTransporters.length === 1) {
                assignedTransporterId = capableTransporters[0].id;
            }
            // If multiple transporters can handle it, pick the one with fewest tasks so far
            // Tiebreaker: jos tehtävämäärä on tasan, valitaan nostin jonka alueen keskipiste
            // on lähempänä nostoasemaa (luonnollisempi valinta)
            else if (capableTransporters.length > 1) {
                // Laske kullekin nostimelle jo myönnettyjen tehtävien määrä
                // ja edellisen tehtävän kohteen etäisyys nostoasemasta
                const scored = capableTransporters.map(t => {
                    const tTasks = tasks.filter(tk => tk.transporter_id === t.id);
                    const count = tTasks.length;
                    // Edellisen tehtävän sink-asema = nostimen viimeisin sijainti
                    // Jos tehtäviä on, käytä viimeisen sink_station_id:tä
                    // Jos ei ole, käytä start_station
                    let lastSinkStation = t.start_station || 0;
                    if (tTasks.length > 0) {
                        // Aikajärjestys: viimeisin tehtävä
                        const sorted = tTasks.slice().sort((a, b) => (a.task_finished_time || 0) - (b.task_finished_time || 0));
                        lastSinkStation = sorted[sorted.length - 1].sink_station_id || lastSinkStation;
                    }
                    const distFromLastTask = Math.abs(lastSinkStation - liftStation);
                    // Alueen keskipiste varalla (jos edellisten tehtävien etäisyys tasan)
                    let areaCenter = 0;
                    let areaCount = 0;
                    for (const areaKey in t.task_areas) {
                        const area = t.task_areas[areaKey];
                        if (area.min_lift_station > 0 && area.max_lift_station > 0) {
                            areaCenter += (area.min_lift_station + area.max_lift_station) / 2;
                            areaCount++;
                        }
                    }
                    areaCenter = areaCount > 0 ? areaCenter / areaCount : 0;
                    const distToLift = Math.abs(areaCenter - liftStation);
                    return { t, count, distFromLastTask, distToLift };
                });
                // Järjestä: 1) vähiten tehtäviä, 2) lähimpänä edellisestä tehtävästä, 3) aluekeskipiste
                scored.sort((a, b) => a.count - b.count || a.distFromLastTask - b.distFromLastTask || a.distToLift - b.distToLift);
                const best = scored[0];
                assignedTransporterId = best.t.id;
                console.log(`[TASK-ASSIGN] B${batch.batch_id}s${currentStage.stage}: overlap ${liftStation}→${sinkStation}, assigned T${best.t.id} (${best.count} tasks, lastDist=${best.distFromLastTask}, areaDist=${best.distToLift.toFixed(0)}, candidates=[${scored.map(s => 'T'+s.t.id+'('+s.count+',ld'+s.distFromLastTask+',ad'+s.distToLift.toFixed(0)+')').join(',')}])`);
            }
        }
        
        // Tehtävän tiedot:
        // - Nostoasema = nykyisen vaiheen asema TAI cross_end_station (poikittaissiirto)
        // - Laskuasema = seuraavan vaiheen asema
        // - Alkuaika = nykyisen vaiheen exit_time (kun erä nostetaan)
        // - Loppuaika = seuraavan vaiheen entry_time (kun erä lasketaan)
        // - calc_time_s, min_time_s ja max_time_s: joustovaran laskentaan konflikteissa
        const task = {
            transporter_id: assignedTransporterId,          // Assigned if only one transporter can do it
            batch_id: batch.batch_id,
            treatment_program_id: batch.treatment_program,
            stage: currentStage.stage,
            lift_station_id: liftStation,
            sink_station_id: sinkStation,
            task_start_time: currentStage.exit_time_s,
            task_finished_time: nextStage.entry_time_s,
            calc_time_s: currentStage.treatment_time_s || 0,
            min_time_s: currentStage.min_time_s || 0,
            max_time_s: currentStage.max_time_s || 0
        };
        
        // Lisää tieto poikittaissiirrosta tehtävään
        if (nextStage.cross_transfer && nextStage.cross_end_station) {
            task.cross_transfer = true;
            task.original_lift_station = currentStage.station;
        }
        
        tasks.push(task);
    }
    
    return tasks;
}

/**
 * Tulosta tehtävälista konsoliin (debug)
 * @param {Array} tasks - Tehtävälista
 */
function printTaskList(tasks) {
    if (!tasks || tasks.length === 0) {
        console.log('\n  Ei tehtäviä');
        return;
    }
    
    console.log('\n═══════════════════════════════════════════════════════════════════');
    console.log(`  TEHTÄVÄLISTA (${tasks.length} tehtävää)`);
    console.log('═══════════════════════════════════════════════════════════════════');
    console.log('\n  ┌────────┬─────────┬───────┬──────────┬──────────┬───────────┬──────────────┐');
    console.log('  │ Erä    │ Ohjelma │ Stage │ Nosto    │ Lasku    │ Alku (s)  │ Loppu (s)    │');
    console.log('  ├────────┼─────────┼───────┼──────────┼──────────┼───────────┼──────────────┤');
    
    tasks.forEach(t => {
        const batch = String(t.batch_id).padStart(6);
        const program = String(t.treatment_program_id).padStart(7);
        const stage = String(t.stage).padStart(5);
        const lift = String(t.lift_station_id).padStart(8);
        const sink = String(t.sink_station_id).padStart(8);
        const start = String(t.task_start_time.toFixed(1)).padStart(9);
        const finish = String(t.task_finished_time.toFixed(1)).padStart(12);
        console.log(`  │${batch} │${program} │${stage} │${lift} │${sink} │${start} │${finish} │`);
    });
    
    console.log('  └────────┴─────────┴───────┴──────────┴──────────┴───────────┴──────────────┘');
    console.log('═══════════════════════════════════════════════════════════════════\n');
}

// ═══════════════════════════════════════════════════════════════════════════════
// KONFLIKTILUOKKIEN TUNNISTUS (LOCAL_FORWARD, LOCAL_BACKWARD, LOCAL_COMBINED)
// Dokumentaatio: StateMachine_Detailed_Design.md kohta 6.0.1
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Laske YHDEN STAGEN jousto (ei koko ketjun)
 * 
 * KORJATTU LOGIIKKA:
 * Kun viivästetään stagea N ja propagoidaan (siirretään koko loppuketjua):
 * - Stage N: calc_time kasvaa → kuluttaa stage N:n joustoa
 * - Stage N+1, N+2, ...: calc_time PYSYY SAMANA, vain start_time siirtyy
 *   → Myöhempien stagejen jousto EI KULU
 * 
 * Siksi palautetaan VAIN kyseisen stagen jousto, ei minimiä ketjusta.
 * 
 * @param {object} program - Erän käsittelyohjelma (stages array)
 * @param {number} fromStage - Stage jonka jousto lasketaan (1-based)
 * @param {string} direction - 'up' (viivästys, max-calc) tai 'down' (aikaistus, calc-min)
 * @returns {number} Stagen jousto sekunteina
 */
function calculateChainFlex(program, fromStage, direction) {
    if (!program || !Array.isArray(program) || program.length === 0) {
        return 0;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // KETJUJOUSTO: Laske stageiden joustojen SUMMA
    // 
    // Konflikti B2s3 vs B1s5, deficit=15s, B1s5.flex_up=10s:
    // - B1s5 voi viivästyä vain 10s → EI RIITÄ
    // - MUTTA jos B1s4 voi viivästyä 5s, se siirtää B1s5:n alkua 5s myöhemmäksi
    // - Yhteensä: 5s (B1s4 viivästys) + 10s (B1s5 oma jousto) = 15s → RIITTÄÄ!
    // 
    // Ketjujousto = oma jousto + edellisten stageiden joustojen summa
    // 
    // HUOM: Stage 0 (odottava erä) saa joustoa KAIKISTA stagesta (1 → n)
    // koska odottava erä voi viivästyä rajattomasti (ei ole vielä linjalla)
    // ═══════════════════════════════════════════════════════════════════════════
    
    // Stage 0 (waiting batch) - käytä koko ohjelman joustoa
    // Task stage 0 = siirto Start → Stage 1, joten jousto lasketaan stagesta 1 eteenpäin
    const stageIndex = fromStage <= 0 ? 0 : fromStage - 1;  // 0-indexed, min 0
    if (stageIndex >= program.length) {
        return 0;
    }
    
    let totalFlex = 0;
    
    // Käy läpi kaikki staget ALUSTA konflikti-stageen asti
    // Jokaisen stagen jousto voidaan käyttää siirtämään konflikti-stagea
    for (let i = 0; i <= stageIndex; i++) {
        const stage = program[i];
        if (!stage) continue;
        
        const calc = parseTimeToSeconds(stage.calc_time) || parseTimeToSeconds(stage.min_time) || 0;
        const min = parseTimeToSeconds(stage.min_time) || 0;
        const max = parseTimeToSeconds(stage.max_time) || calc;
        
        const flex = direction === 'up' 
            ? max - calc   // Viivästysjousto
            : calc - min;  // Aikaistusjousto
        
        const safeFlex = Math.max(0, flex);
        totalFlex += safeFlex;
    }
    
    return totalFlex;
}

/**
 * Etsi seuraava tehtävä joka kuuluu ERI erälle
 * @param {Array} allPairs - Kaikki tehtäväparit
 * @param {number} excludeBatchId - Erä jota EI haeta
 * @param {number} afterTime - Etsitään tehtävää joka alkaa tämän jälkeen
 * @returns {object|null} Seuraava muu tehtävä tai null
 */
function findNextTaskByOtherBatch(allPairs, excludeBatchId, afterTime) {
    const allTasks = [];
    for (const p of allPairs) {
        allTasks.push(p.prevTask);
        allTasks.push(p.nextTask);
    }
    
    return allTasks
        .filter(t => t.batch_id !== excludeBatchId)
        .filter(t => t.start_time > afterTime)
        .sort((a, b) => a.start_time - b.start_time)[0] || null;
}

/**
 * Etsi edellinen tehtävä joka kuuluu ERI erälle
 * @param {Array} allPairs - Kaikki tehtäväparit
 * @param {number} excludeBatchId - Erä jota EI haeta
 * @param {number} beforeTime - Etsitään tehtävää joka loppuu ennen tätä
 * @returns {object|null} Edellinen muu tehtävä tai null
 */
function findPrevTaskByOtherBatch(allPairs, excludeBatchId, beforeTime) {
    const allTasks = [];
    for (const p of allPairs) {
        allTasks.push(p.prevTask);
        allTasks.push(p.nextTask);
    }
    
    return allTasks
        .filter(t => t.batch_id !== excludeBatchId)
        .filter(t => t.finished_time < beforeTime)
        .sort((a, b) => b.finished_time - a.finished_time)[0] || null;
}

/**
 * Hae erän seuraavan stagen flex-arvot
 * @param {Array} allPairs - Kaikki tehtäväparit
 * @param {number} batchId - Erän ID
 * @param {number} currentStage - Nykyinen stage
 * @returns {object|null} { flex_down, flex_up } tai null
 */
function getNextStageFlex(allPairs, batchId, currentStage) {
    for (const p of allPairs) {
        if (p.prevTask.batch_id === batchId && p.prevTask.stage === currentStage + 1) {
            return { flex_down: p.prevTask.flex_down, flex_up: p.prevTask.flex_up };
        }
        if (p.nextTask.batch_id === batchId && p.nextTask.stage === currentStage + 1) {
            return { flex_down: p.nextTask.flex_down, flex_up: p.nextTask.flex_up };
        }
    }
    return null;
}

/**
 * Luokittele yksittäinen konflikti LOCAL_FORWARD, LOCAL_BACKWARD tai LOCAL_COMBINED
 * 
 * KOLME EHTOA JOKAISESSA LOCAL-LUOKASSA:
 * 1. flex-ehto (riittävä jousto)
 * 2. kompensaatioehto (seuraava stage voi kompensoida)
 * 3. törmäysehto (siirto ei aiheuta UUTTA konfliktia muihin eriin)
 * 
 * @param {object} conflict - Yksittäinen konflikti analyzeTaskConflicts():stä
 * @param {Array} allPairs - Kaikki tehtäväparit
 * @param {number} travelTime - Siirtymäaika (conflict.timing.travel_time)
 * @returns {object|null} { type, target, deficit, ... } tai null
 */
function classifySingleConflict(conflict, allPairs, travelTime) {
    const deficit = conflict.timing.deficit;
    const A = conflict.prevTask;  // Aikaisempi (sen viivästys aiheuttaa konfliktin)
    const B = conflict.nextTask;  // Myöhempi (sen aikaistus tarvitaan)
    
    // Hae seuraavien stagien flex-arvot
    const A_nextFlex = getNextStageFlex(allPairs, A.batch_id, A.stage);
    const B_nextFlex = getNextStageFlex(allPairs, B.batch_id, B.stage);
    
    // DEBUG: Logita miksi konflikti EI ole LOCAL
    const debugId = `B${A.batch_id}s${A.stage} vs B${B.batch_id}s${B.stage}`;
    console.log(`[CLASSIFY-DEBUG] ${debugId}: deficit=${deficit.toFixed(1)}s`);
    console.log(`  A (B${A.batch_id}s${A.stage}): flex_down=${A.flex_down}, nextFlex=${A_nextFlex ? `up=${A_nextFlex.flex_up}` : 'null'}`);
    console.log(`  B (B${B.batch_id}s${B.stage}): flex_up=${B.flex_up}, nextFlex=${B_nextFlex ? `down=${B_nextFlex.flex_down}` : 'null'}`);
    
    // ═══════════════════════════════════════════════════════════════════════════
    // VAIHTOEHTO 1: LOCAL_FORWARD - Viivästä B:tä (nextTask)
    // ═══════════════════════════════════════════════════════════════════════════
    const forwardCheck = {
        ehto1: B.flex_up >= deficit,
        ehto2: B_nextFlex && B_nextFlex.flex_down >= deficit,
        ehto3: false,
        ehto3_details: null
    };
    
    if (forwardCheck.ehto1 && forwardCheck.ehto2) {
        // EHTO 3: Tarkista ettei synny uutta konfliktia
        const newFinish = B.finished_time + deficit;
        const nextOtherTask = findNextTaskByOtherBatch(allPairs, B.batch_id, newFinish);
        
        if (!nextOtherTask) {
            forwardCheck.ehto3 = true;
            forwardCheck.ehto3_details = 'Ei seuraavaa muun erän tehtävää';
        } else {
            const gap = nextOtherTask.start_time - newFinish;
            forwardCheck.ehto3 = gap >= travelTime;
            forwardCheck.ehto3_details = `Gap=${gap.toFixed(1)}s vs travel=${travelTime.toFixed(1)}s → ${forwardCheck.ehto3 ? 'OK' : 'TÖRMÄYS'}`;
        }
        
        if (forwardCheck.ehto3) {
            return {
                type: 'LOCAL_FORWARD',
                target: B,
                targetBatch: B.batch_id,
                targetStage: B.stage,
                deficit,
                check: forwardCheck
            };
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // VAIHTOEHTO 2: LOCAL_BACKWARD - Aikaista A:ta (prevTask)
    // ═══════════════════════════════════════════════════════════════════════════
    const backwardCheck = {
        ehto1: A.flex_down >= deficit,
        ehto2: A_nextFlex && A_nextFlex.flex_up >= deficit,
        ehto3: false,
        ehto3_details: null
    };
    
    if (backwardCheck.ehto1 && backwardCheck.ehto2) {
        // EHTO 3: Tarkista ettei synny uutta konfliktia
        const newStart = A.start_time - deficit;
        const prevOtherTask = findPrevTaskByOtherBatch(allPairs, A.batch_id, newStart);
        
        if (!prevOtherTask) {
            backwardCheck.ehto3 = true;
            backwardCheck.ehto3_details = 'Ei edellistä muun erän tehtävää';
        } else {
            const gap = newStart - prevOtherTask.finished_time;
            backwardCheck.ehto3 = gap >= travelTime;
            backwardCheck.ehto3_details = `Gap=${gap.toFixed(1)}s vs travel=${travelTime.toFixed(1)}s → ${backwardCheck.ehto3 ? 'OK' : 'TÖRMÄYS'}`;
        }
        
        if (backwardCheck.ehto3) {
            return {
                type: 'LOCAL_BACKWARD',
                target: A,
                targetBatch: A.batch_id,
                targetStage: A.stage,
                deficit,
                check: backwardCheck
            };
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // VAIHTOEHTO 3: LOCAL_COMBINED - Sekä A:n aikaistus että B:n viivästys
    // ═══════════════════════════════════════════════════════════════════════════
    const A_local = (A.flex_down > 0 && A_nextFlex && A_nextFlex.flex_up >= A.flex_down) ? A.flex_down : 0;
    const B_local = (B.flex_up > 0 && B_nextFlex && B_nextFlex.flex_down >= B.flex_up) ? B.flex_up : 0;
    
    if (A_local + B_local >= deficit) {
        let useA = Math.min(A_local, deficit);
        let useB = Math.min(B_local, deficit - useA);
        
        // EHTO 3 molemmille (yksinkertaistettu tarkistus)
        let A_ok = true, B_ok = true;
        
        if (useA > 0) {
            const newStart = A.start_time - useA;
            const prevOtherTask = findPrevTaskByOtherBatch(allPairs, A.batch_id, newStart);
            if (prevOtherTask) {
                const gap = newStart - prevOtherTask.finished_time;
                A_ok = gap >= travelTime;
            }
        }
        
        if (useB > 0) {
            const newFinish = B.finished_time + useB;
            const nextOtherTask = findNextTaskByOtherBatch(allPairs, B.batch_id, newFinish);
            if (nextOtherTask) {
                const gap = nextOtherTask.start_time - newFinish;
                B_ok = gap >= travelTime;
            }
        }
        
        // Jos jompikumpi törmää, kokeile vain toista
        if (!A_ok && B_local >= deficit) {
            useA = 0;
            useB = deficit;
            A_ok = true;  // Ei käytetä A:ta
        } else if (!B_ok && A_local >= deficit) {
            useB = 0;
            useA = deficit;
            B_ok = true;  // Ei käytetä B:tä
        }
        
        if (A_ok && B_ok && useA + useB >= deficit) {
            return {
                type: 'LOCAL_COMBINED',
                targetA: A,
                targetB: B,
                adjustA: useA,
                adjustB: useB,
                deficit,
                A_local,
                B_local
            };
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // VAIHTOEHTO 4: CHAIN_FORWARD - Viivästä B:tä ja koko sen loppuketjua
    // Ei tarvita kompensaatiota (ehto 2), koska koko ketju siirtyy
    // ═══════════════════════════════════════════════════════════════════════════
    const chainForwardCheck = {
        ehto1: B.flex_up >= deficit,
        ehto3: false,
        ehto3_details: null
    };
    
    if (chainForwardCheck.ehto1) {
        // EHTO 3: Tarkista ettei synny uutta konfliktia
        const newFinish = B.finished_time + deficit;
        const nextOtherTask = findNextTaskByOtherBatch(allPairs, B.batch_id, newFinish);
        
        if (!nextOtherTask) {
            chainForwardCheck.ehto3 = true;
            chainForwardCheck.ehto3_details = 'Ei seuraavaa muun erän tehtävää';
        } else {
            const gap = nextOtherTask.start_time - newFinish;
            chainForwardCheck.ehto3 = gap >= travelTime;
            chainForwardCheck.ehto3_details = `Gap=${gap.toFixed(1)}s vs travel=${travelTime.toFixed(1)}s → ${chainForwardCheck.ehto3 ? 'OK' : 'TÖRMÄYS'}`;
        }
        
        if (chainForwardCheck.ehto3) {
            console.log(`[CLASSIFY] CHAIN_FORWARD: B${B.batch_id}s${B.stage} +${deficit.toFixed(1)}s (koko loppuketju)`);
            return {
                type: 'CHAIN_FORWARD',
                target: B,
                targetBatch: B.batch_id,
                targetStage: B.stage,
                deficit,
                check: chainForwardCheck
            };
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // VAIHTOEHTO 5: CHAIN_BACKWARD - Aikaista A:ta ja koko sen loppuketjua
    // Ei tarvita kompensaatiota (ehto 2), koska koko ketju siirtyy
    // ═══════════════════════════════════════════════════════════════════════════
    const chainBackwardCheck = {
        ehto1: A.flex_down >= deficit,
        ehto3: false,
        ehto3_details: null
    };
    
    if (chainBackwardCheck.ehto1) {
        // EHTO 3: Tarkista ettei synny uutta konfliktia
        const newStart = A.start_time - deficit;
        const prevOtherTask = findPrevTaskByOtherBatch(allPairs, A.batch_id, newStart);
        
        if (!prevOtherTask) {
            chainBackwardCheck.ehto3 = true;
            chainBackwardCheck.ehto3_details = 'Ei edellistä muun erän tehtävää';
        } else {
            const gap = newStart - prevOtherTask.finished_time;
            chainBackwardCheck.ehto3 = gap >= travelTime;
            chainBackwardCheck.ehto3_details = `Gap=${gap.toFixed(1)}s vs travel=${travelTime.toFixed(1)}s → ${chainBackwardCheck.ehto3 ? 'OK' : 'TÖRMÄYS'}`;
        }
        
        if (chainBackwardCheck.ehto3) {
            console.log(`[CLASSIFY] CHAIN_BACKWARD: B${A.batch_id}s${A.stage} -${deficit.toFixed(1)}s (koko loppuketju)`);
            return {
                type: 'CHAIN_BACKWARD',
                target: A,
                targetBatch: A.batch_id,
                targetStage: A.stage,
                deficit,
                check: chainBackwardCheck
            };
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // VAIHTOEHTO 6: CHAIN_COMBINED - Molemmat ketjutettuina
    // ═══════════════════════════════════════════════════════════════════════════
    const A_chain = A.flex_down;
    const B_chain = B.flex_up;
    
    if (A_chain + B_chain >= deficit) {
        let useA = Math.min(A_chain, deficit);
        let useB = deficit - useA;
        if (useB > B_chain) {
            useB = B_chain;
            useA = deficit - useB;
        }
        
        // EHTO 3 molemmille
        let A_ok = true, B_ok = true;
        
        if (useA > 0) {
            const newStart = A.start_time - useA;
            const prevOtherTask = findPrevTaskByOtherBatch(allPairs, A.batch_id, newStart);
            if (prevOtherTask) {
                const gap = newStart - prevOtherTask.finished_time;
                A_ok = gap >= travelTime;
            }
        }
        
        if (useB > 0) {
            const newFinish = B.finished_time + useB;
            const nextOtherTask = findNextTaskByOtherBatch(allPairs, B.batch_id, newFinish);
            if (nextOtherTask) {
                const gap = nextOtherTask.start_time - newFinish;
                B_ok = gap >= travelTime;
            }
        }
        
        if (A_ok && B_ok && useA + useB >= deficit) {
            console.log(`[CLASSIFY] CHAIN_COMBINED: A=-${useA.toFixed(1)}s, B=+${useB.toFixed(1)}s (ketjutettu)`);
            return {
                type: 'CHAIN_COMBINED',
                targetA: A,
                targetB: B,
                adjustA: useA,
                adjustB: useB,
                deficit,
                A_chain,
                B_chain
            };
        }
    }
    
    // Ei mikään ratkaisu toimi → UNNAMED (tuntematon/ei ratkaistavissa)
    console.log(`[CLASSIFY] UNNAMED: B${A.batch_id}s${A.stage} vs B${B.batch_id}s${B.stage} - deficit=${deficit.toFixed(1)}s, A.flex_down=${A.flex_down.toFixed(1)}s, B.flex_up=${B.flex_up.toFixed(1)}s`);
    return {
        type: 'UNNAMED',
        deficit,
        prevBatch: A.batch_id,
        prevStage: A.stage,
        nextBatch: B.batch_id,
        nextStage: B.stage,
        forwardCheck,
        backwardCheck,
        combinedCheck: { A_local, B_local, sum: A_local + B_local, needed: deficit },
        chainForwardCheck,
        chainBackwardCheck,
        chainCombinedCheck: { A_chain, B_chain, sum: A_chain + B_chain, needed: deficit }
    };
}

/**
 * EARLY-EXIT TARKISTUS: Voiko odottavan erän konfliktit YLEENSÄKÄÄN ratkaista?
 * 
 * Kutsutaan ENNEN iteraatiolooppia (6002-6008) - hylkää selvästi mahdottomat
 * tapaukset HETI ilman raskasta iteraatiota.
 * 
 * TARKISTUKSET:
 * A) Kokonaisjousto vs. kokonaisvajaus: totalDeficit > totalFlex?
 * B) Sandwich-tilanne: sama (batch, stage) tarvitsee molempia suuntia?
 * C) Odottavan erän oma sandwich: odottava erä itse puristuksissa?
 * 
 * @param {object} analysis - analyzeTaskConflicts():n tulos
 * @param {Array} batches - Eräluettelo
 * @param {number} waitingBatchId - Odottavan erän ID
 * @returns {object} { solvable: boolean, reason: string, details: object }
 */
function canPotentiallySolve(analysis, batches, waitingBatchId) {
    const conflicts = analysis?.conflicts?.filter(c => c.timing?.is_conflict) || [];
    
    // Jos ei konflikteja, voidaan edetä
    if (conflicts.length === 0) {
        return { solvable: true, reason: 'No conflicts', details: null };
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // HUOM: TARKISTUS A (totalDeficit > totalFlex) POISTETTU
    // 
    // Se on LIIAN PESSIMISTINEN ketjujoustoille:
    // - Kun ratkaisemme konfliktin ketjujoustoilla, yksi muutos voi ratkaista
    //   USEITA konflikteja samanaikaisesti
    // - Esim. B2:n koko ketjun viivästys ratkaisee KAIKKI B1 vs B2 konfliktit
    // - Sen sijaan luotamme solveConflictWithChainFlex-funktioon joka ratkaisee
    //   yhden konfliktin kerrallaan ja iteroi kunnes kaikki on ratkaistu
    // 
    // Säilytämme vain sandwich-tarkistukset (B ja C) jotka ovat aidosti mahdottomia
    // ═══════════════════════════════════════════════════════════════════════════════
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // TARKISTUKSET B JA C POISTETTU
    // 
    // Aiemmin hylättiin "sandwich"-tilanteet joissa sama stage tarvitsi sekä
    // viivästystä ETTÄ aikaistusta. MUTTA tämä oli LIIAN PESSIMISTINEN:
    //
    // Kun B2s1 viivästetään ketjujoustolla, KOKO B2:n loppuketju siirtyy.
    // Seuraavalla iteraatiolla konfliktitilanne on muuttunut:
    //   - B2s1 ei ole enää konfliktissa alkuperäisen kanssa
    //   - Uusi konflikti (jos on) analysoidaan erikseen
    //
    // Eli: annetaan solveAllConflictsWithChainFlex ratkaista iteratiivisesti!
    // Jos ratkaisu ei löydy, se palauttaa failed=true.
    // ═══════════════════════════════════════════════════════════════════════════════
    
    // Kaikki tarkistukset läpäisty - konfliktit ovat potentiaalisesti ratkaistavissa
    // Varsinainen ratkaisu tehdään solveAllConflictsWithChainFlex:ssä
    console.log(`[canPotentiallySolve] OK: ${conflicts.length} conflicts, proceed to chain-solve`);
    return { 
        solvable: true, 
        reason: 'Potentially solvable',
        details: {
            conflictCount: conflicts.length
        }
    };
}

/**
 * Luokittele kaikki konfliktit
 * @param {object} analysis - analyzeTaskConflicts():n tulos
 * @returns {object} { classifications, summary }
 */
function classifyAllConflicts(analysis) {
    if (!analysis || !analysis.conflicts) {
        return { classifications: [], summary: { local_forward: 0, local_backward: 0, local_combined: 0, unnamed: 0 } };
    }
    
    const actualConflicts = analysis.conflicts.filter(c => c.timing.is_conflict);
    const allPairs = analysis.conflicts;  // Kaikki parit (myös ei-konfliktit) ehdon 3 tarkistusta varten
    
    const classifications = [];
    const summary = { 
        local_forward: 0, 
        local_backward: 0, 
        local_combined: 0, 
        chain_forward: 0,
        chain_backward: 0,
        chain_combined: 0,
        unnamed: 0, 
        total: actualConflicts.length 
    };
    
    for (const conflict of actualConflicts) {
        const classification = classifySingleConflict(conflict, allPairs, conflict.timing.travel_time);
        classification.conflict = conflict;  // Liitä alkuperäinen konflikti mukaan
        classifications.push(classification);
        
        const A = conflict.prevTask;
        const B = conflict.nextTask;
        
        if (classification.type === 'LOCAL_FORWARD') {
            summary.local_forward++;
        }
        else if (classification.type === 'LOCAL_BACKWARD') {
            summary.local_backward++;
        }
        else if (classification.type === 'LOCAL_COMBINED') {
            summary.local_combined++;
        }
        else if (classification.type === 'CHAIN_FORWARD') {
            summary.chain_forward++;
        }
        else if (classification.type === 'CHAIN_BACKWARD') {
            summary.chain_backward++;
        }
        else if (classification.type === 'CHAIN_COMBINED') {
            summary.chain_combined++;
        }
        else {
            summary.unnamed++;
            // Lokitetaan vain UNNAMED-konfliktit
            console.log(`[UNNAMED] B${A.batch_id}s${A.stage} vs B${B.batch_id}s${B.stage}, deficit=${classification.deficit.toFixed(1)}s`);
        }
    }
    
    if (summary.total > 0) {
        const local = summary.local_forward + summary.local_backward + summary.local_combined;
        const chain = summary.chain_forward + summary.chain_backward + summary.chain_combined;
        console.log(`[CLASSIFY] ${summary.total} conflicts: LOCAL=${local} (F=${summary.local_forward}, B=${summary.local_backward}, C=${summary.local_combined}), CHAIN=${chain} (F=${summary.chain_forward}, B=${summary.chain_backward}, C=${summary.chain_combined}), UNNAMED=${summary.unnamed}`);
    }
    
    return { classifications, summary };
}

/**
 * Ratkaise LOCAL-konfliktit (FORWARD, BACKWARD, COMBINED)
 * Palauttaa listan säädöistä jotka pitää tehdä käsittelyohjelmiin
 * 
 * @param {Array} classifications - classifyAllConflicts():n tulos
 * @returns {Array} adjustments - Lista säädöistä: { batch_id, stage, delta_s, type, compensate_stage, compensate_delta_s }
 */
function resolveLocalConflicts(classifications) {
    const adjustments = [];
    
    for (const cls of classifications) {
        if (cls.operation === 'LOCAL_FORWARD') {
            // Viivästä B:tä (nextTask) ja kompensoi seuraavassa stagessa
            const B = cls.target;
            const deficit = cls.deficit;
            
            // 1. B.stage: calc_time += deficit
            adjustments.push({
                batch_id: B.batch_id,
                stage: B.stage,
                delta_s: +deficit,
                type: 'LOCAL_FORWARD',
                description: `B${B.batch_id}s${B.stage} +${deficit.toFixed(1)}s (viivästys)`
            });
            
            // 2. B.stage+1: calc_time -= deficit (kompensaatio)
            adjustments.push({
                batch_id: B.batch_id,
                stage: B.stage + 1,
                delta_s: -deficit,
                type: 'LOCAL_FORWARD_COMPENSATE',
                description: `B${B.batch_id}s${B.stage + 1} -${deficit.toFixed(1)}s (kompensaatio)`
            });
            
            console.log(`[RESOLVE] LOCAL_FORWARD: B${B.batch_id}s${B.stage} +${deficit.toFixed(1)}s, kompensaatio s${B.stage + 1} -${deficit.toFixed(1)}s`);
        }
        else if (cls.operation === 'LOCAL_BACKWARD') {
            // Aikaista A:ta (prevTask) ja kompensoi seuraavassa stagessa
            const A = cls.target;
            const deficit = cls.deficit;
            
            // 1. A.stage: calc_time -= deficit
            adjustments.push({
                batch_id: A.batch_id,
                stage: A.stage,
                delta_s: -deficit,
                type: 'LOCAL_BACKWARD',
                description: `B${A.batch_id}s${A.stage} -${deficit.toFixed(1)}s (aikaistus)`
            });
            
            // 2. A.stage+1: calc_time += deficit (kompensaatio)
            adjustments.push({
                batch_id: A.batch_id,
                stage: A.stage + 1,
                delta_s: +deficit,
                type: 'LOCAL_BACKWARD_COMPENSATE',
                description: `B${A.batch_id}s${A.stage + 1} +${deficit.toFixed(1)}s (kompensaatio)`
            });
            
            console.log(`[RESOLVE] LOCAL_BACKWARD: B${A.batch_id}s${A.stage} -${deficit.toFixed(1)}s, kompensaatio s${A.stage + 1} +${deficit.toFixed(1)}s`);
        }
        else if (cls.operation === 'LOCAL_COMBINED') {
            // Sekä A:n aikaistus että B:n viivästys
            const A = cls.targetA;
            const B = cls.targetB;
            const adjustA = cls.adjustA;
            const adjustB = cls.adjustB;
            
            if (adjustA > 0) {
                // A:n aikaistus + kompensaatio
                adjustments.push({
                    batch_id: A.batch_id,
                    stage: A.stage,
                    delta_s: -adjustA,
                    type: 'LOCAL_COMBINED_A',
                    description: `B${A.batch_id}s${A.stage} -${adjustA.toFixed(1)}s (aikaistus)`
                });
                adjustments.push({
                    batch_id: A.batch_id,
                    stage: A.stage + 1,
                    delta_s: +adjustA,
                    type: 'LOCAL_COMBINED_A_COMPENSATE',
                    description: `B${A.batch_id}s${A.stage + 1} +${adjustA.toFixed(1)}s (kompensaatio)`
                });
            }
            
            if (adjustB > 0) {
                // B:n viivästys + kompensaatio
                adjustments.push({
                    batch_id: B.batch_id,
                    stage: B.stage,
                    delta_s: +adjustB,
                    type: 'LOCAL_COMBINED_B',
                    description: `B${B.batch_id}s${B.stage} +${adjustB.toFixed(1)}s (viivästys)`
                });
                adjustments.push({
                    batch_id: B.batch_id,
                    stage: B.stage + 1,
                    delta_s: -adjustB,
                    type: 'LOCAL_COMBINED_B_COMPENSATE',
                    description: `B${B.batch_id}s${B.stage + 1} -${adjustB.toFixed(1)}s (kompensaatio)`
                });
            }
            
            console.log(`[RESOLVE] LOCAL_COMBINED: A=${adjustA.toFixed(1)}s, B=${adjustB.toFixed(1)}s`);
        }
        else if (cls.operation === 'CHAIN_FORWARD') {
            // Viivästä B:tä ja KOKO loppuketjua (ei kompensaatiota)
            const B = cls.target;
            const deficit = cls.deficit;
            
            adjustments.push({
                batch_id: B.batch_id,
                stage: B.stage,
                delta_s: +deficit,
                type: 'CHAIN_FORWARD',
                propagate: true,  // Merkki että koko ketju siirtyy
                description: `B${B.batch_id}s${B.stage}→end +${deficit.toFixed(1)}s (ketjutettu viivästys)`
            });
            
            console.log(`[RESOLVE] CHAIN_FORWARD: B${B.batch_id}s${B.stage}→end +${deficit.toFixed(1)}s`);
        }
        else if (cls.operation === 'CHAIN_BACKWARD') {
            // Aikaista A:ta ja KOKO loppuketjua (ei kompensaatiota)
            const A = cls.target;
            const deficit = cls.deficit;
            
            adjustments.push({
                batch_id: A.batch_id,
                stage: A.stage,
                delta_s: -deficit,
                type: 'CHAIN_BACKWARD',
                propagate: true,  // Merkki että koko ketju siirtyy
                description: `B${A.batch_id}s${A.stage}→end -${deficit.toFixed(1)}s (ketjutettu aikaistus)`
            });
            
            console.log(`[RESOLVE] CHAIN_BACKWARD: B${A.batch_id}s${A.stage}→end -${deficit.toFixed(1)}s`);
        }
        else if (cls.operation === 'CHAIN_COMBINED') {
            // Sekä A:n ketjutettu aikaistus että B:n ketjutettu viivästys
            const A = cls.targetA;
            const B = cls.targetB;
            const adjustA = cls.adjustA;
            const adjustB = cls.adjustB;
            
            if (adjustA > 0) {
                adjustments.push({
                    batch_id: A.batch_id,
                    stage: A.stage,
                    delta_s: -adjustA,
                    type: 'CHAIN_COMBINED_A',
                    propagate: true,
                    description: `B${A.batch_id}s${A.stage}→end -${adjustA.toFixed(1)}s (ketjutettu aikaistus)`
                });
            }
            
            if (adjustB > 0) {
                adjustments.push({
                    batch_id: B.batch_id,
                    stage: B.stage,
                    delta_s: +adjustB,
                    type: 'CHAIN_COMBINED_B',
                    propagate: true,
                    description: `B${B.batch_id}s${B.stage}→end +${adjustB.toFixed(1)}s (ketjutettu viivästys)`
                });
            }
            
            console.log(`[RESOLVE] CHAIN_COMBINED: A=-${adjustA.toFixed(1)}s, B=+${adjustB.toFixed(1)}s (ketjutettu)`);
        }
        // UNNAMED-konflikteja ei ratkaista - ne ovat aidosti tuntemattomia
    }
    
    return adjustments;
}

// ═══════════════════════════════════════════════════════════════════════════════
// DEPARTURE-ANALYYSI: KETJUJOUSTOILLA (UUSI ALGORITMI)
// 
// Tämä korvaa vanhan lähestymistavan departure-tarkastelussa (6005).
// Käyttää KOKO KETJUN joustoa (calculateChainFlex) eikä yksittäisen stagen.
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Ratkaise yksi konflikti käyttäen KETJUJOUSTOJA
 * 
 * Tämä funktio käyttää oikeaa ketjujouston laskentaa (min(stage_i.flex) kaikille i)
 * eikä yksittäisen stagen joustoa kuten vanha classifySingleConflict.
 * 
 * PRIORITEETTI:
 * 1. Aikaista A:ta (prevTask) - chain_flex_down
 * 2. Viivästä B:tä (nextTask) - chain_flex_up  
 * 3. Yhdistelmä: A:n aikaistus + B:n viivästys
 * 
 * @param {object} conflict - Konflikti (analyzeTaskConflicts:n tulosjoukosta)
 * @param {object} programsByBatchId - { batchId: program } - ohjelmat ketjujouston laskentaa varten
 * @param {Array} allPairs - Kaikki tehtäväparit (ehdon 3 tarkistukseen)
 * @param {number} travelTime - Siirtymäaika sekunteina
 * @returns {object|null} Ratkaisu tai null jos ei ratkaistavissa
 */
function solveConflictWithChainFlex(conflict, programsByBatchId, allPairs, travelTime, lockedStages = {}, delayOnly = false) {
    const deficit = conflict.timing.deficit;
    const A = conflict.prevTask;  // Aikaisempi (aikaistus auttaa)
    const B = conflict.nextTask;  // Myöhempi (viivästys auttaa)
    
    // ═══════════════════════════════════════════════════════════════════════════
    // KRIITTINEN: In-flight tehtäviä EI VOI muokata - ne ovat lukittuja
    // Jos A on in-flight, sitä ei voi aikaistaa → jousto = 0
    // Jos B on in-flight, sitä ei voi viivästää → jousto = 0
    // ═══════════════════════════════════════════════════════════════════════════
    const A_isInFlight = A.isInFlight === true;
    const B_isInFlight = B.isInFlight === true;
    
    if (A_isInFlight && B_isInFlight) {
        // Molemmat suorituksessa - mahdotonta ratkaista
        console.log(`[CHAIN-SOLVE] IMPOSSIBLE: Both tasks are in-flight (locked)`);
        return null;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // DELAY-ONLY MODE: Kun delayOnly=true, käytetään VAIN viivästystä (CHAIN_FORWARD)
    // Tämä estää oskillaation TASKS-vaiheessa
    // ═══════════════════════════════════════════════════════════════════════════
    if (delayOnly) {
        console.log(`[CHAIN-SOLVE] DELAY-ONLY MODE: B${A.batch_id}s${A.stage} vs B${B.batch_id}s${B.stage}, deficit=${deficit.toFixed(1)}s`);
    }
    
    // Hae ohjelmat
    const programA = programsByBatchId[String(A.batch_id)];
    const programB = programsByBatchId[String(B.batch_id)];
    
    // Laske KETJUJOUSTOT (koko loppuketjun min)
    // In-flight tehtävän jousto = 0 (lukittu)
    const A_chainFlexDown = A_isInFlight ? 0 : calculateChainFlex(programA, A.stage, 'down');  // A:n aikaistus
    const B_chainFlexUp = B_isInFlight ? 0 : calculateChainFlex(programB, B.stage, 'up');      // B:n viivästys
    
    const debugId = `B${A.batch_id}s${A.stage} vs B${B.batch_id}s${B.stage}`;
    console.log(`[CHAIN-SOLVE] ${debugId}: deficit=${deficit.toFixed(1)}s, A.chainFlexDown=${A_chainFlexDown.toFixed(1)}s${A_isInFlight ? ' (IN-FLIGHT)' : ''}, B.chainFlexUp=${B_chainFlexUp.toFixed(1)}s${B_isInFlight ? ' (IN-FLIGHT)' : ''}`);
    
    // ═══════════════════════════════════════════════════════════════════════════
    // OSKILLAATION ESTO: Tarkista lukitut staget
    // Jos stage on jo lukittu johonkin suuntaan, älä tee vastakkaista
    // ═══════════════════════════════════════════════════════════════════════════
    const keyA = `B${A.batch_id}s${A.stage}`;
    const keyB = `B${B.batch_id}s${B.stage}`;
    const lockA = lockedStages[keyA];
    const lockB = lockedStages[keyB];
    
    // A:n aikaistus (BACKWARD) on lukittu jos:
    // 1. Se on in-flight, TAI
    // 2. Se on aiemmin viivästetty (FORWARD), TAI
    // 3. delayOnly=true (TASKS-vaihe käyttää vain viivästystä)
    const canAdvanceA = !A_isInFlight && lockA !== 'FORWARD' && !delayOnly;
    // B:n viivästys (FORWARD) on lukittu jos:
    // 1. Se on in-flight, TAI
    // 2. Se on aiemmin aikaistettu (BACKWARD)
    const canDelayB = !B_isInFlight && lockB !== 'BACKWARD';
    
    if (lockA) console.log(`[CHAIN-SOLVE] ${keyA} locked to ${lockA}`);
    if (lockB) console.log(`[CHAIN-SOLVE] ${keyB} locked to ${lockB}`);
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PRIORITEETTI 1: Aikaista A:ta (koko loppuketju)
    // HUOM: Ohitetaan jos delayOnly=true (TASKS-vaiheessa ei aikaisteta)
    // ═══════════════════════════════════════════════════════════════════════════
    if (canAdvanceA && A_chainFlexDown >= deficit) {
        // EHTO 3: Tarkista ettei synny uutta konfliktia
        const newStart = A.start_time - deficit;
        const prevOtherTask = findPrevTaskByOtherBatch(allPairs, A.batch_id, newStart);
        
        let ok = true;
        if (prevOtherTask) {
            const gap = newStart - prevOtherTask.finished_time;
            ok = gap >= travelTime;
        }
        
        if (ok) {
            console.log(`[CHAIN-SOLVE] → CHAIN_BACKWARD: B${A.batch_id}s${A.stage}→end -${deficit.toFixed(1)}s`);
            return {
                type: 'CHAIN_BACKWARD',
                adjustments: [{
                    batch_id: A.batch_id,
                    stage: A.stage,
                    delta_s: -deficit,
                    propagate: true,
                    description: `B${A.batch_id}s${A.stage}→end -${deficit.toFixed(1)}s (ketjutettu aikaistus)`
                }]
            };
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PRIORITEETTI 2: Viivästä B:tä (koko loppuketju)
    // ═══════════════════════════════════════════════════════════════════════════
    if (canDelayB && B_chainFlexUp >= deficit) {
        // EHTO 3: Tarkista ettei synny uutta konfliktia
        const newFinish = B.finished_time + deficit;
        const nextOtherTask = findNextTaskByOtherBatch(allPairs, B.batch_id, newFinish);
        
        let ok = true;
        if (nextOtherTask) {
            const gap = nextOtherTask.start_time - newFinish;
            ok = gap >= travelTime;
        }
        
        if (ok) {
            console.log(`[CHAIN-SOLVE] → CHAIN_FORWARD: B${B.batch_id}s${B.stage}→end +${deficit.toFixed(1)}s`);
            return {
                type: 'CHAIN_FORWARD',
                adjustments: [{
                    batch_id: B.batch_id,
                    stage: B.stage,
                    delta_s: +deficit,
                    propagate: true,
                    description: `B${B.batch_id}s${B.stage}→end +${deficit.toFixed(1)}s (ketjutettu viivästys)`
                }]
            };
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PRIORITEETTI 3: Yhdistelmä (molemmat ketjutettuina)
    // Huomioi lukitukset: vain ei-lukittuja suuntia voi käyttää
    // ═══════════════════════════════════════════════════════════════════════════
    const effectiveFlexA = canAdvanceA ? A_chainFlexDown : 0;
    const effectiveFlexB = canDelayB ? B_chainFlexUp : 0;
    
    if (effectiveFlexA + effectiveFlexB >= deficit) {
        // Käytä ensin A:n jousto, loput B:stä
        let useA = Math.min(effectiveFlexA, deficit);
        let useB = deficit - useA;
        
        // Varmista ettei ylitetä B:n joustoa
        if (useB > effectiveFlexB) {
            useB = effectiveFlexB;
            useA = deficit - useB;
        }
        
        // Varmista että A:n käyttö ei ylitä
        if (useA > effectiveFlexA) {
            // Ei riitä
            console.log(`[CHAIN-SOLVE] Combined flex not enough after lock check`);
            return null;
        }
        
        // EHTO 3 molemmille
        let A_ok = true, B_ok = true;
        
        if (useA > 0) {
            const newStart = A.start_time - useA;
            const prevOtherTask = findPrevTaskByOtherBatch(allPairs, A.batch_id, newStart);
            if (prevOtherTask) {
                const gap = newStart - prevOtherTask.finished_time;
                A_ok = gap >= travelTime;
            }
        }
        
        if (useB > 0) {
            const newFinish = B.finished_time + useB;
            const nextOtherTask = findNextTaskByOtherBatch(allPairs, B.batch_id, newFinish);
            if (nextOtherTask) {
                const gap = nextOtherTask.start_time - newFinish;
                B_ok = gap >= travelTime;
            }
        }
        
        if (A_ok && B_ok) {
            console.log(`[CHAIN-SOLVE] → CHAIN_COMBINED: A=-${useA.toFixed(1)}s, B=+${useB.toFixed(1)}s`);
            const adjustments = [];
            
            if (useA > 0) {
                adjustments.push({
                    batch_id: A.batch_id,
                    stage: A.stage,
                    delta_s: -useA,
                    propagate: true,
                    description: `B${A.batch_id}s${A.stage}→end -${useA.toFixed(1)}s (ketjutettu aikaistus)`
                });
            }
            
            if (useB > 0) {
                adjustments.push({
                    batch_id: B.batch_id,
                    stage: B.stage,
                    delta_s: +useB,
                    propagate: true,
                    description: `B${B.batch_id}s${B.stage}→end +${useB.toFixed(1)}s (ketjutettu viivästys)`
                });
            }
            
            return { type: 'CHAIN_COMBINED', adjustments };
        }
    }
    
    // Ei ratkaisua löytynyt
    console.log(`[CHAIN-SOLVE] → NO SOLUTION: deficit=${deficit.toFixed(1)}s > A.flex(${A_chainFlexDown.toFixed(1)}s) + B.flex(${B_chainFlexUp.toFixed(1)}s)`);
    return null;
}

/**
/**
 * Ratkaise KAIKKI konfliktit käyttäen ketjujoustoja (departure-tarkastelu)
 * 
 * @param {object} analysis - analyzeTaskConflicts():n tulos
 * @param {object} programsByBatchId - Ohjelmat ketjujouston laskentaan
 * @param {object} lockedStages - Lukitut staget oskillaation estoon {"B1s7": "FORWARD"}
 * @param {boolean} delayOnly - Jos true, käytetään VAIN viivästystä (ei aikaistusta)
 * @returns {object} { solved: boolean, adjustments: [], unsolved: [] }
 */
function solveAllConflictsWithChainFlex(analysis, programsByBatchId, lockedStages = {}, delayOnly = false) {
    const actualConflicts = analysis?.conflicts?.filter(c => c.timing?.is_conflict) || [];
    
    if (actualConflicts.length === 0) {
        return { solved: true, adjustments: [], unsolved: [] };
    }
    
    const allPairs = analysis.conflicts;
    const allAdjustments = [];
    const unsolved = [];
    
    // Käsittele yksi konflikti kerrallaan
    // HUOM: Käsittelemme vain ENSIMMÄISEN konfliktin per kierros
    // koska ratkaisu voi muuttaa myöhempien konfliktien tilannetta
    const firstConflict = actualConflicts[0];
    const travelTime = firstConflict.timing.travel_time;
    
    const solution = solveConflictWithChainFlex(firstConflict, programsByBatchId, allPairs, travelTime, lockedStages, delayOnly);
    
    if (solution) {
        allAdjustments.push(...solution.adjustments);
        console.log(`[CHAIN-SOLVE-ALL] Solved 1/${actualConflicts.length} conflicts with ${solution.type}`);
        return { 
            solved: false,  // false = lisää konflikteja jäljellä, jatka iteraatiota
            adjustments: allAdjustments, 
            unsolved: actualConflicts.slice(1),  // Loput konfliktit
            solutionType: solution.type
        };
    } else {
        // Ensimmäistäkään konfliktia ei voitu ratkaista
        console.log(`[CHAIN-SOLVE-ALL] FAILED: Cannot solve first conflict`);
        return { 
            solved: false, 
            adjustments: [], 
            unsolved: actualConflicts,
            failed: true
        };
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// IDLE-SLOT LASKENTA JA SOVITUS (2D-NOSTIMILLE)
//
// calculateTransporterIdleSlots: Laskee nostimen vapaat aikavälit tehtävälistasta
// fitBatchToIdleSlots: Sovittaa lähtevän erän taskit idle-ikkunoihin
//
// Käytetään DEPARTURE-tilakoneessa korvaamaan iteratiivinen resolveConflict-silmukka.
// TASKS-tilakone EI käytä näitä funktioita.
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Laskee yksittäisen nostimen vapaat aikavälit (idle slots) tehtävälistasta.
 *
 * Tuloslista sisältää aikavälit joissa nostin EI suorita tehtävää.
 * Jokainen slot: { start, end, duration, prevTask, nextTask }
 *
 * @param {number} transporterId - Nostimen tunniste (1, 2, ...)
 * @param {Array} combinedTasks - Kaikki tehtävät (in-flight + linja + odottavat)
 * @param {number} currentTimeSec - Simulaatioaika (idle-slottien alaraja)
 * @param {object} [options] - { horizonSec: kuinka pitkälle tulevaisuuteen (oletus 36000 = 10h) }
 * @returns {Array} Lista idle-slot-olioita aikajärjestyksessä
 */
function calculateTransporterIdleSlots(transporterId, combinedTasks, currentTimeSec, options = {}) {
    const horizonSec = options.horizonSec || 36000;
    const endHorizon = currentTimeSec + horizonSec;

    // 1. Suodata ja järjestä tämän nostimen tehtävät aikajärjestykseen
    const tasks = combinedTasks
        .filter(t => t.transporter_id === transporterId)
        .sort((a, b) => a.task_start_time - b.task_start_time);

    const slots = [];

    if (tasks.length === 0) {
        // Nostin on täysin vapaa → yksi suuri slot
        slots.push({
            start: currentTimeSec,
            end: endHorizon,
            duration: endHorizon - currentTimeSec,
            prevTask: null,
            nextTask: null
        });
        return slots;
    }

    // 2. Slot ennen ensimmäistä tehtävää
    if (tasks[0].task_start_time > currentTimeSec) {
        slots.push({
            start: currentTimeSec,
            end: tasks[0].task_start_time,
            duration: tasks[0].task_start_time - currentTimeSec,
            prevTask: null,
            nextTask: tasks[0]
        });
    }

    // 3. Slotit tehtävien välissä
    for (let i = 0; i < tasks.length - 1; i++) {
        const gapStart = tasks[i].task_finished_time;
        const gapEnd = tasks[i + 1].task_start_time;
        if (gapEnd > gapStart) {
            slots.push({
                start: gapStart,
                end: gapEnd,
                duration: gapEnd - gapStart,
                prevTask: tasks[i],
                nextTask: tasks[i + 1]
            });
        }
    }

    // 4. Slot viimeisen tehtävän jälkeen
    const lastTask = tasks[tasks.length - 1];
    if (lastTask.task_finished_time < endHorizon) {
        slots.push({
            start: lastTask.task_finished_time,
            end: endHorizon,
            duration: endHorizon - lastTask.task_finished_time,
            prevTask: lastTask,
            nextTask: null
        });
    }

    return slots;
}

/**
 * Sovittaa lähtevän erän kuljetustehtävät nostimien idle-ikkunoihin.
 *
 * Jokaiselle erän taskille tarkistetaan:
 *   1. Minkä nostimen se käyttää (transporter_id)
 *   2. Mikä idle-slot kattaa tehtävän ajallisesti
 *   3. Onko nostin ehtinyt idle-slotin alkupäässä siirtyä
 *      edellisen tehtävänsä kohteelta tämän taskin nostoasemalle
 *   4. Onko idle-slotin loppupäässä tarpeeksi tilaa siirtyä
 *      tämän taskin kohteelta seuraavaan tehtävään nostoasemalle
 *
 * Jos taski ei mahdu mihinkään idle-slottiin, lasketaan tarvittava viivästys (DELAY)
 * jolla erän vastaava stage pitenee ja taski siirtyy sopivaan ikkunaan.
 *
 * @param {Array} batchTasks - Lähtevän erän tehtävät (createTaskListFromSchedule)
 * @param {Object} idleSlotsPerTransporter - Map: transporterId → idle-slot-lista
 * @param {Object} params - Parametrit:
 *   - stations: asema-array
 *   - transporters: nostimet
 *   - movementTimes: esilasketut siirtoajat
 *   - marginSec: turvamarginaali (oletus 5)
 *   - capFactor: cap-kerroin tulevalle stagelle (oletus 0.5)
 *   - conflictMarginSec: konfliktimarginaali (oletus 1)
 * @returns {Object} { fits: boolean, actions: [{action, batch_id, stage, amount, reason}], log: string[] }
 */
function fitBatchToIdleSlots(batchTasks, idleSlotsPerTransporter, params = {}) {
    const {
        stations = [],
        transporters = [],
        movementTimes = null,
        marginSec = 5,
        conflictMarginSec = 1,
    } = params;

    const actions = [];
    const log = [];
    let fits = true;
    
    // Kumulatiivinen siirtymä: kun stage N viivästyy, kaikki N+1, N+2... 
    // siirtyvät automaattisesti samalla määrällä (aikataulu on ketju).
    // Action tallennetaan VAIN sen stagen omana viivästyksenä (ei kumulatiivisena).
    let cumulativeShift = 0;

    // Käsittele jokainen erän taski järjestyksessä (stage 0 → N)
    for (const task of batchTasks) {
        const tId = task.transporter_id;
        if (tId === null || tId === undefined) {
            log.push(`B${task.batch_id}s${task.stage}: skip (no transporter_id)`);
            continue;
        }

        const idleSlots = idleSlotsPerTransporter[tId];
        if (!idleSlots || idleSlots.length === 0) {
            log.push(`B${task.batch_id}s${task.stage}: FAIL — T${tId} ei idle-slotteja`);
            fits = false;
            continue;
        }

        const transporter = transporters.find(t => t.id === tId);
        const liftStation = findStation(task.lift_station_id, stations);
        const sinkStation = findStation(task.sink_station_id, stations);

        // Tehtävän kesto (nosto + siirto + lasku) — task_finished_time - task_start_time
        const taskDuration = task.task_finished_time - task.task_start_time;
        
        // Huomioi kumulatiivinen siirtymä: aiempien stagejen viivästykset
        // siirtävät tämänkin taskin ajankohtaa eteenpäin
        const adjustedStartTime = task.task_start_time + cumulativeShift;

        let bestSlot = null;
        let neededDelay = Infinity;

        // Idle-slotit ovat aikajärjestyksessä → ensimmäinen sopiva on aina paras
        // (myöhemmät slotit = suurempi delay). Break heti kun löytyy.
        for (const slot of idleSlots) {
            // Slot liian aikaisin tai liian myöhään?
            if (slot.end <= adjustedStartTime - 300) continue; // Liian vanha
            // Slot liian kaukana tulevaisuudessa → lopeta haku
            if (slot.start > adjustedStartTime + 3600) break;

            // Lasketaan nostimen siirtymäaika edelliseltä tehtävältä nostoasemalle
            let travelToLift = 0;
            if (slot.prevTask) {
                const fromStation = findStation(slot.prevTask.sink_station_id, stations);
                if (fromStation && liftStation) {
                    travelToLift = getPrecomputedTravelTime(fromStation, liftStation, transporter, movementTimes);
                }
            } else if (transporter && transporter.start_station) {
                const fromStation = findStation(transporter.start_station, stations);
                if (fromStation && liftStation) {
                    travelToLift = getPrecomputedTravelTime(fromStation, liftStation, transporter, movementTimes);
                }
            }

            // Lasketaan nostimen siirtymäaika laskuasemalta seuraavaan tehtävään
            let travelFromSink = 0;
            if (slot.nextTask) {
                const toStation = findStation(slot.nextTask.lift_station_id, stations);
                if (sinkStation && toStation) {
                    travelFromSink = getPrecomputedTravelTime(sinkStation, toStation, transporter, movementTimes);
                }
            }

            // Aikaisin mahdollinen alkuhetki tässä slotissa
            const earliestStart = slot.start + travelToLift + conflictMarginSec;
            // Myöhäisin mahdollinen loppuhetki tässä slotissa
            const latestEnd = slot.nextTask
                ? slot.end - travelFromSink - conflictMarginSec
                : slot.end;

            // Mahtuuko taski ikkunaan?
            const availableWindow = latestEnd - earliestStart;
            if (availableWindow >= taskDuration) {
                const effectiveStart = Math.max(earliestStart, adjustedStartTime);

                if (effectiveStart + taskDuration <= latestEnd) {
                    neededDelay = effectiveStart - adjustedStartTime;
                    bestSlot = slot;
                    break; // Ensimmäinen sopiva = paras (aikajärjestys)
                }
            }
        }

        if (!bestSlot) {
            log.push(`B${task.batch_id}s${task.stage}: FAIL — ei sopivaa idle-slottia T${tId}:lle (duration=${taskDuration.toFixed(1)}s)`);
            fits = false;
            continue;
        }

        if (neededDelay > marginSec) {
            // Tarvitaan viivästys — TÄMÄN stagen omaa käsittelyaikaa pidennetään
            // cumulativeShift kasvaa → seuraavat staget siirtyvät automaattisesti
            cumulativeShift += neededDelay;
            log.push(`B${task.batch_id}s${task.stage}: DELAY ${neededDelay.toFixed(1)}s (slot T${tId}: ${bestSlot.start.toFixed(0)}-${bestSlot.end.toFixed(0)}, adjusted: ${adjustedStartTime.toFixed(0)}, cumShift: ${cumulativeShift.toFixed(0)}s)`);
            actions.push({
                action: 'DELAY',
                batch_id: task.batch_id,
                stage: task.stage,
                amount: neededDelay,
                reason: `idle-slot T${tId}: delay ${neededDelay.toFixed(1)}s to fit`,
                lockKey: `B${task.batch_id}s${task.stage}`,
                lockDirection: 'DELAY'
            });
        } else if (neededDelay < -marginSec) {
            // Voidaan aikaistaa — negatiivinen delay = ADVANCE
            log.push(`B${task.batch_id}s${task.stage}: ADVANCE ${(-neededDelay).toFixed(1)}s (slot T${tId}: ${bestSlot.start.toFixed(0)}-${bestSlot.end.toFixed(0)})`);
            actions.push({
                action: 'ADVANCE',
                batch_id: task.batch_id,
                stage: task.stage,
                amount: -neededDelay,
                reason: `idle-slot T${tId}: advance ${(-neededDelay).toFixed(1)}s`,
                lockKey: `B${task.batch_id}s${task.stage}`,
                lockDirection: 'ADVANCE'
            });
        } else {
            log.push(`B${task.batch_id}s${task.stage}: OK (slot T${tId}: ${bestSlot.start.toFixed(0)}-${bestSlot.end.toFixed(0)}, delta=${neededDelay.toFixed(1)}s)`);
        }
    }
    
    // Tarkista joustovarojen riittävyys: stagekohtainen delay ei saa ylittää flex_up:ia
    // Cap: 50% tulevien stagejen joustosta (TASKS:lle jää tilaa)
    //       90% jos stage 0 (erä on vielä Start-asemalla, tarkempi kontrolli)
    const CAP_FUTURE = 0.5;
    const CAP_CURRENT = 0.9;
    const cappedActions = [];
    let flexOk = true;
    
    for (const action of actions) {
        if (action.action === 'DELAY') {
            // Hae tämän stagen jousto suoraan taskeista
            const stageTask = batchTasks.find(t => t.stage === action.stage);
            if (stageTask) {
                const flex_up = Math.max(0, (stageTask.max_time_s || 0) - (stageTask.calc_time_s || 0));
                // Stage 0: erä odottaa Start-asemalla → 90% cap (kuten resolver)
                // Muut staget: tuleva stage → 50% cap
                const capFactor = (action.stage === 0) ? CAP_CURRENT : CAP_FUTURE;
                const cappedFlex = flex_up * capFactor;
                
                if (action.amount > cappedFlex + 1.0) {
                    log.push(`B${action.batch_id}s${action.stage}: FLEX OVERFLOW — need ${action.amount.toFixed(1)}s, available ${cappedFlex.toFixed(1)}s (flex_up=${flex_up.toFixed(1)}s × ${capFactor})`);
                    flexOk = false;
                } else {
                    cappedActions.push(action);
                }
            } else {
                cappedActions.push(action);
            }
        } else {
            cappedActions.push(action);
        }
    }
    
    if (!flexOk) {
        fits = false;
    }

    return { fits, actions: flexOk ? cappedActions : actions, log };
}

/**
 * Sovittaa YHDEN taskin idle-slotteihin.
 * Käytetään per-tick CHECK_ANALYZE:ssa: yksi stage per tick.
 *
 * @param {Object} task - Yksittäinen taski (batch_id, stage, transporter_id, task_start_time, task_finished_time, ...)
 * @param {Object} idleSlotsPerTransporter - Map: transporterId → idle-slot-lista
 * @param {number} cumulativeShift - Aiempien stagejen kertynyt viive (s)
 * @param {Object} params - { stations, transporters, movementTimes, marginSec, conflictMarginSec }
 * @returns {Object} { fits: boolean, delay: number, slot: object|null, log: string }
 */
function fitSingleTaskToIdleSlots(task, idleSlotsPerTransporter, cumulativeShift, params = {}) {
    const {
        stations = [],
        transporters = [],
        movementTimes = null,
        marginSec = 5,
        conflictMarginSec = 1,
    } = params;

    const tId = task.transporter_id;
    if (tId === null || tId === undefined) {
        return { fits: true, delay: 0, slot: null, log: `B${task.batch_id}s${task.stage}: skip (no transporter_id)` };
    }

    const idleSlots = idleSlotsPerTransporter[tId];
    if (!idleSlots || idleSlots.length === 0) {
        return { fits: false, delay: 0, slot: null, log: `B${task.batch_id}s${task.stage}: FAIL — T${tId} ei idle-slotteja` };
    }

    const transporter = transporters.find(t => t.id === tId);
    const liftStation = findStation(task.lift_station_id, stations);
    const sinkStation = findStation(task.sink_station_id, stations);
    const taskDuration = task.task_finished_time - task.task_start_time;
    const adjustedStartTime = task.task_start_time + cumulativeShift;

    // Ensimmäinen sopiva slot riittää (aikajärjestys)
    for (const slot of idleSlots) {
        if (slot.end <= adjustedStartTime - 300) continue;
        if (slot.start > adjustedStartTime + 3600) break;

        let travelToLift = 0;
        if (slot.prevTask) {
            const fromStation = findStation(slot.prevTask.sink_station_id, stations);
            if (fromStation && liftStation) {
                travelToLift = getPrecomputedTravelTime(fromStation, liftStation, transporter, movementTimes);
            }
        } else if (transporter && transporter.start_station) {
            const fromStation = findStation(transporter.start_station, stations);
            if (fromStation && liftStation) {
                travelToLift = getPrecomputedTravelTime(fromStation, liftStation, transporter, movementTimes);
            }
        }

        let travelFromSink = 0;
        if (slot.nextTask) {
            const toStation = findStation(slot.nextTask.lift_station_id, stations);
            if (sinkStation && toStation) {
                travelFromSink = getPrecomputedTravelTime(sinkStation, toStation, transporter, movementTimes);
            }
        }

        const earliestStart = slot.start + travelToLift + conflictMarginSec;
        const latestEnd = slot.nextTask
            ? slot.end - travelFromSink - conflictMarginSec
            : slot.end;

        const availableWindow = latestEnd - earliestStart;
        if (availableWindow >= taskDuration) {
            const effectiveStart = Math.max(earliestStart, adjustedStartTime);
            if (effectiveStart + taskDuration <= latestEnd) {
                const delay = effectiveStart - adjustedStartTime;

                // Flex-tarkistus inline: delay ei saa ylittää flex_up × factor
                if (delay > marginSec) {
                    const flex_up = Math.max(0, (task.max_time_s || 0) - (task.calc_time_s || 0));
                    const flexUpFactor = params.flexUpFactor ?? 0.5;
                    const cappedFlex = flex_up * flexUpFactor;
                    if (delay > cappedFlex + 1.0) {
                        return {
                            fits: false,
                            delay,
                            slot,
                            needExtra: delay - cappedFlex,
                            log: `B${task.batch_id}s${task.stage}: FLEX OVERFLOW — need ${delay.toFixed(1)}s, available ${cappedFlex.toFixed(1)}s (flex_up=${flex_up.toFixed(1)}s × ${flexUpFactor})`
                        };
                    }
                }

                const action = delay > marginSec ? 'DELAY' : (delay < -marginSec ? 'ADVANCE' : 'OK');
                const taskEndTime = effectiveStart + taskDuration;
                return {
                    fits: true,
                    delay,
                    slot,
                    effectiveStart,
                    taskEndTime,
                    log: `B${task.batch_id}s${task.stage}: ${action} ${Math.abs(delay).toFixed(1)}s (slot T${tId}: ${slot.start.toFixed(0)}-${slot.end.toFixed(0)})`
                };
            }
        }
    }

    return {
        fits: false,
        delay: 0,
        slot: null,
        log: `B${task.batch_id}s${task.stage}: FAIL — ei sopivaa idle-slottia T${tId}:lle (duration=${taskDuration.toFixed(1)}s)`
    };
}

/**
 * Varmistaa, että aiemmin sovitettu taski mahtuu edelleen idle-slotteihin.
 * Kutsutaan joka tickillä aiemmin sovitetuille stageille.
 *
 * @param {Object} task - Taski joka aiemmin sovitettiin
 * @param {Object} idleSlotsPerTransporter - Tuoreet idle-slotit
 * @param {number} fittedDelay - Aiemmin löydetty viive tälle stagelle
 * @param {number} cumulativeShift - Aiempien stagejen kertynyt viive
 * @param {Object} params - { stations, transporters, movementTimes, conflictMarginSec }
 * @returns {Object} { ok: boolean, log: string }
 */
function verifyFittedTask(task, idleSlotsPerTransporter, fittedDelay, cumulativeShift, params = {}) {
    const {
        stations = [],
        transporters = [],
        movementTimes = null,
        conflictMarginSec = 1,
    } = params;

    const tId = task.transporter_id;
    if (tId === null || tId === undefined) {
        return { ok: true, log: `B${task.batch_id}s${task.stage}: skip (no transporter_id)` };
    }

    const idleSlots = idleSlotsPerTransporter[tId];
    if (!idleSlots || idleSlots.length === 0) {
        return { ok: false, log: `B${task.batch_id}s${task.stage}: VERIFY FAIL — T${tId} ei idle-slotteja` };
    }

    const transporter = transporters.find(t => t.id === tId);
    const liftStation = findStation(task.lift_station_id, stations);
    const sinkStation = findStation(task.sink_station_id, stations);
    const taskDuration = task.task_finished_time - task.task_start_time;
    const adjustedStartTime = task.task_start_time + cumulativeShift;

    // Varmistus: taski mahtuu edelleen johonkin slottiin samalla logiikalla
    // kuin fitSingleTaskToIdleSlots. Sallitaan ajan kuluminen (currentTime kasvaa
    // tickien välissä → slotin start siirtyy).
    for (const slot of idleSlots) {
        if (slot.end <= adjustedStartTime - 300) continue;
        if (slot.start > adjustedStartTime + fittedDelay + 3600) break;

        let travelToLift = 0;
        if (slot.prevTask) {
            const fromStation = findStation(slot.prevTask.sink_station_id, stations);
            if (fromStation && liftStation) {
                travelToLift = getPrecomputedTravelTime(fromStation, liftStation, transporter, movementTimes);
            }
        }

        let travelFromSink = 0;
        if (slot.nextTask) {
            const toStation = findStation(slot.nextTask.lift_station_id, stations);
            if (sinkStation && toStation) {
                travelFromSink = getPrecomputedTravelTime(sinkStation, toStation, transporter, movementTimes);
            }
        }

        const slotEarliest = slot.start + travelToLift + conflictMarginSec;
        const slotLatest = slot.nextTask
            ? slot.end - travelFromSink - conflictMarginSec
            : slot.end;

        const availableWindow = slotLatest - slotEarliest;
        if (availableWindow >= taskDuration) {
            const effectiveStart = Math.max(slotEarliest, adjustedStartTime);
            if (effectiveStart + taskDuration <= slotLatest) {
                return { ok: true, log: `B${task.batch_id}s${task.stage}: VERIFY OK (slot T${tId}: ${slot.start.toFixed(0)}-${slot.end.toFixed(0)})` };
            }
        }
    }

    return { ok: false, log: `B${task.batch_id}s${task.stage}: VERIFY FAIL — ei enää sovi T${tId}:n idle-slotteihin (start=${effectiveStart.toFixed(0)}, dur=${taskDuration.toFixed(0)}s)` };
}


// ═══════════════════════════════════════════════════════════════════════════════
// EXPORTS
// ═══════════════════════════════════════════════════════════════════════════════

module.exports = {
    // Pääfunktiot
    calculateBatchSchedule,
    calculateTransferTime,
    calculateTransferTimeWithCrossCheck,
    createTaskListFromSchedule,
    validateAndFixTaskList,
    
    // PLC-pilkotut funktiot (vaiheet erikseen)
    swapSameStationTasks,      // PHASE 2210: Swap
    analyzeTaskConflicts,      // PHASE 2215: Analyze (v3.4 - globaali, stop at first)
    resolveConflict,           // Ratkaisee konfliktin ketjujoustoilla (dokumentti: 5.6)
    resolveFirstConflict,      // DEPRECATED: Vanha resolve (käyttää analysis.conflicts)
    resolveTaskConflicts,      // DEPRECATED: Kaikki konfliktit kerralla
    validateTaskTiming,        // (legacy, varajärjestelmä)
    
    // Konfliktiluokkien tunnistus ja ratkaisu
    canPotentiallySolve,       // EARLY-EXIT: Voiko konfliktit ratkaista?
    classifyAllConflicts,      // Tunnista LOCAL_FORWARD/BACKWARD/COMBINED/UNNAMED
    classifySingleConflict,    // Yhden konfliktin luokitus
    resolveLocalConflicts,     // Ratkaise LOCAL-konfliktit → säätölista
    
    // DEPARTURE: Ketjujoustoilla (UUSI ALGORITMI)
    calculateChainFlex,        // Laske erän ketjun jousto tietystä stagesta loppuun
    solveConflictWithChainFlex,    // Ratkaise yksi konflikti ketjujoustoilla
    solveAllConflictsWithChainFlex, // Ratkaise kaikki konfliktit ketjujoustoilla
    
    // Propagointifunktiot
    propagateEarlierToBatch,
    propagateDelayToBatch,
    
    // Apufunktiot
    calculateAxisTime,
    calculateLiftTime2D,
    calculateSinkTime2D,
    calculateHorizontalTravelTime,
    findStation,
    parseTimeToSeconds,
    formatSecondsToTime,
    canTransporterHandleTask,
    
    // IDLE-SLOT: DEPARTURE-syklin idle-slot -pohjainen sovitus (2D)
    calculateTransporterIdleSlots,
    fitBatchToIdleSlots,
    fitSingleTaskToIdleSlots,  // Per-tick: sovita yksi taski idle-slotteihin
    verifyFittedTask,          // Per-tick: varmista aiempi sovitus
    
    // Rinnakkaiset asemat (parallel stations)
    getParallelStations,
    selectBestParallelStation,
    
    // Poikittaissiirtokuljetin (cross-transporter)
    isCrossTransporterOp,
    findCrossTransporterEndStation,
    
    // Debug
    printSchedule,
    printTransferDetails,
    printTaskList,
    
    // Tietorakenteet
    schedule,
    MAX_BATCHES,
    MAX_STATIONS
};
