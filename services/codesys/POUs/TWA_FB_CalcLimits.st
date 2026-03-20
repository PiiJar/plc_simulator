(* ============================================================
   TWA_FB_CalcLimits.st — Transporter Working Area: X-limit calculation

   Calculates x_min_limit and x_max_limit for all active transporters.
   Collision avoidance layers:

     Pass 1 (per transporter):
       - Station restrictions from g_avoid_status
       - Safety distance from same-line neighbors
       - canEvade, priority, x-rank computation

     Pass 2 (pair comparisons):
       - Priority-based restrictions (higher → lower)
       - Bidirectional safety (same direction chase)

     Final: Trap validation

   Only X-direction for now (y_avoid_mm reserved for future).
   ============================================================ *)

FUNCTION_BLOCK TWA_FB_CalcLimits
VAR_EXTERNAL CONSTANT
    MAX_Transporters : INT;
    MIN_StationIndex : INT;
    MAX_StationIndex : INT;
    AVOID_Passable   : INT;
    AVOID_Block      : INT;
    MIN_WorkingArea  : DINT;
END_VAR

VAR_EXTERNAL
  g_cfg            : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_transporter    : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
  g_station        : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_station_count  : INT;
  g_avoid_status   : ARRAY[MIN_StationIndex..MAX_StationIndex] OF INT;
END_VAR
VAR
  i            : INT;
  j            : INT;
  stn_num      : INT;
  stn_x        : DINT;
  avoid_st     : INT;
  min_x        : DINT;
  max_x        : DINT;
  current_x    : DINT;
  current_y    : DINT;
  avoid_dist   : DINT;
  is_target    : BOOL;
  new_val      : DINT;

  (* Station scan: nearest restricting station per side *)
  near_left_x  : DINT;
  near_right_x : DINT;
  has_left     : BOOL;
  has_right    : BOOL;
  midpoint     : DINT;

  (* Per-transporter computed values *)
  priority     : ARRAY[1..MAX_Transporters] OF DINT;
  can_evade    : ARRAY[1..MAX_Transporters] OF BOOL;
  rank         : ARRAY[1..MAX_Transporters] OF INT;

  (* Pair comparison *)
  other_x      : DINT;
  other_y      : DINT;
  i_phase      : INT;
  j_phase      : INT;
  dist         : DINT;
  work_area    : DINT;
  a_wins       : BOOL;
  restrict_x   : DINT;
  between      : INT;
  chain_ofs    : DINT;
  adjusted     : DINT;

  (* Bidirectional *)
  i_moving_right : BOOL;
  i_moving_left  : BOOL;
  j_moving_right : BOOL;
  j_moving_left  : BOOL;
END_VAR

(* ══════════════════════════════════════════════════════════════
   PASS 1: Station restrictions + safety distance + properties
   Each transporter computes its OWN limits in one iteration.
   ══════════════════════════════════════════════════════════════ *)
FOR i := 1 TO MAX_Transporters DO
  IF NOT g_transporter[i].IsActive THEN
    priority[i] := 0;
    can_evade[i] := FALSE;
    rank[i] := 0;
    CONTINUE;
  END_IF;

  min_x := g_cfg[i].DrivePosMin;
  max_x := g_cfg[i].DrivePosMax;
  current_x := g_transporter[i].XPosition;
  current_y := g_transporter[i].YPosition;
  avoid_dist := g_cfg[i].AvoidanceWidth;

  (* Lock transporters with no drive range configured *)
  IF (min_x < 1) OR (max_x < 1) THEN
    g_transporter[i].XMinDriveLimit := current_x;
    g_transporter[i].XMaxDriveLimit := current_x;
    priority[i] := 0;
    can_evade[i] := FALSE;
    rank[i] := 0;
    CONTINUE;
  END_IF;

  (* ── Station scan: find nearest restrict LEFT and RIGHT ──────
     Single pass through all stations. Only Block and
     Passable-target stations cause restrictions. *)
  has_left := FALSE;
  has_right := FALSE;
  near_left_x := 0;
  near_right_x := 0;

  FOR stn_num := MIN_StationIndex TO MAX_StationIndex DO
    IF g_station[stn_num].TankId = 0 THEN CONTINUE; END_IF;

    avoid_st := g_avoid_status[stn_num];
    IF avoid_st = 0 THEN CONTINUE; END_IF;  (* AVOID_None *)

    (* Passable: only restricts if this transporter's target *)
    IF avoid_st = AVOID_Passable THEN
      is_target := (stn_num = g_transporter[i].LiftStationTarget)
               OR  (stn_num = g_transporter[i].SinkStationTarget);
      IF NOT is_target THEN CONTINUE; END_IF;
    END_IF;

    (* Station is Block or Passable+target → track nearest per side *)
    stn_x := g_station[stn_num].XPosition;

    IF stn_x < current_x THEN
      IF NOT has_left OR stn_x > near_left_x THEN
        near_left_x := stn_x;
        has_left := TRUE;
      END_IF;
    ELSIF stn_x > current_x THEN
      IF NOT has_right OR stn_x < near_right_x THEN
        near_right_x := stn_x;
        has_right := TRUE;
      END_IF;
    END_IF;
  END_FOR;

  (* Apply station restrictions *)
  IF has_left THEN
    new_val := near_left_x + avoid_dist;
    IF new_val > min_x THEN min_x := new_val; END_IF;
  END_IF;
  IF has_right THEN
    new_val := near_right_x - avoid_dist;
    IF new_val < max_x THEN max_x := new_val; END_IF;
  END_IF;

  (* Conflict: trapped between two restricting stations *)
  IF (min_x >= max_x) AND has_left AND has_right THEN
    midpoint := (near_left_x + near_right_x) / 2;
    min_x := midpoint - 5;
    max_x := midpoint + 5;
  END_IF;

  (* ── Safety distance: each same-line neighbor pushes i away ── *)
  FOR j := 1 TO MAX_Transporters DO
    IF j = i THEN CONTINUE; END_IF;
    IF NOT g_transporter[j].IsActive THEN CONTINUE; END_IF;

    other_y := g_transporter[j].YPosition;
    IF ABS(other_y - current_y) >= 1 THEN CONTINUE; END_IF;

    other_x := g_transporter[j].XPosition;

    IF other_x < current_x THEN
      (* j is LEFT → j's safety zone pushes i's min up *)
      new_val := other_x + g_cfg[j].AvoidanceWidth;
      IF new_val > min_x THEN min_x := new_val; END_IF;
    ELSIF other_x > current_x THEN
      (* j is RIGHT → j's safety zone pushes i's max down *)
      new_val := other_x - g_cfg[j].AvoidanceWidth;
      IF new_val < max_x THEN max_x := new_val; END_IF;
    END_IF;
  END_FOR;

  (* ── Write limits ── *)
  g_transporter[i].XMinDriveLimit := min_x;
  g_transporter[i].XMaxDriveLimit := max_x;

  (* ── canEvade (inline) ── *)
  can_evade[i] := TRUE;
  IF g_transporter[i].Status < 3 THEN
    can_evade[i] := FALSE;
  END_IF;
  IF (g_transporter[i].Status = 4)
     AND ((g_transporter[i].Phase = 2) OR (g_transporter[i].Phase = 4)) THEN
    can_evade[i] := FALSE;
  END_IF;
  work_area := max_x - min_x;
  IF work_area < MIN_WorkingArea THEN
    can_evade[i] := FALSE;
  END_IF;

  (* ── Priority (inline, replaces TWA_CalcPriority call) ── *)
  i_phase := g_transporter[i].Phase;
  IF NOT can_evade[i] THEN
    priority[i] := DINT#100000;
  ELSIF i_phase = 3 THEN
    dist := ABS(current_x - g_transporter[i].XFinalTarget);
    IF dist > 99999 THEN dist := 99999; END_IF;
    priority[i] := DINT#200000 + (DINT#99999 - dist);
  ELSIF i_phase = 1 THEN
    dist := ABS(current_x - g_transporter[i].XFinalTarget);
    IF dist > 99999 THEN dist := 99999; END_IF;
    priority[i] := DINT#100000 + (DINT#99999 - dist);
  ELSE
    priority[i] := 1;
  END_IF;

  (* ── X-rank among same-line active transporters ──
     rank = 1 + count of same-line transporters with smaller x *)
  rank[i] := 1;
  FOR j := 1 TO MAX_Transporters DO
    IF j = i THEN CONTINUE; END_IF;
    IF NOT g_transporter[j].IsActive THEN CONTINUE; END_IF;
    IF ABS(g_transporter[j].YPosition - current_y) >= 1 THEN CONTINUE; END_IF;
    IF g_transporter[j].XPosition < current_x THEN
      rank[i] := rank[i] + 1;
    END_IF;
  END_FOR;
END_FOR;

(* ══════════════════════════════════════════════════════════════
   PASS 2: Priority restrictions + bidirectional safety
   Each pair (i,j): i restricts j if i has higher priority.
   ══════════════════════════════════════════════════════════════ *)
FOR i := 1 TO MAX_Transporters DO
  IF NOT g_transporter[i].IsActive THEN CONTINUE; END_IF;
  IF priority[i] = 0 THEN CONTINUE; END_IF;

  current_x := g_transporter[i].XPosition;
  current_y := g_transporter[i].YPosition;
  i_phase := g_transporter[i].Phase;

  FOR j := 1 TO MAX_Transporters DO
    IF j = i THEN CONTINUE; END_IF;
    IF NOT g_transporter[j].IsActive THEN CONTINUE; END_IF;
    IF priority[j] = 0 THEN CONTINUE; END_IF;

    other_y := g_transporter[j].YPosition;
    IF ABS(other_y - current_y) >= 1 THEN CONTINUE; END_IF;

    other_x := g_transporter[j].XPosition;
    j_phase := g_transporter[j].Phase;

    (* ── Priority restrictions: i restricts j if i wins ── *)
    IF i_phase <> 0 THEN
      a_wins := FALSE;
      IF priority[i] > priority[j] THEN
        a_wins := TRUE;
      ELSIF (priority[i] = priority[j]) AND (i < j) THEN
        a_wins := TRUE;
      END_IF;

      IF a_wins THEN
        (* Higher priority uses target pos for phase 1/3 *)
        IF (i_phase = 1) OR (i_phase = 3) THEN
          restrict_x := g_transporter[i].XFinalTarget;
        ELSE
          restrict_x := current_x;
        END_IF;

        (* "between" from pre-computed rank *)
        between := ABS(rank[i] - rank[j]) - 1;
        IF between < 0 THEN between := 0; END_IF;

        chain_ofs := g_cfg[i].AvoidanceWidth
                   + INT_TO_DINT(between) * (MIN_WorkingArea + g_cfg[i].AvoidanceWidth);

        IF current_x < other_x THEN
          (* i LEFT, j RIGHT → restrict j's XMin *)
          new_val := restrict_x + chain_ofs;
          IF new_val > g_transporter[j].XMinDriveLimit THEN
            IF new_val <= (g_transporter[j].XMaxDriveLimit - MIN_WorkingArea) THEN
              g_transporter[j].XMinDriveLimit := new_val;
            ELSE
              adjusted := g_transporter[j].XMaxDriveLimit - MIN_WorkingArea;
              IF adjusted > g_transporter[j].XMinDriveLimit THEN
                g_transporter[j].XMinDriveLimit := adjusted;
              END_IF;
            END_IF;
          END_IF;

        ELSIF current_x > other_x THEN
          (* i RIGHT, j LEFT → restrict j's XMax *)
          new_val := restrict_x - chain_ofs;
          IF new_val < g_transporter[j].XMaxDriveLimit THEN
            IF new_val >= (g_transporter[j].XMinDriveLimit + MIN_WorkingArea) THEN
              g_transporter[j].XMaxDriveLimit := new_val;
            ELSE
              adjusted := g_transporter[j].XMinDriveLimit + MIN_WorkingArea;
              IF adjusted < g_transporter[j].XMaxDriveLimit THEN
                g_transporter[j].XMaxDriveLimit := adjusted;
              END_IF;
            END_IF;
          END_IF;
        END_IF;
      END_IF;
    END_IF;

    (* ── Bidirectional safety: only adjacent (rank diff = 1) ── *)
    IF ABS(rank[i] - rank[j]) = 1 THEN
      i_moving_right := ((i_phase = 1) OR (i_phase = 3))
                        AND (g_transporter[i].XFinalTarget > current_x);
      j_moving_right := ((j_phase = 1) OR (j_phase = 3))
                        AND (g_transporter[j].XFinalTarget > other_x);
      i_moving_left := ((i_phase = 1) OR (i_phase = 3))
                       AND (g_transporter[i].XFinalTarget < current_x);
      j_moving_left := ((j_phase = 1) OR (j_phase = 3))
                       AND (g_transporter[j].XFinalTarget < other_x);

      IF current_x < other_x AND i_moving_right AND j_moving_right THEN
        (* i LEFT chasing j RIGHT → restrict j's XMin *)
        new_val := current_x + g_cfg[i].AvoidanceWidth;
        IF new_val > g_transporter[j].XMinDriveLimit THEN
          g_transporter[j].XMinDriveLimit := new_val;
        END_IF;
      END_IF;

      IF current_x > other_x AND i_moving_left AND j_moving_left THEN
        (* i RIGHT chasing j LEFT → restrict j's XMax *)
        new_val := current_x - g_cfg[i].AvoidanceWidth;
        IF new_val < g_transporter[j].XMaxDriveLimit THEN
          g_transporter[j].XMaxDriveLimit := new_val;
        END_IF;
      END_IF;
    END_IF;
  END_FOR;
END_FOR;

(* ══════════════════════════════════════════════════════════════
   TRAP VALIDATION: if restrictions conflict, lock in place
   ══════════════════════════════════════════════════════════════ *)
FOR i := 1 TO MAX_Transporters DO
  IF NOT g_transporter[i].IsActive THEN CONTINUE; END_IF;
  IF g_transporter[i].XMinDriveLimit > g_transporter[i].XMaxDriveLimit THEN
    g_transporter[i].XMinDriveLimit := g_transporter[i].XPosition;
    g_transporter[i].XMaxDriveLimit := g_transporter[i].XPosition;
  END_IF;
END_FOR;

END_FUNCTION_BLOCK
