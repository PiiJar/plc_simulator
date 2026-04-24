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
 *  Production version would replace sim_main with:
 *    - Real PLC clock → g_time_s
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
  g_time_s                  : LINT;
END_VAR

VAR
  sim_main                  : FB_SIM_MainCycle;
  main_scheduler            : FB_STC_MainScheduler;
END_VAR

(* ── Simulator: command handler, time, TWA, physics, UI snapshot, events ── *)
sim_main();

(* ── Main Scheduler (TSK + DEP alternating cycles) ──
   MUST run outside init_done block so that when init_done=FALSE
   (during RESET), MainScheduler's i_run=FALSE path executes,
   properly resetting internal state of both TSK and DEP FBs. *)
main_scheduler(i_run := sim_main.o_init_done, i_time_s := g_time_s);

END_PROGRAM
