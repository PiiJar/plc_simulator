(* ============================================================
   TWA_FB_CalcLimits.st — Transporter Working Area: X-limit calculation

   Calculates x_min_limit and x_max_limit for all active transporters.
   Algorithm ported from transporterWorkingArea.js:

     Phase 1:   Station-based restrictions (g_avoid_status)
     Step 2.0:  Basic safety distance (current positions)
     Step 2.2:  Priority-based collision avoidance
       2.2.1:   Sort by x-position (selection sort)
       2.2.2:   Calculate canEvade + priority
       2.2.3:   Priority restrictions (target-based)
       2.2.4:   Bidirectional safety
       2.2.5:   Trap validation

   Only X-direction for now (y_avoid_mm reserved for future).
   ============================================================ *)

FUNCTION_BLOCK TWA_FB_CalcLimits
VAR_EXTERNAL CONSTANT
    MAX_Transporters    : INT;
    MIN_StationIndex : INT;
    MAX_StationIndex   : INT;
    AVOID_Passable          : INT;
    AVOID_Block         : INT;
    MIN_WorkingArea       : DINT;
END_VAR

VAR_EXTERNAL
  g_cfg            : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_transporter          : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
  g_station       : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_station_count  : INT;
  g_avoid_status   : ARRAY[MIN_StationIndex..MAX_StationIndex] OF INT;
END_VAR
VAR
  i            : INT;
  j            : INT;
  k            : INT;
  stn_num      : INT;
  stn_x        : DINT;
  avoid_st     : INT;
  min_x        : DINT;
  max_x        : DINT;
  current_x    : DINT;
  avoid_dist   : DINT;
  is_target    : BOOL;
  new_val      : DINT;
  left_s2_x    : DINT;
  right_s2_x   : DINT;
  has_left_s2  : BOOL;
  has_right_s2 : BOOL;
  midpoint     : DINT;

  (* Working arrays for sort + priority (max 3 transporters) *)
  n_active     : INT;
  w_idx        : ARRAY[1..MAX_Transporters] OF INT;
  w_xpos       : ARRAY[1..MAX_Transporters] OF DINT;
  w_phase      : ARRAY[1..MAX_Transporters] OF INT;
  w_target     : ARRAY[1..MAX_Transporters] OF DINT;
  w_avoid      : ARRAY[1..MAX_Transporters] OF DINT;
  w_can_evade  : ARRAY[1..MAX_Transporters] OF BOOL;
  w_priority   : ARRAY[1..MAX_Transporters] OF DINT;
  w_status     : ARRAY[1..MAX_Transporters] OF INT;
  w_ypos       : ARRAY[1..MAX_Transporters] OF DINT;

  (* Sort temp vars *)
  min_idx      : INT;
  tmp_int      : INT;
  tmp_dint     : DINT;
  tmp_bool     : BOOL;

  (* Step 2.2.3 vars *)
  a_wins       : BOOL;
  restrict_x   : DINT;
  between      : INT;
  chain_ofs    : DINT;
  cur_min      : DINT;
  cur_max      : DINT;
  adjusted     : DINT;

  (* Step 2.2.4 vars *)
  left_right   : BOOL;
  right_right  : BOOL;
  left_left    : BOOL;
  right_left   : BOOL;
  safety_val   : DINT;

  work_area    : DINT;
  other_x      : DINT;
  other_avoid  : DINT;
  current_y    : DINT;
  other_y      : DINT;
END_VAR

(* ================================================================
   PHASE 1: Station-based restrictions from g_avoid_status
   For each active transporter, search stations near current_station
   and restrict x_min/x_max based on avoid_status 1 (pass) and 2 (block).
   ================================================================ *)
FOR i := 1 TO MAX_Transporters DO
  IF NOT g_transporter[i].IsActive THEN
    CONTINUE;
  END_IF;

  min_x := g_cfg[i].DrivePosMin;
  max_x := g_cfg[i].DrivePosMax;
  current_x := g_transporter[i].XPosition;
  avoid_dist := g_cfg[i].AvoidanceWidth;

  (* If no limits configured, lock to current position *)
  IF (min_x < 1) OR (max_x < 1) THEN
    g_transporter[i].XMinDriveLimit := current_x;
    g_transporter[i].XMaxDriveLimit := current_x;
    CONTINUE;
  END_IF;

  has_left_s2 := FALSE;
  has_right_s2 := FALSE;
  left_s2_x := 0;
  right_s2_x := 0;

  (* --- Search downward (smaller station numbers) from current_station --- *)
  stn_num := g_transporter[i].CurrentStation - 1;
  WHILE stn_num >= MIN_StationIndex DO
    IF g_station[stn_num].TankId = 0 THEN
      stn_num := stn_num - 1;
      CONTINUE;
    END_IF;

    stn_x := g_station[stn_num].XPosition;
    IF stn_x < min_x THEN
      EXIT;
    END_IF;

    avoid_st := g_avoid_status[stn_num];

    (* AVOID_Passable: passable unless it is this transporter's target station *)
    IF avoid_st = AVOID_Passable THEN
      is_target := (stn_num = g_transporter[i].LiftStationTarget)
               OR  (stn_num = g_transporter[i].SinkStationTarget);
      IF is_target THEN
        IF current_x < stn_x THEN
          new_val := stn_x - avoid_dist;
          IF new_val < max_x THEN max_x := new_val; END_IF;
          right_s2_x := stn_x;
          has_right_s2 := TRUE;
        ELSE
          new_val := stn_x + avoid_dist;
          IF new_val > min_x THEN min_x := new_val; END_IF;
          left_s2_x := stn_x;
          has_left_s2 := TRUE;
        END_IF;
        EXIT;
      END_IF;
      (* else: passable, keep searching *)
    END_IF;

    (* AVOID_Block: hard block — transporter cannot cross *)
    IF avoid_st = AVOID_Block THEN
      IF current_x < stn_x THEN
        new_val := stn_x - avoid_dist;
        IF new_val < max_x THEN max_x := new_val; END_IF;
        right_s2_x := stn_x;
        has_right_s2 := TRUE;
      ELSE
        new_val := stn_x + avoid_dist;
        IF new_val > min_x THEN min_x := new_val; END_IF;
        left_s2_x := stn_x;
        has_left_s2 := TRUE;
      END_IF;
      EXIT;
    END_IF;

    stn_num := stn_num - 1;
  END_WHILE;

  (* --- Search upward (larger station numbers) from current_station --- *)
  stn_num := g_transporter[i].CurrentStation + 1;
  WHILE stn_num <= MAX_StationIndex DO
    IF g_station[stn_num].TankId = 0 THEN
      stn_num := stn_num + 1;
      CONTINUE;
    END_IF;

    stn_x := g_station[stn_num].XPosition;
    IF stn_x > max_x THEN
      EXIT;
    END_IF;

    avoid_st := g_avoid_status[stn_num];

    IF avoid_st = AVOID_Passable THEN
      is_target := (stn_num = g_transporter[i].LiftStationTarget)
               OR  (stn_num = g_transporter[i].SinkStationTarget);
      IF is_target THEN
        IF current_x < stn_x THEN
          new_val := stn_x - avoid_dist;
          IF new_val < max_x THEN max_x := new_val; END_IF;
          right_s2_x := stn_x;
          has_right_s2 := TRUE;
        ELSE
          new_val := stn_x + avoid_dist;
          IF new_val > min_x THEN min_x := new_val; END_IF;
          left_s2_x := stn_x;
          has_left_s2 := TRUE;
        END_IF;
        EXIT;
      END_IF;
    END_IF;

    IF avoid_st = AVOID_Block THEN
      IF current_x < stn_x THEN
        new_val := stn_x - avoid_dist;
        IF new_val < max_x THEN max_x := new_val; END_IF;
        right_s2_x := stn_x;
        has_right_s2 := TRUE;
      ELSE
        new_val := stn_x + avoid_dist;
        IF new_val > min_x THEN min_x := new_val; END_IF;
        left_s2_x := stn_x;
        has_left_s2 := TRUE;
      END_IF;
      EXIT;
    END_IF;

    stn_num := stn_num + 1;
  END_WHILE;

  (* Conflict resolution: trapped between two BLOCK stations *)
  IF (min_x >= max_x) AND has_left_s2 AND has_right_s2 THEN
    midpoint := (left_s2_x + right_s2_x) / 2;
    min_x := midpoint - 5;
    max_x := midpoint + 5;
  END_IF;

  g_transporter[i].XMinDriveLimit := min_x;
  g_transporter[i].XMaxDriveLimit := max_x;
END_FOR;

(* ================================================================
   STEP 2.0: Basic safety distance — current positions
   Every active transporter pushes neighbors away by x_avoid_mm.
   ================================================================ *)
FOR i := 1 TO MAX_Transporters DO
  IF NOT g_transporter[i].IsActive THEN
    CONTINUE;
  END_IF;

  current_x := g_transporter[i].XPosition;
  current_y := g_transporter[i].YPosition;
  avoid_dist := g_cfg[i].AvoidanceWidth;

  FOR j := 1 TO MAX_Transporters DO
    IF j = i THEN CONTINUE; END_IF;
    IF NOT g_transporter[j].IsActive THEN CONTINUE; END_IF;

    (* Skip transporters on different line (y-position check, matches JS Step 2.0) *)
    other_y := g_transporter[j].YPosition;
    IF ABS(other_y - current_y) >= 1 THEN CONTINUE; END_IF;

    other_x := g_transporter[j].XPosition;

    IF other_x > current_x THEN
      (* j is to the RIGHT of i — restrict j's x_min *)
      new_val := current_x + avoid_dist;
      IF new_val > g_transporter[j].XMinDriveLimit THEN
        g_transporter[j].XMinDriveLimit := new_val;
      END_IF;
    ELSIF other_x < current_x THEN
      (* j is to the LEFT of i — restrict j's x_max *)
      new_val := current_x - avoid_dist;
      IF new_val < g_transporter[j].XMaxDriveLimit THEN
        g_transporter[j].XMaxDriveLimit := new_val;
      END_IF;
    END_IF;
  END_FOR;
END_FOR;

(* ================================================================
   STEP 2.2: Priority-based collision avoidance
   ================================================================ *)

(* --- 2.2.1: Build sorted array of active transporters by x-position --- *)
n_active := 0;
FOR i := 1 TO MAX_Transporters DO
  IF g_transporter[i].IsActive THEN
    n_active := n_active + 1;
    w_idx[n_active] := i;
    w_xpos[n_active] := g_transporter[i].XPosition;
    w_phase[n_active] := g_transporter[i].Phase;
    w_status[n_active] := g_transporter[i].Status;
    w_ypos[n_active] := g_transporter[i].YPosition;
    w_target[n_active] := g_transporter[i].XFinalTarget;
    w_avoid[n_active] := g_cfg[i].AvoidanceWidth;
  END_IF;
END_FOR;

(* Selection sort by x-position (ascending) *)
FOR i := 1 TO n_active - 1 DO
  min_idx := i;
  FOR j := i + 1 TO n_active DO
    IF w_xpos[j] < w_xpos[min_idx] THEN
      min_idx := j;
    END_IF;
  END_FOR;
  IF min_idx <> i THEN
    tmp_int := w_idx[i];    w_idx[i] := w_idx[min_idx];    w_idx[min_idx] := tmp_int;
    tmp_dint := w_xpos[i];  w_xpos[i] := w_xpos[min_idx];  w_xpos[min_idx] := tmp_dint;
    tmp_int := w_phase[i];  w_phase[i] := w_phase[min_idx]; w_phase[min_idx] := tmp_int;
    tmp_int := w_status[i]; w_status[i] := w_status[min_idx]; w_status[min_idx] := tmp_int;
    tmp_dint := w_ypos[i];  w_ypos[i] := w_ypos[min_idx];  w_ypos[min_idx] := tmp_dint;
    tmp_dint := w_target[i]; w_target[i] := w_target[min_idx]; w_target[min_idx] := tmp_dint;
    tmp_dint := w_avoid[i];  w_avoid[i] := w_avoid[min_idx];  w_avoid[min_idx] := tmp_dint;
  END_IF;
END_FOR;

(* --- 2.2.2: Calculate canEvade and priority --- *)
FOR i := 1 TO n_active DO
  k := w_idx[i];

  (* canEvade rules (from JS specification):
     RULE 1: status < 3 - not in automatic mode, cannot evade
     RULE 2: status = 4 AND phase = 2 or 4 - Z-movement, cannot evade
     RULE 3: working area too small - cannot evade *)
  w_can_evade[i] := TRUE;
  IF w_status[i] < 3 THEN
    w_can_evade[i] := FALSE;
  END_IF;
  IF (w_status[i] = 4) AND ((w_phase[i] = 2) OR (w_phase[i] = 4)) THEN
    w_can_evade[i] := FALSE;
  END_IF;
  work_area := g_transporter[k].XMaxDriveLimit - g_transporter[k].XMinDriveLimit;
  IF work_area < MIN_WorkingArea THEN
    w_can_evade[i] := FALSE;
  END_IF;

  w_priority[i] := TWA_CalcPriority(
    i_phase := w_phase[i],
    i_can_evade := w_can_evade[i],
    i_x_pos := w_xpos[i],
    i_x_target := w_target[i]
  );
END_FOR;

(* Skip Steps 2.2.3-2.2.5 if fewer than 2 active transporters *)
IF n_active >= 2 THEN

  (* --- 2.2.3: Priority restrictions (higher priority → lower priority) --- *)
  FOR i := 1 TO n_active DO
    (* Skip idle transporters — they don't set priority restrictions *)
    IF w_phase[i] = 0 THEN CONTINUE; END_IF;

    FOR j := 1 TO n_active DO
      IF i = j THEN CONTINUE; END_IF;
      (* Skip transporters on different line *)
      IF ABS(w_ypos[i] - w_ypos[j]) >= 1 THEN CONTINUE; END_IF;

      (* Determine if i has higher priority than j *)
      a_wins := FALSE;
      IF w_priority[i] > w_priority[j] THEN
        a_wins := TRUE;
      ELSIF (w_priority[i] = w_priority[j]) AND (w_idx[i] < w_idx[j]) THEN
        a_wins := TRUE;
      END_IF;

      IF NOT a_wins THEN CONTINUE; END_IF;

      (* Higher priority transporter uses target for phase 1/3, else current pos *)
      IF (w_phase[i] = 1) OR (w_phase[i] = 3) THEN
        restrict_x := w_target[i];
      ELSE
        restrict_x := w_xpos[i];
      END_IF;

      k := w_idx[j];
      cur_min := g_transporter[k].XMinDriveLimit;
      cur_max := g_transporter[k].XMaxDriveLimit;

      IF w_xpos[i] < w_xpos[j] THEN
        (* i is LEFT, j is RIGHT — i sets j's x_min *)
        (* Count same-line transporters between i and j *)
        between := 0;
        FOR stn_num := i + 1 TO j - 1 DO
          IF ABS(w_ypos[stn_num] - w_ypos[i]) < 1 THEN between := between + 1; END_IF;
        END_FOR;
        chain_ofs := w_avoid[i] + INT_TO_DINT(between) * (MIN_WorkingArea + w_avoid[i]);
        new_val := restrict_x + chain_ofs;

        IF new_val > cur_min THEN
          IF new_val <= (cur_max - MIN_WorkingArea) THEN
            g_transporter[k].XMinDriveLimit := new_val;
          ELSE
            adjusted := cur_max - MIN_WorkingArea;
            IF adjusted > cur_min THEN
              g_transporter[k].XMinDriveLimit := adjusted;
            END_IF;
          END_IF;
        END_IF;

      ELSIF w_xpos[i] > w_xpos[j] THEN
        (* i is RIGHT, j is LEFT — i sets j's x_max *)
        (* Count same-line transporters between j and i *)
        between := 0;
        FOR stn_num := j + 1 TO i - 1 DO
          IF ABS(w_ypos[stn_num] - w_ypos[i]) < 1 THEN between := between + 1; END_IF;
        END_FOR;
        chain_ofs := w_avoid[i] + INT_TO_DINT(between) * (MIN_WorkingArea + w_avoid[i]);
        new_val := restrict_x - chain_ofs;

        IF new_val < cur_max THEN
          IF new_val >= (cur_min + MIN_WorkingArea) THEN
            g_transporter[k].XMaxDriveLimit := new_val;
          ELSE
            adjusted := cur_min + MIN_WorkingArea;
            IF adjusted < cur_max THEN
              g_transporter[k].XMaxDriveLimit := adjusted;
            END_IF;
          END_IF;
        END_IF;
      END_IF;
    END_FOR;
  END_FOR;

  (* --- 2.2.4: Bidirectional safety (both moving same direction) --- *)
  FOR i := 1 TO n_active - 1 DO
    j := i + 1;
    (* i = left (smaller x), j = right (larger x) — sorted array *)

    (* Skip if not on same line *)
    IF ABS(w_ypos[i] - w_ypos[j]) >= 1 THEN CONTINUE; END_IF;

    left_right := ((w_phase[i] = 1) OR (w_phase[i] = 3)) AND (w_target[i] > w_xpos[i]);
    right_right := ((w_phase[j] = 1) OR (w_phase[j] = 3)) AND (w_target[j] > w_xpos[j]);
    left_left := ((w_phase[i] = 1) OR (w_phase[i] = 3)) AND (w_target[i] < w_xpos[i]);
    right_left := ((w_phase[j] = 1) OR (w_phase[j] = 3)) AND (w_target[j] < w_xpos[j]);

    IF left_right AND right_right THEN
      (* Both moving right — left chasing right *)
      safety_val := w_xpos[i] + w_avoid[i];
      k := w_idx[j];
      IF safety_val > g_transporter[k].XMinDriveLimit THEN
        g_transporter[k].XMinDriveLimit := safety_val;
      END_IF;
    END_IF;

    IF left_left AND right_left THEN
      (* Both moving left — right chasing left *)
      safety_val := w_xpos[j] - w_avoid[j];
      k := w_idx[i];
      IF safety_val < g_transporter[k].XMaxDriveLimit THEN
        g_transporter[k].XMaxDriveLimit := safety_val;
      END_IF;
    END_IF;
  END_FOR;

  (* --- 2.2.5: Validate limits (trap detection) --- *)
  FOR i := 1 TO n_active DO
    k := w_idx[i];
    IF g_transporter[k].XMinDriveLimit > g_transporter[k].XMaxDriveLimit THEN
      (* Trapped — lock in place *)
      g_transporter[k].XMinDriveLimit := g_transporter[k].XPosition;
      g_transporter[k].XMaxDriveLimit := g_transporter[k].XPosition;
    END_IF;
  END_FOR;

END_IF;  (* n_active >= 2 *)

END_FUNCTION_BLOCK
