(* ============================================================
   STC_CalcTransferTime — Total transfer time (FUNCTION)
   ============================================================
   Calculates total transfer time between two stations using
   precomputed move time table plus operational delays.

   Matches JS calculateTransferTime logic:
     p2 = lift_s  + fromDroppingTime + dripTrayDelay
     p3 = travel_s
     p4 = sink_s  + dripTrayDelay    + toDeviceDelay

   NOTE: Lift station device_delay is NOT added because covers
   are opened during treatment time (overlaps).

   All delay inputs are INT ×10 (tenths of second), same as
   g_station[].DrippingTime, g_station[].DeviceDelay, g_cfg[].DripTrayDelay.

   Used by: TSK_FB_CalcSchedule, TSK_FB_NoTreatment, DEP_FB_Scheduler,
            SIM_FB_RunTasks, STC_FB_DispatchTask
   ============================================================ *)

FUNCTION STC_CalcTransferTime : REAL
VAR_INPUT
  i_from_stn             : INT;     (* source station, e.g. 105 *)
  i_to_stn               : INT;     (* destination station, e.g. 112 *)
  i_move                 : UDT_JC_MoveTimesType;   (* transporter's precomputed move times *)
  i_from_dropping_x10    : INT;     (* g_station[from].DrippingTime — tenths of second *)
  i_to_device_delay_x10  : INT;     (* g_station[to].DeviceDelay   — tenths of second *)
  i_drip_tray_delay_x10  : INT;     (* g_cfg[trans].DripTrayDelay  — tenths of second *)
END_VAR
VAR
  from_idx : INT;
  to_idx   : INT;
END_VAR

STC_CalcTransferTime := 0.0;
IF i_from_stn > 0 AND i_from_stn <> i_to_stn THEN
  from_idx := i_from_stn - 100;
  to_idx   := i_to_stn - 100;
  IF from_idx >= 1 AND from_idx <= 25 AND to_idx >= 1 AND to_idx <= 25 THEN
    STC_CalcTransferTime :=
      (* Phase 2: lift + dropping + drip tray *)
      INT_TO_REAL(i_move.LiftTime[from_idx]) / 10.0
      + INT_TO_REAL(i_from_dropping_x10) / 10.0
      + INT_TO_REAL(i_drip_tray_delay_x10) / 10.0
      (* Phase 3: horizontal travel *)
      + INT_TO_REAL(i_move.Travel[from_idx].ToTime[to_idx]) / 10.0
      (* Phase 4: sink + drip tray + device delay *)
      + INT_TO_REAL(i_move.SinkTime[to_idx]) / 10.0
      + INT_TO_REAL(i_drip_tray_delay_x10) / 10.0
      + INT_TO_REAL(i_to_device_delay_x10) / 10.0;
  END_IF;
END_IF;

END_FUNCTION
