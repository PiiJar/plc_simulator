(* STC_FindStationOffset - Find a station N steps away in a given direction *)

FUNCTION STC_FindStationOffset : INT

VAR_INPUT
    i_trans     : INT;
    i_from_stn  : INT;
    i_dir       : INT;
    i_min_steps : INT;
END_VAR

VAR
    from_x             : DINT;
    scan_station       : INT;
    step_count         : INT;
    station_x          : DINT;
    drive_min          : DINT;
    drive_max          : DINT;
    is_in_task_area    : BOOL;
    task_area_index    : INT;
END_VAR

STC_FindStationOffset := 0;

IF i_trans < 1 OR i_trans > MAX_Transporters THEN RETURN; END_IF;
IF i_from_stn < MIN_StationIndex OR i_from_stn > MAX_StationIndex THEN RETURN; END_IF;
IF i_dir <> 1 AND i_dir <> -1 THEN RETURN; END_IF;
IF i_min_steps < 1 THEN RETURN; END_IF;

from_x    := Stations[i_from_stn].XPosition;
drive_min := g_cfg[i_trans].DrivePosMin;
drive_max := g_cfg[i_trans].DrivePosMax;
step_count := 0;

IF i_dir = 1 THEN
    FOR scan_station := MIN_StationIndex TO MAX_StationIndex DO
        IF Stations[scan_station].TankId = 0 THEN CONTINUE; END_IF;

        station_x := Stations[scan_station].XPosition;
        IF station_x <= from_x THEN CONTINUE; END_IF;
        IF station_x > drive_max THEN CONTINUE; END_IF;

        is_in_task_area := FALSE;
        FOR task_area_index := 1 TO 3 DO
            IF g_cfg[i_trans].TaskArea[task_area_index].MinLift <> 0 THEN
                IF scan_station >= g_cfg[i_trans].TaskArea[task_area_index].MinLift
                     AND scan_station <= g_cfg[i_trans].TaskArea[task_area_index].MaxLift THEN
                    is_in_task_area := TRUE;
                END_IF;
                IF scan_station >= g_cfg[i_trans].TaskArea[task_area_index].MinSink
                     AND scan_station <= g_cfg[i_trans].TaskArea[task_area_index].MaxSink THEN
                    is_in_task_area := TRUE;
                END_IF;
            END_IF;
        END_FOR;
        IF NOT is_in_task_area THEN CONTINUE; END_IF;

        step_count := step_count + 1;
        IF step_count >= i_min_steps THEN
            STC_FindStationOffset := scan_station;
            RETURN;
        END_IF;
    END_FOR;
ELSE
    FOR scan_station := MAX_StationIndex TO MIN_StationIndex BY -1 DO
        IF Stations[scan_station].TankId = 0 THEN CONTINUE; END_IF;

        station_x := Stations[scan_station].XPosition;
        IF station_x >= from_x THEN CONTINUE; END_IF;
        IF station_x < drive_min THEN CONTINUE; END_IF;

        is_in_task_area := FALSE;
        FOR task_area_index := 1 TO 3 DO
            IF g_cfg[i_trans].TaskArea[task_area_index].MinLift <> 0 THEN
                IF scan_station >= g_cfg[i_trans].TaskArea[task_area_index].MinLift
                     AND scan_station <= g_cfg[i_trans].TaskArea[task_area_index].MaxLift THEN
                    is_in_task_area := TRUE;
                END_IF;
                IF scan_station >= g_cfg[i_trans].TaskArea[task_area_index].MinSink
                     AND scan_station <= g_cfg[i_trans].TaskArea[task_area_index].MaxSink THEN
                    is_in_task_area := TRUE;
                END_IF;
            END_IF;
        END_FOR;
        IF NOT is_in_task_area THEN CONTINUE; END_IF;

        step_count := step_count + 1;
        IF step_count >= i_min_steps THEN
            STC_FindStationOffset := scan_station;
            RETURN;
        END_IF;
    END_FOR;
END_IF;

STC_FindStationOffset := 0;

END_FUNCTION
