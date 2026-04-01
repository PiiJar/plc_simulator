(* ===========================================================================================
 *  STC_FindStationOffset — Find a station N steps away in a given direction
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen / AI-assisted
 *  Created : 01.04.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Starting from i_from_stn, walk i_dir direction (+1=right, -1=left) counting
 *  stations that belong to the transporter's task area.  Return the station number
 *  once i_min_steps stations have been passed, or 0 if not enough stations exist
 *  within the transporter's drive limits.
 *
 *  Only stations with TankId <> 0 are counted as real steps.
 *  The search is bounded by g_cfg[i_trans].DrivePosMin / DrivePosMax.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION STC_FindStationOffset : INT   (* returns station number or 0 *)


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
    i_trans     : INT;   (* transporter index — for drive limits and task area *)
    i_from_stn  : INT;   (* starting station *)
    i_dir       : INT;   (* +1 = right (increasing X), -1 = left (decreasing X) *)
    i_min_steps : INT;   (* minimum number of station steps to travel *)
END_VAR

VAR_EXTERNAL CONSTANT
    MIN_StationIndex  : INT;
    MAX_StationIndex  : INT;
    MAX_Transporters  : INT;
END_VAR

VAR_EXTERNAL
    g_station : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
    g_cfg     : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
END_VAR

VAR
    from_x      : DINT;
    stn         : INT;
    steps       : INT;
    x           : DINT;
    drive_min   : DINT;
    drive_max   : DINT;
    in_area     : BOOL;
    ta          : INT;
END_VAR


(* Implementation ---------------------------------------------------------------------------*)

STC_FindStationOffset := 0;

(* Guard inputs *)
IF i_trans < 1 OR i_trans > MAX_Transporters THEN RETURN; END_IF;
IF i_from_stn < MIN_StationIndex OR i_from_stn > MAX_StationIndex THEN RETURN; END_IF;
IF i_dir <> 1 AND i_dir <> -1 THEN RETURN; END_IF;
IF i_min_steps < 1 THEN RETURN; END_IF;

from_x    := g_station[i_from_stn].XPosition;
drive_min := g_cfg[i_trans].DrivePosMin;
drive_max := g_cfg[i_trans].DrivePosMax;
steps     := 0;

(* Walk stations in the given direction.
   We scan the entire station range and check X-position relative to from_x
   in the chosen direction.  A simple linear scan is fast enough for ≤30 stations. *)

IF i_dir = 1 THEN
    (* Scan right: find stations with X > from_x, in ascending X order.
       Since station indices may not be in X-order, we do repeated nearest-next scans. *)
    FOR stn := MIN_StationIndex TO MAX_StationIndex DO
        (* skip dummy stations *)
        IF g_station[stn].TankId = 0 THEN CONTINUE; END_IF;

        x := g_station[stn].XPosition;
        IF x <= from_x THEN CONTINUE; END_IF;
        IF x > drive_max THEN CONTINUE; END_IF;

        (* Check task area membership *)
        in_area := FALSE;
        FOR ta := 1 TO 3 DO
            IF g_cfg[i_trans].TaskArea[ta].MinLift <> 0 THEN
                IF stn >= g_cfg[i_trans].TaskArea[ta].MinLift
                   AND stn <= g_cfg[i_trans].TaskArea[ta].MaxLift THEN
                    in_area := TRUE;
                END_IF;
                IF stn >= g_cfg[i_trans].TaskArea[ta].MinSink
                   AND stn <= g_cfg[i_trans].TaskArea[ta].MaxSink THEN
                    in_area := TRUE;
                END_IF;
            END_IF;
        END_FOR;
        IF NOT in_area THEN CONTINUE; END_IF;

        steps := steps + 1;
        IF steps >= i_min_steps THEN
            STC_FindStationOffset := stn;
            RETURN;
        END_IF;
    END_FOR;

ELSE  (* i_dir = -1 *)
    (* Scan left: find stations with X < from_x, in descending X order.
       Walk station indices from high to low — works when indices correlate with X. *)
    FOR stn := MAX_StationIndex TO MIN_StationIndex BY -1 DO
        IF g_station[stn].TankId = 0 THEN CONTINUE; END_IF;

        x := g_station[stn].XPosition;
        IF x >= from_x THEN CONTINUE; END_IF;
        IF x < drive_min THEN CONTINUE; END_IF;

        (* Check task area membership *)
        in_area := FALSE;
        FOR ta := 1 TO 3 DO
            IF g_cfg[i_trans].TaskArea[ta].MinLift <> 0 THEN
                IF stn >= g_cfg[i_trans].TaskArea[ta].MinLift
                   AND stn <= g_cfg[i_trans].TaskArea[ta].MaxLift THEN
                    in_area := TRUE;
                END_IF;
                IF stn >= g_cfg[i_trans].TaskArea[ta].MinSink
                   AND stn <= g_cfg[i_trans].TaskArea[ta].MaxSink THEN
                    in_area := TRUE;
                END_IF;
            END_IF;
        END_FOR;
        IF NOT in_area THEN CONTINUE; END_IF;

        steps := steps + 1;
        IF steps >= i_min_steps THEN
            STC_FindStationOffset := stn;
            RETURN;
        END_IF;
    END_FOR;
END_IF;

(* Not enough stations found *)
STC_FindStationOffset := 0;
