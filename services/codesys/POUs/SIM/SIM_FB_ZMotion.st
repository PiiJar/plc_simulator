(* ============================================================
   SIM_FB_ZMotion — Vertical (Z) motion simulation

   Company : Galvatek part of the John Cockerill Group
   Author  : Jarmo Piipponen
   Created : 25.03.2026
   ============================================================
   Simulates 2D transporter lift/sink with realistic physics:
   slow start / fast middle / slow end speed profiles,
   different slow zones for wet vs dry stations.

   LIFT sequence (ioZStage 2-5, 9):
     2: Slow lift    0 → iZposslowup/iZposslowdown
     3: Fast lift    → (z_total - iZposslowend)
     4: Slow end     → z_total
     5: Dropping     at top, dripping time
     9: Drip close   drip tray close delay at top

   SINK sequence (ioZStage 6-8):
     6: Init delay   (device_delay + drip_delay)
     7: Fast sink    z_total → slow_zone
     8: Slow sink    → 0 mm

   Caller sets ioZStage and ioZTimerS before first call.
   Output 'oDone' pulses TRUE when sequence completes.
   ------------------------------------------------------------
   Changes:
   ============================================================ *)

FUNCTION_BLOCK SIM_FB_ZMotion
VAR_INPUT
  iDeltaT         : REAL;    (* Cycle time in seconds — simulation internal *)
  iStationKind    : INT;     (* KIND_DRY=0, KIND_WET=1 *)
  iZposup          : DINT;    (* Z position at full up mm *)
  iZposdown        : DINT;    (* Z position at full down mm *)
  iZposslowup      : DINT;    (* Slow zone when going up (dry) mm *)
  iZposslowdown    : DINT;    (* Slow zone when going down (wet) mm *)
  iZposslowend     : DINT;    (* Slow zone at end of travel mm *)
  iSpeedliftslowZ : DINT;    (* Slow speed mm/s *)
  iSpeedliftfastZ : DINT;    (* Fast speed mm/s *)
  iDriptraydelay   : INT;     (* Drip tray open/close delay ×10 = tenths of second *)
  iDroppingtime    : INT;     (* Dropping/dripping time ×10 = tenths of second *)
END_VAR
VAR_IN_OUT
  ioZMm      : DINT;        (* Current Z position mm *)
  ioZStage   : INT;         (* Current motion stage *)
  ioZTimerS : REAL;        (* Delay timer — simulation internal *)
END_VAR
VAR_OUTPUT
  oDone : BOOL;             (* TRUE when sequence complete *)
END_VAR
VAR_EXTERNAL CONSTANT
  KIND_WET : INT;
END_VAR
VAR
  (* Internal REAL copies for physics integration *)
  vRZ          : REAL;
  vRTotal      : REAL;
  vRSlowZone  : REAL;
  vRSlowEnd   : REAL;
  vRSlowSpd   : REAL;
  vRFastSpd   : REAL;
  vRDrip       : REAL;
  vRDrop       : REAL;     (* dropping/dripping time seconds *)
  vZTotalMm   : DINT;     (* computed: iZposdown - iZposup *)
END_VAR

  oDone := FALSE;
  vZTotalMm := iZposdown - iZposup;

  (* Convert DINT/INT inputs to REAL for physics *)
  vRZ         := DINT_TO_REAL(ioZMm);
  vRTotal     := DINT_TO_REAL(vZTotalMm);
  vRSlowEnd  := DINT_TO_REAL(iZposslowend);
  vRSlowSpd  := DINT_TO_REAL(iSpeedliftslowZ);
  vRFastSpd  := DINT_TO_REAL(iSpeedliftfastZ);
  vRDrip      := INT_TO_REAL(iDriptraydelay) / 10.0;
  vRDrop      := INT_TO_REAL(iDroppingtime) / 10.0;

  (* Select slow zone based on station kind *)
  IF iStationKind = KIND_WET THEN
    vRSlowZone := DINT_TO_REAL(iZposslowdown);
  ELSE
    vRSlowZone := DINT_TO_REAL(iZposslowup);
  END_IF;

  CASE ioZStage OF

    (* === LIFT: stages 2-5,9 — nosto altaasta ylös (z kasvaa: 0 → z_total) === *)
    (* Stage 1 no longer used for lift — device_delay overlaps with treatment wait *)

    2: (* Slow lift start — hidas nosto nesteestä *)
      vRZ := vRZ + vRSlowSpd * iDeltaT;
      ioZMm := REAL_TO_DINT(vRZ);
      IF vRZ >= vRSlowZone THEN
        ioZStage := 3;
      END_IF;

    3: (* Fast lift — nopea nosto *)
      vRZ := vRZ + vRFastSpd * iDeltaT;
      ioZMm := REAL_TO_DINT(vRZ);
      IF vRZ >= (vRTotal - vRSlowEnd) THEN
        ioZStage := 4;
      END_IF;

    4: (* Slow lift end — hidas loppunosto *)
      vRZ := vRZ + vRSlowSpd * iDeltaT;
      IF vRZ >= vRTotal THEN
        ioZMm := vZTotalMm;
        ioZTimerS := vRDrop;
        ioZStage := 5;
      ELSE
        ioZMm := REAL_TO_DINT(vRZ);
      END_IF;

    5: (* Dropping / dripping — valutusaika yläasemassa *)
      ioZTimerS := ioZTimerS - iDeltaT;
      IF ioZTimerS <= 0.0 THEN
        ioZTimerS := vRDrip;
        ioZStage := 9;
      END_IF;

    9: (* Drip tray close — tippakouru sulkeutuu *)
      ioZTimerS := ioZTimerS - iDeltaT;
      IF ioZTimerS <= 0.0 THEN
        ioZStage := 0;
        oDone := TRUE;
      END_IF;

    (* === SINK: stages 6-8 — lasku altaaseen (z pienenee: z_total → 0) === *)

    6: (* Init delay: device_delay + drip_delay *)
      ioZTimerS := ioZTimerS - iDeltaT;
      IF ioZTimerS <= 0.0 THEN
        ioZStage := 7;
      END_IF;

    7: (* Fast sink — nopea lasku *)
      vRZ := vRZ - vRFastSpd * iDeltaT;
      ioZMm := REAL_TO_DINT(vRZ);
      IF vRZ <= vRSlowZone THEN
        ioZStage := 8;
      END_IF;

    8: (* Slow sink — hidas lasku nesteeseen *)
      vRZ := vRZ - vRSlowSpd * iDeltaT;
      IF vRZ <= 0.0 THEN
        ioZMm := 0;
        ioZStage := 0;
        oDone := TRUE;
      ELSE
        ioZMm := REAL_TO_DINT(vRZ);
      END_IF;

  END_CASE;

END_FUNCTION_BLOCK
