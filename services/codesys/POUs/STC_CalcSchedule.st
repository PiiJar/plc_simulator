(* ===========================================================================================
 *  STC_CalcSchedule — Calculate batch schedule for one unit
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Shared FC: both TSK and DEP call this with different arrays.
 *  Calculates start/finish times for each treatment stage based
 *  on elapsed time, cal_time and transfer durations.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION STC_CalcSchedule : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_unit                    : INT;
  i_trans                   : INT;
  i_time_s                  : LINT;
END_VAR

VAR_IN_OUT
  io_schedule               : ARRAY[1..10] OF UDT_JC_TskScheduleType;
  io_batch                  : ARRAY[1..10] OF UDT_BatchType;
  io_program                : ARRAY[1..10] OF UDT_TreatmentProgramType;
END_VAR

VAR_EXTERNAL CONSTANT
    MIN_StationIndex        : INT;
    MAX_StationIndex        : INT;
    MAX_Units               : INT;
    MAX_Transporters        : INT;
    NOT_PROCESSED           : INT;
    USED                    : INT;
END_VAR

VAR_EXTERNAL
  g_unit                    : ARRAY[1..MAX_Units] OF UDT_UnitType;
  g_station                 : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_station_loc             : ARRAY[1..MAX_StationIndex] OF UDT_UnitLocation;
  g_station_count           : INT;
  g_move                    : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
  g_cfg                     : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_transporter             : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
END_VAR

VAR
  stg                       : INT;
  stn_num                   : INT;
  prev_stn                  : INT;
  cur_stage                 : INT;
  location                  : INT;
  start_st                  : INT;
  entry_t                   : LINT;
  exit_t                    : LINT;
  xfer_t                    : REAL;
  calc_s                    : REAL;
  min_s                     : REAL;
  max_s                     : REAL;
  is_on_stn                 : BOOL;
  is_first                  : BOOL;
  remain_s                  : REAL;
  elapsed_s                 : REAL;
  out_count                 : INT;
  p                         : INT;
  chosen_stn                : INT;
  tmp_move                  : UDT_JC_MoveTimesType;
  cand_arr                  : ARRAY[1..5] OF INT;
  cand_cnt                  : INT;
  sched_occupied            : ARRAY[1..5] OF BOOL;
  phys_occupied             : ARRAY[1..5] OF BOOL;
  best_change_time          : LINT;
  my_entry                  : LINT;
  my_exit                   : LINT;
  ov_start                  : LINT;
  ov_end                    : LINT;
  uj                        : INT;
  sj                        : INT;
  pickup_wait               : REAL;   (* earliest pickup time for waiting batch *)
  MIN_PICKUP_WAIT           : REAL := 5.0;  (* minimum pickup wait seconds *)
END_VAR

STC_CalcSchedule := FALSE;
IF i_unit < 1 OR i_unit > MAX_Units THEN RETURN; END_IF;
IF i_trans < 1 OR i_trans > MAX_Transporters THEN RETURN; END_IF;

cur_stage := io_batch[i_unit].CurStage;
location  := g_unit[i_unit].location;
is_on_stn := location >= 100;
out_count := 0;

(* Clear old schedule *)
FOR stg := 1 TO 30 DO
  io_schedule[i_unit].Stages[stg].station := 0;
  io_schedule[i_unit].Stages[stg].ProgramStage := 0;
  io_schedule[i_unit].Stages[stg].EntryTime := 0;
  io_schedule[i_unit].Stages[stg].ExitTime := 0;
  io_schedule[i_unit].Stages[stg].MinTime := 0;
  io_schedule[i_unit].Stages[stg].CalcTime := 0;
  io_schedule[i_unit].Stages[stg].MaxTime := 0;
  io_schedule[i_unit].Stages[stg].TransferTime := 0;
END_FOR;

(* Waiting batch (state = NOT_PROCESSED): treat as stage 0 *)
IF io_batch[i_unit].State = NOT_PROCESSED THEN
  cur_stage := 0;
END_IF;

IF is_on_stn THEN
  start_st := cur_stage;
ELSE
  start_st := cur_stage + 1;
END_IF;
IF start_st < 1 THEN
  start_st := 1;
END_IF;

IF is_on_stn THEN
  prev_stn := location;
ELSIF cur_stage >= 1 AND cur_stage <= 30 THEN
  prev_stn := io_program[i_unit].Steps[cur_stage].Stations[0];
ELSE
  prev_stn := 0;
END_IF;

exit_t := i_time_s;
is_first := TRUE;

(* Prepend current location when unit needs pre-positioning *)
IF is_on_stn AND start_st >= 1 THEN
  stn_num := 0;
  FOR p := 0 TO 4 DO
    IF io_program[i_unit].Steps[start_st].Stations[p] = location THEN
      stn_num := location;
    END_IF;
  END_FOR;
  IF stn_num = 0 THEN
    out_count := out_count + 1;
    io_schedule[i_unit].Stages[out_count].station       := location;
    io_schedule[i_unit].Stages[out_count].ProgramStage := 0;
    io_schedule[i_unit].Stages[out_count].EntryTime    := exit_t;
    io_schedule[i_unit].Stages[out_count].TransferTime := 0;

    IF io_batch[i_unit].CurStage = 0 AND io_batch[i_unit].CalTime > 0 THEN
      IF io_batch[i_unit].StartTime > 0 AND io_batch[i_unit].StartTime < i_time_s THEN
        elapsed_s := LINT_TO_REAL(i_time_s - io_batch[i_unit].StartTime);
      ELSE
        elapsed_s := 0.0;
      END_IF;
      remain_s := DINT_TO_REAL(io_batch[i_unit].CalTime) - elapsed_s;
  IF remain_s < 1.0 THEN remain_s := 1.0; END_IF;
      exit_t := i_time_s + REAL_TO_LINT(remain_s);
      io_schedule[i_unit].Stages[out_count].ExitTime  := exit_t;
      io_schedule[i_unit].Stages[out_count].CalcTime  := REAL_TO_DINT(remain_s);
      io_schedule[i_unit].Stages[out_count].MinTime   := io_batch[i_unit].MinTime;
      io_schedule[i_unit].Stages[out_count].MaxTime   := io_batch[i_unit].MaxTime;
    ELSE
      (* Waiting batch (State=0, CalTime=0): calculate earliest pickup time.
         Transporter must travel to the batch location before it can pick up. *)
      IF io_batch[i_unit].State = NOT_PROCESSED THEN
        tmp_move := g_move[i_trans];
        pickup_wait := 0.0;

        IF g_transporter[i_trans].Phase >= 1 AND g_transporter[i_trans].Phase <= 4 THEN
          (* Transporter busy: finish current task + travel from sink to batch *)
          pickup_wait := DINT_TO_REAL(g_transporter[i_trans].TaskRemainingTime);
          IF g_transporter[i_trans].SinkStationTarget <> location THEN
            pickup_wait := pickup_wait + STC_CalcHorizontalTravel(
              i_from_stn := g_transporter[i_trans].SinkStationTarget,
              i_to_stn   := location,
              i_move     := tmp_move);
          END_IF;
        ELSE
          (* Transporter idle: only travel time *)
          IF g_transporter[i_trans].CurrentStation <> location THEN
            pickup_wait := STC_CalcHorizontalTravel(
              i_from_stn := g_transporter[i_trans].CurrentStation,
              i_to_stn   := location,
              i_move     := tmp_move);
          END_IF;
        END_IF;

  IF pickup_wait < MIN_PICKUP_WAIT THEN pickup_wait := MIN_PICKUP_WAIT; END_IF;

        exit_t := i_time_s + REAL_TO_LINT(pickup_wait);
        io_schedule[i_unit].Stages[out_count].ExitTime  := exit_t;
        io_schedule[i_unit].Stages[out_count].CalcTime  := REAL_TO_DINT(pickup_wait);
        io_schedule[i_unit].Stages[out_count].MinTime   := REAL_TO_DINT(pickup_wait);
        io_schedule[i_unit].Stages[out_count].MaxTime   := REAL_TO_DINT(pickup_wait * 2.0);
      ELSE
        io_schedule[i_unit].Stages[out_count].ExitTime  := exit_t;
        io_schedule[i_unit].Stages[out_count].CalcTime  := 0;
        io_schedule[i_unit].Stages[out_count].MinTime   := 0;
        io_schedule[i_unit].Stages[out_count].MaxTime   := 0;
      END_IF;
    END_IF;

    is_first := FALSE;
  END_IF;
END_IF;

(* ============================================================
   MAIN LOOP: Calculate schedule for each program stage
   ============================================================ *)
FOR stg := start_st TO io_program[i_unit].StepCount DO

  cand_cnt := 0;
  FOR p := 0 TO 4 DO
    IF io_program[i_unit].Steps[stg].Stations[p] > 0 THEN
      cand_cnt := cand_cnt + 1;
      cand_arr[cand_cnt] := io_program[i_unit].Steps[stg].Stations[p];
      sched_occupied[cand_cnt] := FALSE;
      phys_occupied[cand_cnt] := FALSE;
    END_IF;
  END_FOR;

  IF cand_cnt = 0 THEN
    EXIT;
  END_IF;

  chosen_stn := 0;
  IF is_first AND is_on_stn AND stg = cur_stage THEN
    FOR p := 1 TO cand_cnt DO
      IF cand_arr[p] = location THEN
        chosen_stn := location;
      END_IF;
    END_FOR;
  END_IF;

  IF chosen_stn = 0 THEN
    IF cand_cnt = 1 THEN
      chosen_stn := cand_arr[1];
    ELSE
      (* Estimate this batch's time window per candidate for overlap check *)
      calc_s := DINT_TO_REAL(io_program[i_unit].Steps[stg].CalTime);
      tmp_move := g_move[i_trans];

      FOR p := 1 TO cand_cnt DO
        (* Calculate entry/exit per candidate station individually *)
        xfer_t := STC_CalcTransferTime(
          i_from_stn            := prev_stn,
          i_to_stn              := cand_arr[p],
          i_move                := tmp_move,
          i_from_dropping_x10   := g_station[prev_stn].DrippingTime,
          i_to_device_delay_x10 := g_station[cand_arr[p]].DeviceDelay,
          i_drip_tray_delay_x10 := g_cfg[i_trans].DripTrayDelay
        );
        my_entry := exit_t + REAL_TO_LINT(xfer_t);
        my_exit  := my_entry + REAL_TO_LINT(calc_s);

        FOR uj := 1 TO MAX_Units DO
          IF uj <> i_unit AND io_schedule[uj].StageCount > 0 THEN
            FOR sj := 1 TO io_schedule[uj].StageCount DO
              IF io_schedule[uj].Stages[sj].station = cand_arr[p] THEN
                ov_start := my_entry;
                IF io_schedule[uj].Stages[sj].EntryTime > ov_start THEN
                  ov_start := io_schedule[uj].Stages[sj].EntryTime;
                END_IF;
                ov_end := my_exit;
                IF io_schedule[uj].Stages[sj].ExitTime < ov_end THEN
                  ov_end := io_schedule[uj].Stages[sj].ExitTime;
                END_IF;
                IF ov_end > ov_start THEN
                  sched_occupied[p] := TRUE;
                END_IF;
              END_IF;
            END_FOR;
          END_IF;
        END_FOR;

        FOR uj := 1 TO MAX_Units DO
          IF g_unit[uj].location = cand_arr[p] AND g_unit[uj].Status = USED THEN
            phys_occupied[p] := TRUE;
          END_IF;
        END_FOR;
      END_FOR;

      best_change_time := LINT#9999999999;
      FOR p := 1 TO cand_cnt DO
        IF NOT sched_occupied[p] AND NOT phys_occupied[p] THEN
          IF cand_arr[p] >= MIN_StationIndex AND cand_arr[p] <= MAX_StationIndex THEN
            IF g_station_loc[cand_arr[p]].ChangeTime < best_change_time THEN
              best_change_time := g_station_loc[cand_arr[p]].ChangeTime;
              chosen_stn := cand_arr[p];
            END_IF;
          END_IF;
        END_IF;
      END_FOR;

      (* Pass 2: prefer physically free even if sched-occupied *)
      IF chosen_stn = 0 THEN
        FOR p := 1 TO cand_cnt DO
          IF NOT phys_occupied[p] AND chosen_stn = 0 THEN
            chosen_stn := cand_arr[p];
          END_IF;
        END_FOR;
      END_IF;

      (* Pass 3: prefer sched-free even if phys-occupied *)
      IF chosen_stn = 0 THEN
        FOR p := 1 TO cand_cnt DO
          IF NOT sched_occupied[p] AND chosen_stn = 0 THEN
            chosen_stn := cand_arr[p];
          END_IF;
        END_FOR;
      END_IF;

      (* Pass 4: all occupied — pick first candidate *)
      IF chosen_stn = 0 THEN
        chosen_stn := cand_arr[1];
      END_IF;
    END_IF;
  END_IF;

  stn_num := chosen_stn;

  calc_s := DINT_TO_REAL(io_program[i_unit].Steps[stg].CalTime);
  min_s  := DINT_TO_REAL(io_program[i_unit].Steps[stg].MinTime);
  max_s  := DINT_TO_REAL(io_program[i_unit].Steps[stg].MaxTime);

  tmp_move := g_move[i_trans];
  IF prev_stn >= MIN_StationIndex AND prev_stn <= MAX_StationIndex
     AND stn_num >= MIN_StationIndex AND stn_num <= MAX_StationIndex THEN
    IF g_station[prev_stn].Crosstransport > 0
       AND g_station[prev_stn].ChangeStation > 0
       AND g_station[prev_stn].YPosition <> g_station[stn_num].YPosition THEN
      xfer_t := INT_TO_REAL(g_station[prev_stn].CrossTransportTime)
              + STC_CalcTransferTime(
                  i_from_stn            := g_station[prev_stn].ChangeStation,
                  i_to_stn              := stn_num,
                  i_move                := tmp_move,
                  i_from_dropping_x10   := g_station[g_station[prev_stn].ChangeStation].DrippingTime,
                  i_to_device_delay_x10 := g_station[stn_num].DeviceDelay,
                  i_drip_tray_delay_x10 := g_cfg[i_trans].DripTrayDelay
                );
    ELSE
      xfer_t := STC_CalcTransferTime(
        i_from_stn            := prev_stn,
        i_to_stn              := stn_num,
        i_move                := tmp_move,
        i_from_dropping_x10   := g_station[prev_stn].DrippingTime,
        i_to_device_delay_x10 := g_station[stn_num].DeviceDelay,
        i_drip_tray_delay_x10 := g_cfg[i_trans].DripTrayDelay
      );
    END_IF;
  ELSE
    xfer_t := 60.0;
  END_IF;

  IF is_first AND is_on_stn AND stg = cur_stage THEN
    entry_t := i_time_s;
    IF io_batch[i_unit].StartTime > 0 THEN
      elapsed_s := LINT_TO_REAL(i_time_s - io_batch[i_unit].StartTime);
    ELSE
      elapsed_s := 0.0;
    END_IF;
    remain_s := DINT_TO_REAL(io_batch[i_unit].CalTime) - elapsed_s;
  IF remain_s < 1.0 THEN remain_s := 1.0; END_IF;
    exit_t := i_time_s + REAL_TO_LINT(remain_s);
  ELSIF is_first AND NOT is_on_stn THEN
    IF io_batch[i_unit].StartTime > 0 AND io_batch[i_unit].CalTime > 0 THEN
      entry_t := io_batch[i_unit].StartTime + DINT_TO_LINT(io_batch[i_unit].CalTime);
    ELSE
      entry_t := i_time_s + REAL_TO_LINT(xfer_t);
    END_IF;
    exit_t  := entry_t + REAL_TO_LINT(calc_s);
  ELSE
    entry_t := exit_t + REAL_TO_LINT(xfer_t);
    exit_t  := entry_t + REAL_TO_LINT(calc_s);
  END_IF;

  out_count := out_count + 1;
  IF out_count <= 30 THEN
    io_schedule[i_unit].Stages[out_count].station       := stn_num;
    io_schedule[i_unit].Stages[out_count].ProgramStage := stg;
    io_schedule[i_unit].Stages[out_count].EntryTime    := entry_t;
    io_schedule[i_unit].Stages[out_count].ExitTime     := exit_t;
    io_schedule[i_unit].Stages[out_count].MinTime      := REAL_TO_DINT(min_s);
    io_schedule[i_unit].Stages[out_count].CalcTime     := REAL_TO_DINT(calc_s);
    io_schedule[i_unit].Stages[out_count].MaxTime      := REAL_TO_DINT(max_s);
    io_schedule[i_unit].Stages[out_count].TransferTime := REAL_TO_DINT(xfer_t);
  END_IF;

  prev_stn := stn_num;
  is_first := FALSE;

END_FOR;

io_schedule[i_unit].StageCount := out_count;
STC_CalcSchedule := TRUE;

END_FUNCTION
