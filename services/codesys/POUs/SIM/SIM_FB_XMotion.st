(* ============================================================
   SIM_FB_XMotion — Horizontal motion with accel / decel

   Company : Galvatek part of the John Cockerill Group
   Author  : Jarmo Piipponen
   Created : 25.03.2026
   ============================================================
   Trapezoidal velocity profile: accelerate, cruise, decelerate.
   Clamps position to [iXMin..iXMax] drive limits.
   VAR_IN_OUT: ioXPos, ioVX (modified in place).
   ------------------------------------------------------------
   Changes:
   ============================================================ *)

FUNCTION_BLOCK SIM_FB_XMotion
VAR_INPUT
  iDeltaT  : REAL;     (* cycle time s — simulation internal *)
  iXTarget : DINT;     (* target X mm *)
  iXMin    : DINT;     (* TWA lower limit mm *)
  iXMax    : DINT;     (* TWA upper limit mm *)
  iVMax    : DINT;     (* max velocity mm/s *)
  iTAcc    : DINT;     (* acceleration time ×10 = tenths of second *)
  iTDec    : DINT;     (* deceleration time ×10 = tenths of second *)
END_VAR
VAR_IN_OUT
  ioXPos : DINT;        (* current X position mm *)
  ioVX   : DINT;        (* current X velocity mm/s *)
END_VAR
VAR_OUTPUT
  oArrived : BOOL;
  oXDrive : DINT;      (* actual drive target after limit clamping *)
END_VAR
VAR
  (* Internal REAL copies for physics integration *)
  vRTarget     : REAL;
  vRMin        : REAL;
  vRMax        : REAL;
  vRVmax       : REAL;
  vRTacc       : REAL;
  vRTdec       : REAL;
  vRPos        : REAL;
  vRVel        : REAL;
  vDriveTarget : REAL;
  vDistance     : REAL;
  vDir          : REAL;
  vAAcc        : REAL;
  vADec        : REAL;
  vBrakeDist   : REAL;
  vNewVel      : REAL;
  vTravel       : REAL;
END_VAR
  (* Convert DINT/INT inputs to REAL for physics *)
  vRTarget := DINT_TO_REAL(iXTarget);
  vRMin    := DINT_TO_REAL(iXMin);
  vRMax    := DINT_TO_REAL(iXMax);
  vRVmax   := DINT_TO_REAL(iVMax);
  vRTacc   := DINT_TO_REAL(iTAcc) / 10.0;
  vRTdec   := DINT_TO_REAL(iTDec) / 10.0;
  vRPos    := DINT_TO_REAL(ioXPos);
  vRVel    := DINT_TO_REAL(ioVX);

  IF (vRMax > vRMin) THEN
    IF vRPos < vRMin THEN
      vDriveTarget := vRMin;
    ELSIF vRPos > vRMax THEN
      vDriveTarget := vRMax;
    ELSE
      IF vRTarget < vRMin THEN
        vDriveTarget := vRMin;
      ELSIF vRTarget > vRMax THEN
        vDriveTarget := vRMax;
      ELSE
        vDriveTarget := vRTarget;
      END_IF;
    END_IF;
  ELSE
    vDriveTarget := vRTarget;
  END_IF;

  oXDrive := REAL_TO_DINT(vDriveTarget);

  oArrived := ABS(vRPos - vDriveTarget) <= 3.0;
  IF oArrived THEN
    ioXPos := REAL_TO_DINT(vDriveTarget);
    ioVX := 0;
    RETURN;
  END_IF;

  IF vRTacc <= 0.0 THEN vRTacc := 0.001; END_IF;
  IF vRTdec <= 0.0 THEN vRTdec := 0.001; END_IF;
  IF vRVmax < 0.0 THEN vRVmax := 0.0; END_IF;

  vAAcc := vRVmax / vRTacc;
  vADec := vRVmax / vRTdec;

  vDir := 1.0;
  IF vDriveTarget < vRPos THEN
    vDir := -1.0;
  END_IF;

  vDistance := ABS(vDriveTarget - vRPos);

  IF vADec > 0.0 THEN
    vBrakeDist := (vRVel * vRVel) / (2.0 * vADec);
  ELSE
    vBrakeDist := 0.0;
  END_IF;

  IF vBrakeDist >= vDistance THEN
    vNewVel := vRVel - vADec * iDeltaT;
    IF vNewVel < 0.0 THEN vNewVel := 0.0; END_IF;
  ELSE
    vNewVel := vRVel + vAAcc * iDeltaT;
    IF vNewVel > vRVmax THEN vNewVel := vRVmax; END_IF;
  END_IF;

  vTravel := vNewVel * iDeltaT;
  IF vTravel >= vDistance THEN
    ioXPos := REAL_TO_DINT(vDriveTarget);
    ioVX := 0;
    oArrived := TRUE;
  ELSE
    ioXPos := REAL_TO_DINT(vRPos + vDir * vTravel);
    ioVX := REAL_TO_DINT(vNewVel);
    oArrived := FALSE;
  END_IF;
END_FUNCTION_BLOCK

