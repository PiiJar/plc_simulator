(* ===========================================================================================
 *  FC_DEP_CalcIdleSlots — Idle slot calculation per transporter
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Reads task queue via VAR_IN_OUT (sandbox or live).
 *  Writes idle slot sets to ioIdleSlot per transporter.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_DEP_CalcIdleSlots : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iTrans                   : INT;
  iTimeS                  : LINT;
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 3=MAX_TRANSPORTERS *)
  ioTask                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
  ioIdleSlot              : ARRAY[1..3] OF UDT_JC_DepIdleSlotSetType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MAX_UNITS               : INT;
    DEP_MAX_IDLE_SLOTS      : INT;
END_VAR

VAR_EXTERNAL
  g_transporter             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
END_VAR

VAR
  qi                        : INT;
  si                        : INT;
  vCnt                       : INT;
  vPrevEnd                  : LINT;
  vPrevSink                 : INT;
  vGapStart                 : LINT;
  vGapEnd                   : LINT;
  HORIZON                   : LINT := 9999999999;
END_VAR

FC_DEP_CalcIdleSlots := FALSE;
IF iTrans < 1 OR iTrans > MAX_TRANSPORTERS THEN RETURN; END_IF;

ioIdleSlot[iTrans].Count := 0;
si := 0;
vCnt := ioTask[iTrans].Count;

vPrevEnd  := iTimeS;
vPrevSink := g_transporter[iTrans].CurrentStation;

FOR qi := 1 TO MAX_UNITS DO
  IF qi > vCnt THEN EXIT; END_IF;

  vGapStart := vPrevEnd;
  vGapEnd   := ioTask[iTrans].Queue[qi].StartTime;

  IF vGapEnd > vGapStart + LINT#1 THEN
    si := si + 1;
    IF si <= DEP_MAX_IDLE_SLOTS THEN
      ioIdleSlot[iTrans].Slots[si].StartTime   := vGapStart;
      ioIdleSlot[iTrans].Slots[si].EndTime     := vGapEnd;
      ioIdleSlot[iTrans].Slots[si].LiftStationTarget := vPrevSink;
      ioIdleSlot[iTrans].Slots[si].SinkStationTarget := ioTask[iTrans].Queue[qi].LiftStationTarget;
    END_IF;
  END_IF;

  vPrevEnd  := ioTask[iTrans].Queue[qi].FinishTime;
  vPrevSink := ioTask[iTrans].Queue[qi].SinkStationTarget;
END_FOR;

si := si + 1;
IF si <= DEP_MAX_IDLE_SLOTS THEN
  ioIdleSlot[iTrans].Slots[si].StartTime   := vPrevEnd;
  ioIdleSlot[iTrans].Slots[si].EndTime     := HORIZON;
  ioIdleSlot[iTrans].Slots[si].LiftStationTarget := vPrevSink;
  ioIdleSlot[iTrans].Slots[si].SinkStationTarget := 0;
END_IF;

ioIdleSlot[iTrans].Count := si;
FC_DEP_CalcIdleSlots := TRUE;

END_FUNCTION
