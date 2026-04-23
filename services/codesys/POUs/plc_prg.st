(* ===========================================================================================
 *  PLC_PRG — Main program (CODESYS / OPC UA)
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Simulator version: delegates SIM-specific logic to SIM_FB_MainCycle.
 *
 *  Production version would replace vFB_SimMain with:
 *    - Real PLC clock → TimeS
 *    - TWA calc
 *    - (no command handler, no physics, no UI snapshot, no event queue)
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


PROGRAM PLC_PRG


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_EXTERNAL
  TimeS                  : LINT;
END_VAR

VAR
  vFB_SimMain                  : SIM_FB_MainCycle;
  vFB_MainScheduler            : STC_FB_MainScheduler;
END_VAR

(* ── Simulator: command handler, time, TWA, physics, UI snapshot, events ── *)
vFB_SimMain();

(* ── Main Scheduler (TSK + DEP alternating cycles) ──
   MUST run outside init_done block so that when init_done=FALSE
   (during RESET), MainScheduler's iRun=FALSE path executes,
   properly resetting internal state of both TSK and DEP FBs. *)
vFB_MainScheduler(iRun := vFB_SimMain.oInitDone, iTimeS := TimeS);

END_PROGRAM
