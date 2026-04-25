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
  vQi                        : INT;
  vSi                        : INT;
  vCnt                       : INT;
  vPrevEnd                  : LINT;
  vPrevSink                 : INT;
  vGapStart                 : LINT;
  vGapEnd                   : LINT;
  cHorizon                   : LINT := 9999999999;
END_VAR

FC_DEP_CalcIdleSlots := FALSE;
IF iTrans < 1 OR iTrans > MAX_TRANSPORTERS THEN RETURN; END_IF;

ioIdleSlot[iTrans].Count := 0;
vSi := 0;
vCnt := ioTask[iTrans].Count;

vPrevEnd  := iTimeS;
vPrevSink := g_transporter[iTrans].CurrentStation;

FOR vQi := 1 TO MAX_UNITS DO
  IF vQi > vCnt THEN EXIT; END_IF;

  vGapStart := vPrevEnd;
  vGapEnd   := ioTask[iTrans].Queue[vQi].StartTime;

  IF vGapEnd > vGapStart + LINT#1 THEN
    vSi := vSi + 1;
    IF vSi <= DEP_MAX_IDLE_SLOTS THEN
      ioIdleSlot[iTrans].Slots[vSi].StartTime   := vGapStart;
      ioIdleSlot[iTrans].Slots[vSi].EndTime     := vGapEnd;
      ioIdleSlot[iTrans].Slots[vSi].LiftStationTarget := vPrevSink;
      ioIdleSlot[iTrans].Slots[vSi].SinkStationTarget := ioTask[iTrans].Queue[vQi].LiftStationTarget;
    END_IF;
  END_IF;

  vPrevEnd  := ioTask[iTrans].Queue[vQi].FinishTime;
  vPrevSink := ioTask[iTrans].Queue[vQi].SinkStationTarget;
END_FOR;

vSi := vSi + 1;
IF vSi <= DEP_MAX_IDLE_SLOTS THEN
  ioIdleSlot[iTrans].Slots[vSi].StartTime   := vPrevEnd;
  ioIdleSlot[iTrans].Slots[vSi].EndTime     := cHorizon;
  ioIdleSlot[iTrans].Slots[vSi].LiftStationTarget := vPrevSink;
  ioIdleSlot[iTrans].Slots[vSi].SinkStationTarget := 0;
END_IF;

ioIdleSlot[iTrans].Count := vSi;
FC_DEP_CalcIdleSlots := TRUE;

END_FUNCTION
