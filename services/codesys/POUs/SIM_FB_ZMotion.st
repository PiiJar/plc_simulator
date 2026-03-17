(* ============================================================
   SIM_FB_ZMotion.st — Vertical (Z) motion simulation
   
   Simulates 2D transporter lift/sink with realistic physics:
   - Slow start / fast middle / slow end speed profiles
   - Different slow zones for wet vs dry stations
   - Device delays and drip delays
   
   Coordinate convention: z=0 is bottom (sunk), z=z_total is top (lifted)
   
   LIFT sequence (z_stage 2-5, 9):
     2: Slow lift    0 → ZPosSlowUp/ZPosSlowDown
     3: Fast lift    → (z_total - ZPosSlowEnd)
     4: Slow end     → z_total
     5: Dropping     at top, dripping time (blue bar in UI)
     9: Drip close   drip tray close delay at top
   
   Note: Device delay + treatment overlap is handled by the caller
   (SIM_FB_RunTasks) in Phase 1 via can_lift check. Stage 1 is
   no longer used for lift — caller sets z_stage := 2 directly.
   
   SINK sequence (z_stage 6-8):
     6: Init delay  (device_delay + drip_delay)
     7: Fast sink    z_total → slow_zone
     8: Slow sink    → 0 mm
   
   Caller sets z_stage and z_timer_s before first call.
   Output 'done' pulses TRUE when sequence completes.
   ============================================================ *)

FUNCTION_BLOCK SIM_FB_ZMotion
VAR_INPUT
  delta_t         : REAL;    (* Cycle time in seconds — simulation internal *)
  station_kind    : INT;     (* KIND_DRY=0, KIND_WET=1 *)
  ZPosUp          : DINT;    (* Z position at full up mm *)
  ZPosDown        : DINT;    (* Z position at full down mm *)
  ZPosSlowUp      : DINT;    (* Slow zone when going up (dry) mm *)
  ZPosSlowDown    : DINT;    (* Slow zone when going down (wet) mm *)
  ZPosSlowEnd     : DINT;    (* Slow zone at end of travel mm *)
  SpeedLiftSlow_Z : DINT;    (* Slow speed mm/s *)
  SpeedLiftFast_Z : DINT;    (* Fast speed mm/s *)
  DripTrayDelay   : INT;     (* Drip tray open/close delay ×10 = tenths of second *)
  DroppingTime    : INT;     (* Dropping/dripping time ×10 = tenths of second *)
END_VAR
VAR_IN_OUT
  z_mm      : DINT;        (* Current Z position mm *)
  z_stage   : INT;         (* Current motion stage *)
  z_timer_s : REAL;        (* Delay timer — simulation internal *)
END_VAR
VAR_OUTPUT
  done : BOOL;             (* TRUE when sequence complete *)
END_VAR
VAR_EXTERNAL CONSTANT
  KIND_WET : INT;
END_VAR
VAR
  (* Internal REAL copies for physics integration *)
  r_z          : REAL;
  r_total      : REAL;
  r_slow_zone  : REAL;
  r_slow_end   : REAL;
  r_slow_spd   : REAL;
  r_fast_spd   : REAL;
  r_drip       : REAL;
  r_drop       : REAL;     (* dropping/dripping time seconds *)
  z_total_mm   : DINT;     (* computed: ZPosDown - ZPosUp *)
END_VAR

  done := FALSE;
  z_total_mm := ZPosDown - ZPosUp;

  (* Convert DINT/INT inputs to REAL for physics *)
  r_z         := DINT_TO_REAL(z_mm);
  r_total     := DINT_TO_REAL(z_total_mm);
  r_slow_end  := DINT_TO_REAL(ZPosSlowEnd);
  r_slow_spd  := DINT_TO_REAL(SpeedLiftSlow_Z);
  r_fast_spd  := DINT_TO_REAL(SpeedLiftFast_Z);
  r_drip      := INT_TO_REAL(DripTrayDelay) / 10.0;
  r_drop      := INT_TO_REAL(DroppingTime) / 10.0;

  (* Select slow zone based on station kind *)
  IF station_kind = KIND_WET THEN
    r_slow_zone := DINT_TO_REAL(ZPosSlowDown);
  ELSE
    r_slow_zone := DINT_TO_REAL(ZPosSlowUp);
  END_IF;

  CASE z_stage OF

    (* === LIFT: stages 2-5,9 — nosto altaasta ylös (z kasvaa: 0 → z_total) === *)
    (* Stage 1 no longer used for lift — device_delay overlaps with treatment wait *)

    2: (* Slow lift start — hidas nosto nesteestä *)
      r_z := r_z + r_slow_spd * delta_t;
      z_mm := REAL_TO_DINT(r_z);
      IF r_z >= r_slow_zone THEN
        z_stage := 3;
      END_IF;

    3: (* Fast lift — nopea nosto *)
      r_z := r_z + r_fast_spd * delta_t;
      z_mm := REAL_TO_DINT(r_z);
      IF r_z >= (r_total - r_slow_end) THEN
        z_stage := 4;
      END_IF;

    4: (* Slow lift end — hidas loppunosto *)
      r_z := r_z + r_slow_spd * delta_t;
      IF r_z >= r_total THEN
        z_mm := z_total_mm;
        z_timer_s := r_drop;
        z_stage := 5;
      ELSE
        z_mm := REAL_TO_DINT(r_z);
      END_IF;

    5: (* Dropping / dripping — valutusaika yläasemassa *)
      z_timer_s := z_timer_s - delta_t;
      IF z_timer_s <= 0.0 THEN
        z_timer_s := r_drip;
        z_stage := 9;
      END_IF;

    9: (* Drip tray close — tippakouru sulkeutuu *)
      z_timer_s := z_timer_s - delta_t;
      IF z_timer_s <= 0.0 THEN
        z_stage := 0;
        done := TRUE;
      END_IF;

    (* === SINK: stages 6-8 — lasku altaaseen (z pienenee: z_total → 0) === *)

    6: (* Init delay: device_delay + drip_delay *)
      z_timer_s := z_timer_s - delta_t;
      IF z_timer_s <= 0.0 THEN
        z_stage := 7;
      END_IF;

    7: (* Fast sink — nopea lasku *)
      r_z := r_z - r_fast_spd * delta_t;
      z_mm := REAL_TO_DINT(r_z);
      IF r_z <= r_slow_zone THEN
        z_stage := 8;
      END_IF;

    8: (* Slow sink — hidas lasku nesteeseen *)
      r_z := r_z - r_slow_spd * delta_t;
      IF r_z <= 0.0 THEN
        z_mm := 0;
        z_stage := 0;
        done := TRUE;
      ELSE
        z_mm := REAL_TO_DINT(r_z);
      END_IF;

  END_CASE;

END_FUNCTION_BLOCK
