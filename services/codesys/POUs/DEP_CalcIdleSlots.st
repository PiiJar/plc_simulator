(* ===========================================================================================
 *  DEP_CalcIdleSlots — Idle slot calculation per transporter
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Reads task queue via VAR_IN_OUT (sandbox or live).
 *  Writes idle slot sets to io_idle_slot per transporter.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION DEP_CalcIdleSlots : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_trans                   : INT;
  i_time_s                  : LINT;
END_VAR

VAR_IN_OUT
  io_task                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
  io_idle_slot              : ARRAY[1..3] OF UDT_JC_DepIdleSlotSetType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_Transporters        : INT;
    MAX_Units               : INT;
    DEP_MAX_IDLE_SLOTS      : INT;
END_VAR

VAR_EXTERNAL
  g_transporter             : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
END_VAR

VAR
  qi                        : INT;
  si                        : INT;
  cnt                       : INT;
  prev_end                  : LINT;
  prev_sink                 : INT;
  gap_start                 : LINT;
  gap_end                   : LINT;
  HORIZON                   : LINT := 9999999999;
END_VAR

DEP_CalcIdleSlots := FALSE;
IF i_trans < 1 OR i_trans > MAX_Transporters THEN RETURN; END_IF;

io_idle_slot[i_trans].Count := 0;
si := 0;
cnt := io_task[i_trans].Count;

prev_end  := i_time_s;
prev_sink := g_transporter[i_trans].CurrentStation;

FOR qi := 1 TO MAX_Units DO
  IF qi > cnt THEN EXIT; END_IF;

  gap_start := prev_end;
  gap_end   := io_task[i_trans].Queue[qi].StartTime;

  IF gap_end > gap_start + LINT#1 THEN
    si := si + 1;
    IF si <= DEP_MAX_IDLE_SLOTS THEN
      io_idle_slot[i_trans].Slots[si].StartTime   := gap_start;
      io_idle_slot[i_trans].Slots[si].EndTime     := gap_end;
      io_idle_slot[i_trans].Slots[si].LiftStationTarget := prev_sink;
      io_idle_slot[i_trans].Slots[si].SinkStationTarget := io_task[i_trans].Queue[qi].LiftStationTarget;
    END_IF;
  END_IF;

  prev_end  := io_task[i_trans].Queue[qi].FinishTime;
  prev_sink := io_task[i_trans].Queue[qi].SinkStationTarget;
END_FOR;

si := si + 1;
IF si <= DEP_MAX_IDLE_SLOTS THEN
  io_idle_slot[i_trans].Slots[si].StartTime   := prev_end;
  io_idle_slot[i_trans].Slots[si].EndTime     := HORIZON;
  io_idle_slot[i_trans].Slots[si].LiftStationTarget := prev_sink;
  io_idle_slot[i_trans].Slots[si].SinkStationTarget := 0;
END_IF;

io_idle_slot[i_trans].Count := si;
DEP_CalcIdleSlots := TRUE;

END_FUNCTION
