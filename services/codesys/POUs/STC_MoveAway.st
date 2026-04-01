(* ===========================================================================================
 *  STC_MoveAway — Evaluate and trigger idle move-away for transporters
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen / AI-assisted
 *  Created : 01.04.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Called once per scheduler cycle (phase 2202).
 *  For each idle transporter (Phase=0, Status=3) sitting on a MoveAway station,
 *  checks if idle time exceeds the station's MoveAway threshold.
 *  If so, calculates a safe target station and initiates move-away by setting
 *  Phase:=1, Status:=3, LiftStationTarget:=dest_stn.
 *
 *  60-second rule: If the transporter's next queued task starts on the SAME station
 *  and begins within MOVE_AWAY_MIN_WAIT_S seconds, move-away is suppressed.
 *
 *  Direction fallback: If no station is found in the preferred direction, tries
 *  the opposite direction before giving up.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION STC_MoveAway : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
    i_time_s : LINT;   (* current unix time in seconds *)
END_VAR

VAR_EXTERNAL CONSTANT
    MIN_StationIndex     : INT;
    MAX_StationIndex     : INT;
    MAX_Transporters     : INT;
    MOVE_AWAY_MIN_WAIT_S : LINT;
END_VAR

VAR_EXTERNAL
    g_transporter : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
    g_station     : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
    g_cfg         : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
    g_task        : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
    g_sim_trans   : ARRAY[1..MAX_Transporters] OF UDT_JC_SimTransporterType;
END_VAR

VAR
    ti            : INT;    (* transporter index *)
    stn           : INT;    (* current station *)
    move_away_s   : INT;    (* station's move-away threshold *)
    idle_time     : LINT;   (* seconds since idle start *)
    current_x     : DINT;   (* current X position *)
    next_lift_x   : DINT;   (* next task lift station X *)
    area_center   : DINT;   (* midpoint of drive area *)
    dir           : INT;    (* +1 = right, -1 = left *)
    dest_stn      : INT;    (* target station *)
    next_stn      : INT;    (* chain-search temp *)
    next_task_stn : INT;    (* next task start station *)
    time_to_start : LINT;   (* seconds until next task *)
END_VAR


(* Implementation ---------------------------------------------------------------------------*)

STC_MoveAway := TRUE;

FOR ti := 1 TO MAX_Transporters DO

    (* Only idle transporters in auto mode *)
    IF g_transporter[ti].Phase <> 0 THEN CONTINUE; END_IF;
    IF g_transporter[ti].Status <> 3 THEN CONTINUE; END_IF;
    IF NOT g_transporter[ti].IsActive THEN CONTINUE; END_IF;

    stn := g_transporter[ti].CurrentStation;
    IF stn < MIN_StationIndex OR stn > MAX_StationIndex THEN CONTINUE; END_IF;

    move_away_s := g_station[stn].MoveAway;
    IF move_away_s = 0 THEN CONTINUE; END_IF;

    (* Calculate idle time: seconds since last task completed *)
    idle_time := i_time_s - g_sim_trans[ti].IdleStartTime;
    IF idle_time < DINT_TO_LINT(INT_TO_DINT(move_away_s)) THEN CONTINUE; END_IF;

    (* 60-second rule: don't move away if next task starts on same station soon *)
    IF g_task[ti].Count > 0 THEN
        next_task_stn := g_task[ti].Queue[1].LiftStationTarget;
        IF next_task_stn = stn THEN
            time_to_start := g_task[ti].Queue[1].StartTime - i_time_s;
            IF time_to_start >= 0 AND time_to_start < MOVE_AWAY_MIN_WAIT_S THEN
                CONTINUE;
            END_IF;
        END_IF;
    END_IF;

    (* Idle time exceeded — calculate target *)
    current_x := g_transporter[ti].XPosition;

    (* Direction: toward next task, or toward area center *)
    IF g_task[ti].Count > 0 THEN
        next_lift_x := g_station[ g_task[ti].Queue[1].LiftStationTarget ].XPosition;
        IF next_lift_x > current_x THEN
            dir := 1;
        ELSE
            dir := -1;
        END_IF;
    ELSE
        area_center := (g_cfg[ti].DrivePosMin + g_cfg[ti].DrivePosMax) / 2;
        IF area_center > current_x THEN
            dir := 1;
        ELSE
            dir := -1;
        END_IF;
    END_IF;

    (* Find station at least 2 steps away *)
    dest_stn := STC_FindStationOffset(
        i_trans     := ti,
        i_from_stn  := stn,
        i_dir       := dir,
        i_min_steps := 2
    );

    (* Direction fallback: try opposite if first attempt failed *)
    IF dest_stn = 0 THEN
        dir := -dir;
        dest_stn := STC_FindStationOffset(
            i_trans     := ti,
            i_from_stn  := stn,
            i_dir       := dir,
            i_min_steps := 2
        );
        IF dest_stn = 0 THEN CONTINUE; END_IF;
    END_IF;

    (* Chain: skip consecutive MoveAway stations *)
    WHILE (dest_stn >= MIN_StationIndex) AND (dest_stn <= MAX_StationIndex)
          AND (g_station[dest_stn].MoveAway > 0) DO
        next_stn := STC_FindStationOffset(
            i_trans     := ti,
            i_from_stn  := dest_stn,
            i_dir       := dir,
            i_min_steps := 1
        );

        IF (next_stn = 0) OR (next_stn = dest_stn) THEN
            dest_stn := 0;
            EXIT;
        END_IF;

        dest_stn := next_stn;
    END_WHILE;

    IF dest_stn = 0 THEN CONTINUE; END_IF;

    (* Initiate move-away: Phase 1 + Status 3 = idle move *)
    g_transporter[ti].Phase := 1;
    (* Status stays 3 — auto idle *)
    g_transporter[ti].LiftStationTarget := dest_stn;
    g_transporter[ti].XDriveTarget := g_station[dest_stn].XPosition;
    g_transporter[ti].XFinalTarget := g_station[dest_stn].XPosition;

END_FOR;
