(* ===========================================================================================
 *  STC_FC_CalcTransferTime — Total transfer time calculation
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Calculates total transfer time between two stations using
 *  precomputed move time table plus operational delays:
 *  p2 = lift_s  + fromDroppingTime + dripTrayDelay
 *  p3 = travel_s
 *  p4 = sink_s  + dripTrayDelay    + toDeviceDelay
 *
 *  Lift station device_delay is NOT added because covers
 *  are opened during treatment time (overlaps).
 *
 *  All delay inputs are INT ×10 (tenths of second).
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION STC_FC_CalcTransferTime : REAL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iFromStn                : INT;     (* source station, e.g. 105 *)
  iToStn                  : INT;     (* destination station, e.g. 112 *)
  iMove                    : UDT_JC_MoveTimesType;   (* transporter's precomputed move times *)
  iFromDroppingX10       : INT;     (* Stations[from].DrippingTime — tenths of second *)
  iToDeviceDelayX10     : INT;     (* Stations[to].DeviceDelay   — tenths of second *)
  iDripTrayDelayX10     : INT;     (* Transporters[trans].DripTrayDelay  — tenths of second *)
END_VAR

VAR
  vFromIdx                  : INT;
  vToIdx                    : INT;
END_VAR

STC_FC_CalcTransferTime := 0.0;
IF iFromStn > 0 AND iFromStn <> iToStn THEN
  vFromIdx := iFromStn - MIN_STATION_INDEX;
  vToIdx   := iToStn - MIN_STATION_INDEX;
  IF vFromIdx >= 1 AND vFromIdx <= 25 AND vToIdx >= 1 AND vToIdx <= 25 THEN
    STC_FC_CalcTransferTime :=
      (* Phase 2: lift + dropping + drip tray *)
      INT_TO_REAL(iMove.LiftTime[vFromIdx]) / 10.0
      + INT_TO_REAL(iFromDroppingX10) / 10.0
      + INT_TO_REAL(iDripTrayDelayX10) / 10.0
      (* Phase 3: horizontal travel *)
      + INT_TO_REAL(iMove.Travel[vFromIdx].ToTime[vToIdx]) / 10.0
      (* Phase 4: sink + drip tray + device delay *)
      + INT_TO_REAL(iMove.SinkTime[vToIdx]) / 10.0
      + INT_TO_REAL(iDripTrayDelayX10) / 10.0
      + INT_TO_REAL(iToDeviceDelayX10) / 10.0;
  END_IF;
END_IF;

END_FUNCTION
