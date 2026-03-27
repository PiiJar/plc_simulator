/********************************************************************************************************
 * TRANSPORTER WORKING AREA CALCULATION
 * 
 * This module calculates drive limits for all transporters in the factory.
 * 
 * The function processes all transporters in one pass, applying:
 * 1. Initial limits from transporter configuration (parameters)
 * 2. Station-based restrictions (avoid_status 1 and 2)
 * 3. Conflict resolution (when trapped between two status 2 stations)
 * 4. Transporter-to-transporter avoidance (mutual restrictions)
 * 
 * This algorithm is designed to be directly translatable to PLC ST (Structured Text).
 * Uses only basic operations: loops, MIN/MAX, IF/ELSE.
 * 
 * This module is self-contained and can be ported to PLC environment as a single unit.
 ********************************************************************************************************/

/**
 * Calculate drive limits for ALL transporters in the factory.
 * 
 * @param {array} allTransporters - Array of all transporter configs
 * @param {array} allTransporterStates - Array of all transporter states (will be modified in-place)
 * @param {array} stations - Array of all stations
 * @param {object} avoidStatuses - Station avoid status object {station_number: {avoid_status: N}}
 */
function calculateWorkingAreas(allTransporters, allTransporterStates, stations, avoidStatuses) {
  
  // Create station lookup by number for fast access
  // PLC ST: ARRAY[1..MAX_STATIONS] OF Station
  const stationByNum = {};
  let maxStationNum = 0;
  for (const station of stations) {
    const num = station.number || 0;
    stationByNum[num] = station;
    if (num > maxStationNum) {
      maxStationNum = num;
    }
  }
  
  //=====================================================================================================
  // PHASE 1: Initialize limits from configuration parameters and apply station-based restrictions
  //=====================================================================================================
  // PLC ST: FOR i := 0 TO num_transporters-1 DO
  
  for (let i = 0; i < allTransporterStates.length; i++) {
    const tState = allTransporterStates[i];
    const transporter = allTransporters.find((c) => c.id === tState.id);
    if (!transporter) continue;
    
    // Initialize with configured drive limits from transporters.json
    let minX = transporter.x_min_drive_limit || 0;
    let maxX = transporter.x_max_drive_limit || 0;
    
    const currentX = tState.state.x_position || 0;
    
    // If no limits configured (either is zero), set to current position (safe fallback)
    if (minX === 0 || maxX === 0) {
      tState.state.x_min_drive_limit = currentX;
      tState.state.x_max_drive_limit = currentX;
      continue;
    }
    
    const avoidDistance = (transporter.physics_2D && transporter.physics_2D.avoid_distance_mm) || 0;
    const currentStation = tState.state.current_station || 0;
    
    // Track status 2 stations found for conflict resolution
    let leftStatus2Station = null;   // Station to the left (smaller x)
    let rightStatus2Station = null;  // Station to the right (larger x)
    
    // Search downward (smaller station numbers) from current station
    // PLC ST: stationNum := currentStation - 1
    let stationNum = currentStation - 1;
    while (stationNum >= 1) {
      if (!stationByNum[stationNum]) {
        stationNum--;
        continue;
      }
      
      const station = stationByNum[stationNum];
      const stationX = station.x_position || 0;
      
      if (stationX < minX) break;
      
      const avoidStatusObj = avoidStatuses[String(stationNum)] || {};
      const avoidStatus = avoidStatusObj.avoid_status || 0;
      
      // Status 1: Passable, but blocks if it's a target station (lift or sink)
      if (avoidStatus === 1) {
        const isTargetStation = (stationNum === tState.state.lift_station_target) || 
                                (stationNum === tState.state.sink_station_target);
        if (isTargetStation) {
          // Treat like status 2 when this is the destination
          if (currentX < stationX) {
            const newMax = stationX - avoidDistance;
            if (newMax < maxX) maxX = newMax;
            rightStatus2Station = stationX;
          } else {
            const newMin = stationX + avoidDistance;
            if (newMin > minX) minX = newMin;
            leftStatus2Station = stationX;
          }
          break;
        }
        // else: passable, continue searching
      }
      
      // Status 2: Station to avoid - transporter cannot cross this station
      if (avoidStatus === 2) {
        if (currentX < stationX) {
          // Transporter left of station - prevent moving right past it
          const newMax = stationX - avoidDistance;
          if (newMax < maxX) maxX = newMax;
          rightStatus2Station = stationX;
        } else {
          // Transporter right of station - prevent moving left past it
          const newMin = stationX + avoidDistance;
          if (newMin > minX) minX = newMin;
          leftStatus2Station = stationX;
        }
        break;
      }
      
      stationNum--;
    }
    
    // Search upward (larger station numbers) from current station
    // PLC ST: stationNum := currentStation + 1
    stationNum = currentStation + 1;
    while (stationNum <= maxStationNum) {
      if (!stationByNum[stationNum]) {
        stationNum++;
        continue;
      }
      
      const station = stationByNum[stationNum];
      const stationX = station.x_position || 0;
      
      if (stationX > maxX) break;
      
      const avoidStatusObj = avoidStatuses[String(stationNum)] || {};
      const avoidStatus = avoidStatusObj.avoid_status || 0;
      
      // Status 1: Passable, but blocks if it's a target station (lift or sink)
      if (avoidStatus === 1) {
        const isTargetStation = (stationNum === tState.state.lift_station_target) || 
                                (stationNum === tState.state.sink_station_target);
        if (isTargetStation) {
          // Treat like status 2 when this is the destination
          if (currentX < stationX) {
            const newMax = stationX - avoidDistance;
            if (newMax < maxX) maxX = newMax;
            rightStatus2Station = stationX;
          } else {
            const newMin = stationX + avoidDistance;
            if (newMin > minX) minX = newMin;
            leftStatus2Station = stationX;
          }
          break;
        }
        // else: passable, continue searching
      }
      
      // Status 2: Station to avoid - transporter cannot cross this station
      if (avoidStatus === 2) {
        if (currentX < stationX) {
          // Transporter left of station - prevent moving right past it
          const newMax = stationX - avoidDistance;
          if (newMax < maxX) maxX = newMax;
          rightStatus2Station = stationX;
        } else {
          // Transporter right of station - prevent moving left past it
          const newMin = stationX + avoidDistance;
          if (newMin > minX) minX = newMin;
          leftStatus2Station = stationX;
        }
        break;
      }
      
      stationNum++;
    }
    
    // Handle conflict: min >= max (transporter trapped between two status 2 stations)
    // PLC ST: IF minX >= maxX THEN
    if (minX >= maxX && leftStatus2Station !== null && rightStatus2Station !== null) {
      // Calculate midpoint between the two status 2 stations
      // PLC ST: midpoint := (leftStation + rightStation) / 2
      const midpoint = (leftStatus2Station + rightStatus2Station) / 2;
      
      // Set limits around midpoint: min = midpoint - 5, max = midpoint + 5
      // PLC ST: minX := midpoint - 5; maxX := midpoint + 5;
      minX = midpoint - 5;
      maxX = midpoint + 5;
    }
    
    // Store calculated limits back to state
    tState.state.x_min_drive_limit = minX;
    tState.state.x_max_drive_limit = maxX;
  }
  
  //=====================================================================================================
  // STEP 2.0: Basic safety distance - every transporter sets limits around its CURRENT position
  //=====================================================================================================
  // This is the fundamental rule: "I am here NOW, stay away from me by avoid_distance"
  // ALL transporters set this - it prevents overlap at current positions.
  // This uses CURRENT position, not target.
  //
  console.log('[STEP 2.0] Basic safety distance calculation (current positions)');
  for (let i = 0; i < allTransporterStates.length; i++) {
    const tState = allTransporterStates[i];
    const transporter = allTransporters.find((c) => c.id === tState.id);
    if (!transporter || transporter.model !== '2D') continue;
    
    const myX = Math.round(tState.state.x_position || 0);
    const myY = Math.round(tState.state.y_position || 0);
    const myAvoidDistance = Math.round((transporter.physics_2D && transporter.physics_2D.avoid_distance_mm) || 0);
    const myPhase = tState.state.phase || 0;
    
    console.log(`  Transporter ${tState.id}: x=${myX}, phase=${myPhase}, avoidDist=${myAvoidDistance}`);
    
    // Compare with other 2D transporters on the same line
    for (let j = 0; j < allTransporterStates.length; j++) {
      if (i === j) continue; // Skip self
      
      const otherState = allTransporterStates[j];
      const otherCfg = allTransporters.find((c) => c.id === otherState.id);
      if (!otherCfg || otherCfg.model !== '2D') continue;
      
      const otherX = Math.round(otherState.state.x_position || 0);
      const otherY = Math.round(otherState.state.y_position || 0);
      
      // Check if on same line (same y-position)
      if (Math.abs(myY - otherY) < 1.0) {
        // Other transporter is on the RIGHT (larger x) - I restrict its min_x
        if (otherX > myX) {
          const newMin = myX + myAvoidDistance;
          const currentMin = otherState.state.x_min_drive_limit || -Infinity;
          console.log(`    ${tState.id} restricts ${otherState.id}.x_min: ${currentMin} -> ${newMin}`);
          if (newMin > currentMin) {
            otherState.state.x_min_drive_limit = newMin;
          }
        }
        // Other transporter is on the LEFT (smaller x) - I restrict its max_x
        else if (otherX < myX) {
          const newMax = myX - myAvoidDistance;
          const currentMax = otherState.state.x_max_drive_limit || Infinity;
          console.log(`    ${tState.id} restricts ${otherState.id}.x_max: ${currentMax} -> ${newMax}`);
          if (newMax < currentMax) {
            otherState.state.x_max_drive_limit = newMax;
          }
        }
      }
    }
  }
  
  //=====================================================================================================
  // STEP 2: Priority-based collision avoidance (v2 specification)
  //=====================================================================================================
  //
  // Implementation based on 2D_Transporter_Collision_Avoidance_Design_v2.md
  //
  // Priority rules (in order of importance):
  // 1. canEvade = FALSE → priority = 100000 (cannot move, others must avoid)
  // 2. phase 3 (to_sink): 200000 + (99999 - distance_to_target)
  // 3. phase 1 (to_source): 100000 + (99999 - distance_to_target)
  // 4. phase 0 (idle): priority = 1
  // 5. Equal priority: lower transporter ID wins
  //
  // MIN_WORKING_AREA: Minimum space needed to perform evasion (20mm)
  //
  const MIN_WORKING_AREA = 20;
  
  //---------------------------------------------------------------------------------------------
  // STEP 2.1: Group transporters by line (based on start_station DIV 100)
  //---------------------------------------------------------------------------------------------
  // Build line groups: { lineIndex: [array of transporter indices] }
  const lineGroups = {};
  
  for (let i = 0; i < allTransporterStates.length; i++) {
    const tState = allTransporterStates[i];
    const transporter = allTransporters.find((c) => c.id === tState.id);
    if (!transporter || transporter.model !== '2D') continue;
    
    // Determine line from start_station (DIV 100)
    const startStation = tState.state.start_station || tState.state.current_station || 0;
    const lineIndex = Math.floor(startStation / 100);
    
    if (!lineGroups[lineIndex]) {
      lineGroups[lineIndex] = [];
    }
    lineGroups[lineIndex].push(i);
  }
  
  //---------------------------------------------------------------------------------------------
  // STEP 2.2: Process each line independently
  //---------------------------------------------------------------------------------------------
  for (const lineIndex of Object.keys(lineGroups)) {
    const lineTransporterIndices = lineGroups[lineIndex];
    const lineCount = lineTransporterIndices.length;
    
    if (lineCount < 2) continue; // No collision possible with single transporter
    
    //-------------------------------------------------------------------------------------------
    // STEP 2.2.1: Build sorted array by x-position (Selection Sort for PLC compatibility)
    //-------------------------------------------------------------------------------------------
    // Create working array with transporter data
    const lineData = [];
    for (let k = 0; k < lineCount; k++) {
      const idx = lineTransporterIndices[k];
      const tState = allTransporterStates[idx];
      const transporter = allTransporters.find((c) => c.id === tState.id);
      const xPos = Math.round(tState.state.x_position || 0);
      const phase = tState.state.phase || 0;
      const status = tState.state.status || 0;
      const finalTarget = Math.round(
        (tState.state.x_final_target !== undefined && tState.state.x_final_target !== null)
          ? tState.state.x_final_target
          : xPos
      );
      const avoidDist = Math.round((transporter.physics_2D && transporter.physics_2D.avoid_distance_mm) || 0);
      const configMinX = transporter.x_min_drive_limit || 0;
      const configMaxX = transporter.x_max_drive_limit || 0;
      
      lineData.push({
        stateIndex: idx,
        tState: tState,
        transporter: transporter,
        id: parseInt(tState.id) || 0,
        xPos: xPos,
        phase: phase,
        status: status,
        finalTarget: finalTarget,
        avoidDist: avoidDist,
        configMinX: configMinX,
        configMaxX: configMaxX
      });
    }
    
    // Selection sort by x-position (PLC-compatible, no WHILE)
    for (let i = 0; i < lineCount - 1; i++) {
      let minIdx = i;
      for (let j = i + 1; j < lineCount; j++) {
        if (lineData[j].xPos < lineData[minIdx].xPos) {
          minIdx = j;
        }
      }
      if (minIdx !== i) {
        const temp = lineData[i];
        lineData[i] = lineData[minIdx];
        lineData[minIdx] = temp;
      }
    }
    
    //-------------------------------------------------------------------------------------------
    // STEP 2.2.2: Calculate canEvade and priority for each transporter
    //-------------------------------------------------------------------------------------------
    // CanEvade rules (from specification):
    // RULE 1: status < 3 → CANNOT evade (not in automatic mode)
    // RULE 2: status = 4 AND phase ∈ {2, 4} → CANNOT evade (Z-movement)
    // RULE 3: x_max - x_min < MIN_WORKING_AREA → CANNOT evade (area too small)
    //
    for (let i = 0; i < lineCount; i++) {
      const t = lineData[i];
      
      // RULE 1: status < 3 → CANNOT evade
      const notAutomatic = (t.status < 3);
      
      // RULE 2: status = 4 AND phase ∈ {2, 4} → CANNOT evade (Z-movement)
      const zMovement = (t.status === 4 && (t.phase === 2 || t.phase === 4));
      
      // RULE 3: Working area too small
      const currentMinX = t.tState.state.x_min_drive_limit || t.configMinX;
      const currentMaxX = t.tState.state.x_max_drive_limit || t.configMaxX;
      const workingArea = currentMaxX - currentMinX;
      const areaTooSmall = workingArea < MIN_WORKING_AREA;
      
      t.canEvade = !(notAutomatic || zMovement || areaTooSmall);
      
      // Calculate priority
      // canEvade = FALSE → priority = 100000
      // phase 3 → 200000 + (99999 - distance)
      // phase 1 → 100000 + (99999 - distance)
      // phase 0 (idle) → priority = 1
      if (!t.canEvade) {
        t.priority = 100000; // Cannot evade - fixed priority
      } else if (t.phase === 3) {
        const dist = Math.abs(t.xPos - t.finalTarget);
        t.priority = 200000 + (99999 - Math.min(dist, 99999));
      } else if (t.phase === 1) {
        const dist = Math.abs(t.xPos - t.finalTarget);
        t.priority = 100000 + (99999 - Math.min(dist, 99999));
      } else {
        t.priority = 1; // Idle
      }
    }
    
    //-------------------------------------------------------------------------------------------
    // STEP 2.2.3: Apply restrictions (higher priority sets limits for lower priority)
    //-------------------------------------------------------------------------------------------
    // SIMPLE RULE: Higher priority transporter calculates limit based on its target.
    // The limit is applied ONLY IF it narrows the current limit.
    // This automatically handles "is transporter in the way" - if not, limit won't narrow.
    //
    // - A on LEFT, B on RIGHT: A sets B's x_min = A.target + chainOffset
    // - A on RIGHT, B on LEFT: A sets B's x_max = A.target - chainOffset
    //
    // Only apply if it NARROWS (newMin > currentMin OR newMax < currentMax)
    //
    console.log('[STEP 2.2.3] Priority-based restrictions:');
    for (let i = 0; i < lineCount; i++) {
      const tA = lineData[i];
      
      // Skip if A is idle (phase 0) - idle transporters don't set priority restrictions
      // (they still set basic safety in STEP 2.0)
      if (tA.phase === 0) continue;
      
      console.log(`  Active T${tA.id}: x=${tA.xPos}, target=${tA.finalTarget}, phase=${tA.phase}, priority=${tA.priority}`);
      
      for (let j = 0; j < lineCount; j++) {
        if (i === j) continue;
        
        const tB = lineData[j];
        
        console.log(`    Comparing with T${tB.id}: x=${tB.xPos}, priority=${tB.priority}`);
        
        // Determine if A has higher priority than B
        let aWins = false;
        if (tA.priority > tB.priority) {
          aWins = true;
        } else if (tA.priority === tB.priority && tA.id < tB.id) {
          aWins = true;
        }
        
        console.log(`    aWins=${aWins}, tA.xPos(${tA.xPos}) vs tB.xPos(${tB.xPos})`);
        
        if (!aWins) continue;
        
        // A has higher priority - calculate what A needs
        // Use target position ONLY for phase 1 or 3 (X-movement)
        // For other phases (0, 2, 4), use current position
        let restrictionX;
        if (tA.phase === 1 || tA.phase === 3) {
          restrictionX = tA.finalTarget;
        } else {
          restrictionX = tA.xPos;
        }
        
        if (tA.xPos < tB.xPos) {
          // A is on LEFT, B is on RIGHT
          // A sets B's x_min
          
          const transportersBetween = j - i - 1;
          const chainOffset = tA.avoidDist + transportersBetween * (MIN_WORKING_AREA + tA.avoidDist);
          
          const newMin = Math.round(restrictionX + chainOffset);
          const currentMin = tB.tState.state.x_min_drive_limit || 0;
          const currentMax = tB.tState.state.x_max_drive_limit || 99999999;
          
          console.log(`  T${tA.id}(target=${tA.finalTarget}) -> T${tB.id}: x_min? ${newMin} vs current min=${currentMin}, max=${currentMax}`);
          
          // Apply if it NARROWS (newMin > currentMin)
          if (newMin > currentMin) {
            if (newMin <= currentMax - MIN_WORKING_AREA) {
              // Normal case: newMin fits within current range
              tB.tState.state.x_min_drive_limit = newMin;
              console.log(`    -> SET x_min = ${newMin}`);
            } else {
              // newMin would exceed max: set min = max - tolerance (push to right edge)
              const adjustedMin = currentMax - MIN_WORKING_AREA;
              if (adjustedMin > currentMin) {
                tB.tState.state.x_min_drive_limit = adjustedMin;
                console.log(`    -> SET x_min = ${adjustedMin} (adjusted, max=${currentMax})`);
              }
            }
          }
          
        } else if (tA.xPos > tB.xPos) {
          // A is on RIGHT, B is on LEFT
          // A sets B's x_max
          
          const transportersBetween = i - j - 1;
          const chainOffset = tA.avoidDist + transportersBetween * (MIN_WORKING_AREA + tA.avoidDist);
          
          const newMax = Math.round(restrictionX - chainOffset);
          const currentMin = tB.tState.state.x_min_drive_limit || 0;
          const currentMax = tB.tState.state.x_max_drive_limit || 99999999;
          
          console.log(`  T${tA.id}(target=${tA.finalTarget}) -> T${tB.id}: x_max? ${newMax} vs current min=${currentMin}, max=${currentMax}`);
          
          // Apply if it NARROWS (newMax < currentMax)
          if (newMax < currentMax) {
            if (newMax >= currentMin + MIN_WORKING_AREA) {
              // Normal case: newMax fits within current range
              tB.tState.state.x_max_drive_limit = newMax;
              console.log(`    -> SET x_max = ${newMax}`);
            } else {
              // newMax would go below min: set max = min + tolerance (push to left edge)
              const adjustedMax = currentMin + MIN_WORKING_AREA;
              if (adjustedMax < currentMax) {
                tB.tState.state.x_max_drive_limit = adjustedMax;
                console.log(`    -> SET x_max = ${adjustedMax} (adjusted, min=${currentMin})`);
              }
            }
          }
        }
      }
    }
    
    //-------------------------------------------------------------------------------------------
    // STEP 2.2.4: Bidirectional safety distance (Rule 7)
    // Fast transporter chasing slow one - both need safety distance
    //-------------------------------------------------------------------------------------------
    for (let i = 0; i < lineCount - 1; i++) {
      const tLeft = lineData[i];      // Smaller x
      const tRight = lineData[i + 1]; // Larger x
      
      // Check if both are moving in same direction
      const leftMovingRight = (tLeft.phase === 1 || tLeft.phase === 3) && tLeft.finalTarget > tLeft.xPos;
      const rightMovingRight = (tRight.phase === 1 || tRight.phase === 3) && tRight.finalTarget > tRight.xPos;
      const leftMovingLeft = (tLeft.phase === 1 || tLeft.phase === 3) && tLeft.finalTarget < tLeft.xPos;
      const rightMovingLeft = (tRight.phase === 1 || tRight.phase === 3) && tRight.finalTarget < tRight.xPos;
      
      if (leftMovingRight && rightMovingRight) {
        // Both moving right - left chasing right
        // Right needs safety: x_min >= left.x + avoidDist
        const safetyMin = Math.round(tLeft.xPos + tLeft.avoidDist);
        const currentMin = tRight.tState.state.x_min_drive_limit || -Infinity;
        if (safetyMin > currentMin) {
          tRight.tState.state.x_min_drive_limit = safetyMin;
        }
      }
      
      if (leftMovingLeft && rightMovingLeft) {
        // Both moving left - right chasing left
        // Left needs safety: x_max <= right.x - avoidDist
        const safetyMax = Math.round(tRight.xPos - tRight.avoidDist);
        const currentMax = tLeft.tState.state.x_max_drive_limit || Infinity;
        if (safetyMax < currentMax) {
          tLeft.tState.state.x_max_drive_limit = safetyMax;
        }
      }
    }
    
    //-------------------------------------------------------------------------------------------
    // STEP 2.2.5: Validate limits (trap detection)
    //-------------------------------------------------------------------------------------------
    for (let i = 0; i < lineCount; i++) {
      const t = lineData[i];
      const minLimit = t.tState.state.x_min_drive_limit || 0;
      const maxLimit = t.tState.state.x_max_drive_limit || 0;
      
      if (minLimit > maxLimit) {
        // Trapped - lock in place
        t.tState.state.x_min_drive_limit = t.xPos;
        t.tState.state.x_max_drive_limit = t.xPos;
      }
    }
  }
}

module.exports = { calculateWorkingAreas };
