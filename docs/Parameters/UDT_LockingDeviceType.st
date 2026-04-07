(* UDT_LockingDeviceType - Configuration data for locking device controller *)
(* Used by FB_LockingDevice-style logic for process timings and enable state *)
(* Hardware-specific I/O mapping remains in the consuming FB or lower-level I/O layer *)
TYPE UDT_LockingDeviceType :
STRUCT
    Id : INT; (* Primary key *)
    StationId : INT; (* Associated station/loading-place index *)
    IsInUse : BOOL; (* TRUE when locking device is configured and enabled *)
    PhotocellWaitTime : INT; (* Max wait time for photocell/product detect in milliseconds *)
    WaitUnlockTime : INT; (* Delay after unlock command before next step in milliseconds *)
    WaitAfterOpening : INT; (* Delay after fully opened position in milliseconds *)
    AlarmLockingTimeout : INT; (* Max time to complete locking cycle in milliseconds *)
    AlarmUnlockingTimeout : INT; (* Max time to complete unlocking cycle in milliseconds *)
    DelayForPullCylinders : INT; (* Delay before pull cylinders actuate in milliseconds *)
END_STRUCT
END_TYPE