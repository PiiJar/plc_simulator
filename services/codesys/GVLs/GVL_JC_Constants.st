(* GVL_JC_Constants — Global constants *)
(* Identical names to globals.st VAR_GLOBAL CONSTANT — no renaming needed *)
VAR_GLOBAL CONSTANT

  (* ===== Layout Hierarchy Limits ===== *)
  MAX_STATIONS_PER_LINE     : INT  := 30;   (* max stations per line *)
  MIN_StationIndex          : INT  := 100;  (* first valid station index *)
  MAX_StationIndex          : INT  := 130;  (* MaxLines*100 + MaxStationsPerLine *)

  (* ===== Derived Absolute Limits ===== *)
  MAX_Transporters          : INT  := 3;   (* absolute max transporters in a plant *)
  MAX_Units                 : INT  := 10;  (* max units (lifting frames / hooks) *)
  MAX_STATIONS_PER_STEP     : INT  := 5;   (* max parallel stations per program stage *)
  MAX_STEPS_PER_PROGRAM     : INT  := 30;  (* max stages in a treatment program *)
  MAX_TASK_QUEUE            : INT  := 30;  (* max tasks per transporter queue — must match UDT_JC_TskQueueType.Queue size *)

  (* ===== Algorithm / Scheduler Limits ===== *)
  MAX_LOCKS                 : INT  := 50;  (* max locked stages in conflict resolution *)
  DEP_MAX_IDLE_SLOTS        : INT  := 20;  (* max idle slots per transporter *)
  DEP_MAX_DELAY_ACTS        : INT  := 20;  (* max delay actions per cycle *)
  DEP_MAX_WAITING           : INT  := 5;   (* max waiting batches *)
  MIN_WorkingArea           : DINT := 20;  (* mm — TWA minimum working area *)

  (* ===== Scheduler Timing Constants ===== *)
  SCH_DISPATCH_MARGIN_S     : REAL := 3.0;  (* dispatch early-start margin (seconds) *)
  SCH_CONFLICT_MARGIN_S     : REAL := 2.0;  (* conflict detection margin (seconds) *)
  SCH_DEP_FLEX_FACTOR       : REAL := 0.6;  (* fraction of flex (max-cal) used by DEP *)
  SCH_TSK_FLEX_FACTOR       : REAL := 0.9;  (* fraction of flex (max-cal) used by TSK scheduler *)
  SCH_MARGIN_S              : REAL := 5.0;  (* DEP small-delay threshold (seconds) *)
  SCH_MAX_INIT_WAIT_S       : REAL := 120.0;  (* max initial wait for stage0 pickup (seconds) *)
  SCH_MAX_FIT_ROUNDS        : INT  := 50;  (* max recalc rounds in DEP fit loop *)

  (* ===== Enumerated Constants ===== *)

  (* Unit status *)
  USED                      : INT  := 1;  (* unit in use *)
  NOT_USED                  : INT  := 0;  (* unit not in use *)

  (* Unit target *)
  TO_NONE                   : INT  := 0;  (* no target *)
  TO_LOADING                : INT  := 1;  (* target: loading station *)
  TO_BUFFER                 : INT  := 2;  (* target: buffer station *)
  TO_PROCESS                : INT  := 3;  (* target: process station *)
  TO_UNLOAD                 : INT  := 4;  (* target: unloading station *)
  TO_AVOID                  : INT  := 5;  (* target: avoidance position *)

  (* Station kind *)
  KIND_DRY                  : INT  := 0;  (* dry station *)
  KIND_WET                  : INT  := 1;  (* wet station *)

  (* Station operation — logistics *)
  OP_BUFFER                 : INT  := 30;  (* buffer station *)
  OP_BUFFER_PROCESSED       : INT  := 33;  (* processed buffer station *)
  OP_LOADING                : INT  := 40;  (* loading operation *)
  OP_LOADING_UNLOADING      : INT  := 42;  (* combined loading/unloading *)

  (* Batch state *)
  NOT_PROCESSED             : INT  := 0;  (* batch not yet processed *)
  IN_PROCESS                : INT  := 1;  (* batch currently in process *)
  PROCESSED                 : INT  := 2;  (* batch processing complete *)

  (* Avoid status for stations (TWA) *)
  AVOID_None                : INT  := 0;  (* station not avoided *)
  AVOID_Passable            : INT  := 1;  (* pass through allowed, no stop *)
  AVOID_Block               : INT  := 2;  (* hard block, cannot pass *)

  (* Take-out constants *)
  TAKE_OUT_MIN_WAIT_S       : INT  := 60;  (* do not start take-out if next task on same station starts within this many seconds *)
END_VAR
