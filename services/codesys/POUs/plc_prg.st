(* ===========================================================================================
 *  PLC_PRG — Main program (CODESYS / OPC UA)
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Simulator version: delegates SIM-specific logic to FB_SIM_MainCycle.
 *
 *  Production version would replace vFB_SimMainCycle with:
 *    - Real PLC clock → gTimeS
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
  gTimeS : LINT;
END_VAR

VAR
  vFB_SimMainCycle  : FB_SIM_MainCycle;
  vFB_MainScheduler : FB_STC_MainScheduler;
END_VAR

(* ── Simulator: command handler, time, TWA, physics, UI snapshot, events ── *)
vFB_SimMainCycle();

(* ── Main Scheduler (TSK + DEP alternating cycles) ──
   MUST run outside vInitDone block so that when vInitDone=FALSE
   (during RESET), MainScheduler's iRun=FALSE path executes,
   properly resetting internal state of both TSK and DEP FBs. *)
vFB_MainScheduler(iRun := vFB_SimMainCycle.oInitDone, iTimeS := gTimeS);

END_PROGRAM
