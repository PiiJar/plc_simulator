import React from 'react';
import DraggablePanel from '../StationLayout/helpers/DraggablePanel';

export default function UnitsPanel(props) {
  const { config, setConfig, loadError, setLoadError, isRunning, setIsRunning, isResetting, setIsResetting, elapsedMs, setElapsedMs, speed, setSpeed, avgCycleSec, setAvgCycleSec, productionStats, setProductionStats, showBatches, setShowBatches, showTasks, setShowTasks, showProduction, setShowProduction, productionPrograms, setProductionPrograms, productionProgramDetails, setProductionProgramDetails, productionRows, setProductionRows, productionSaving, setProductionSaving, productionError, setProductionError, productionSetup, setProductionSetup, productionSetupSaving, setProductionSetupSaving, taskInputs, setTaskInputs, transporters, setTransporters, stations, setStations, tanks, setTanks, batches, setBatches, units, setUnits, transporterTasks, setTransporterTasks, manualTasks, setManualTasks, avoidStatuses, setAvoidStatuses, transporterStates, setTransporterStates, displayTransporterStates, setDisplayTransporterStates, debugTransporterId, setDebugTransporterId, editingBatchId, setEditingBatchId, plantSetups, setPlantSetups, selectedPlantSetup, setSelectedPlantSetup, showCustomer, setShowCustomer, customers, setCustomers, selectedCustomer, setSelectedCustomer, selectedPlant, setSelectedPlant, customerPlants, setCustomerPlants, customerError, setCustomerError, creatingCustomer, setCreatingCustomer, newCustomerName, setNewCustomerName, creatingPlant, setCreatingPlant, newPlantName, setNewPlantName, plantStatus, setPlantStatus, selectedTemplate, setSelectedTemplate, copyingTemplate, setCopyingTemplate, simPurpose, setSimPurpose, simPurposeForm, setSimPurposeForm, simPurposeSaving, setSimPurposeSaving, plcStatus, setPlcStatus, plcToggling, setPlcToggling, productionQueue, setProductionQueue, productionStartTime, setProductionStartTime, productionDuration, setProductionDuration, showConfig, setShowConfig, showCalibration, setShowCalibration, configForm, setConfigForm, configSaving, setConfigSaving, configError, setConfigError, batchForm, setBatchForm, batchSaving, setBatchSaving, batchError, setBatchError, selectedUnitId, setSelectedUnitId, unitLocationEdit, setUnitLocationEdit, unitBatchEdit, setUnitBatchEdit, unitStatusEdit, setUnitStatusEdit, unitTargetEdit, setUnitTargetEdit, unitSaving, setUnitSaving, api, fetchBatchesFromApi, fetchUnitsFromApi, formatTime, resetBatchForm, emptyBatchForm, handleAddProductionRow, handleRemoveProductionRow, handleProductionRowChange, handleSaveProductionSetup, handleCreateProduction, fetchSimulationState, handleManualTask, cancelManualTask } = props;

  return (
    <DraggablePanel title="Units" onClose={() => {
  setShowBatches(false);
  resetBatchForm();
}} width={880}>
            <div style={{
    display: 'flex',
    flexDirection: 'column',
    gap: 12
  }}>
              {batchError && <div style={{
      color: '#c62828',
      fontWeight: 600,
      fontSize: 13
    }}>{batchError}</div>}

              {/* Unit list — read from PLC */}
              <div style={{
      maxHeight: 260,
      overflowY: 'auto',
      border: '1px solid #eee',
      borderRadius: 6,
      padding: 8,
      background: '#fafafa'
    }}>
                <table style={{
        width: '100%',
        borderCollapse: 'collapse',
        fontSize: 12
      }}>
                  <thead>
                    <tr style={{
            borderBottom: '2px solid #ccc',
            textAlign: 'left'
          }}>
                      <th style={{
              padding: '3px 4px'
            }}>Unit</th>
                      <th style={{
              padding: '3px 4px'
            }}>Loc</th>
                      <th style={{
              padding: '3px 4px'
            }}>Status</th>
                      <th style={{
              padding: '3px 4px'
            }}>Target</th>
                      <th style={{
              padding: '3px 4px',
              borderLeft: '2px solid #90caf9'
            }}>Batch</th>
                      <th style={{
              padding: '3px 4px'
            }}>State</th>
                      <th style={{
              padding: '3px 4px'
            }}>Program</th>
                      <th style={{
              padding: '3px 4px'
            }}>Stage</th>
                      <th style={{
              padding: '3px 4px'
            }}>MinTime</th>
                      <th style={{
              padding: '3px 4px'
            }}>MaxTime</th>
                      <th style={{
              padding: '3px 4px'
            }}>CalcTime</th>
                      <th style={{
              padding: '3px 4px'
            }}></th>
                    </tr>
                  </thead>
                  <tbody>
                    {units.map(u => {
            const statusLabels = {
              0: 'not_used',
              1: 'used'
            };
            const targetLabels = {
              'none': 'none',
              'to_loading': 'to_load',
              'to_buffer': 'to_buf',
              'to_process': 'to_proc',
              'to_unload': 'to_unl',
              'to_avoid': 'to_avoid',
              0: 'none',
              1: 'to_load',
              2: 'to_buf',
              3: 'to_proc',
              4: 'to_unl',
              5: 'to_avoid'
            };
            const batchStateLabels = {
              'not_processed': 'Not Processed',
              'in_process': 'In Process',
              'processed': 'Processed'
            };
            const isUsed = u.status === 1;
            const hasBatch = u.batch_code && u.batch_code !== 0;
            const fmtTime = s => s != null && s !== 0 ? `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}` : '—';
            return <tr key={u.unit_id} style={{
              borderBottom: '1px solid #f0f0f0',
              opacity: isUsed ? 1 : 0.5
            }}>
                          <td style={{
                padding: '3px 4px',
                fontWeight: 700
              }}>U{u.unit_id}</td>
                          <td style={{
                padding: '3px 4px'
              }}>{u.location || '—'}</td>
                          <td style={{
                padding: '3px 4px'
              }}>{statusLabels[u.status] || u.status}</td>
                          <td style={{
                padding: '3px 4px'
              }}>{targetLabels[u.target] || u.target}</td>
                          <td style={{
                padding: '3px 4px',
                borderLeft: '2px solid #90caf9',
                color: hasBatch ? '#1565c0' : '#999',
                fontWeight: hasBatch ? 700 : 400
              }}>{hasBatch ? u.batch_code : '—'}</td>
                          <td style={{
                padding: '3px 4px',
                color: hasBatch ? '#333' : '#999'
              }}>{hasBatch ? batchStateLabels[u.batch_state] || u.batch_state : '—'}</td>
                          <td style={{
                padding: '3px 4px',
                color: hasBatch ? '#333' : '#999'
              }}>{hasBatch ? u.batch_program ?? '—' : '—'}</td>
                          <td style={{
                padding: '3px 4px',
                color: hasBatch ? '#333' : '#999'
              }}>{hasBatch ? u.batch_stage ?? '—' : '—'}</td>
                          <td style={{
                padding: '3px 4px',
                color: hasBatch ? '#333' : '#999'
              }}>{hasBatch ? fmtTime(u.batch_min_time) : '—'}</td>
                          <td style={{
                padding: '3px 4px',
                color: hasBatch ? '#333' : '#999'
              }}>{hasBatch ? fmtTime(u.batch_max_time) : '—'}</td>
                          <td style={{
                padding: '3px 4px',
                color: hasBatch ? '#333' : '#999'
              }}>{hasBatch ? fmtTime(u.batch_cal_time) : '—'}</td>
                          <td style={{
                padding: '3px 4px'
              }}>
                            <button onClick={() => handleUnitSelect(String(u.unit_id))} style={{
                  padding: '3px 6px',
                  borderRadius: 4,
                  border: '1px solid #2196f3',
                  background: selectedUnitId === String(u.unit_id) ? '#1565c0' : '#e3f2fd',
                  color: selectedUnitId === String(u.unit_id) ? '#fff' : '#333',
                  cursor: 'pointer',
                  fontSize: 11
                }}>
                              Edit
                            </button>
                          </td>
                        </tr>;
          })}
                    {units.length === 0 && <tr><td colSpan={12} style={{
              padding: 8,
              color: '#666',
              textAlign: 'center'
            }}>No units (PLC not connected?)</td></tr>}
                  </tbody>
                </table>
              </div>

              {/* Unit edit form */}
              {selectedUnitId !== '' && <div style={{
      border: '1px solid #90caf9',
      borderRadius: 6,
      padding: 10,
      background: '#e3f2fd',
      display: 'flex',
      flexDirection: 'column',
      gap: 8
    }}>
                  <div style={{
        fontWeight: 700,
        fontSize: 14
      }}>Edit Unit {selectedUnitId}</div>
                  <div style={{
        display: 'flex',
        gap: 8,
        alignItems: 'flex-end'
      }}>
                    <label style={{
          display: 'flex',
          flexDirection: 'column',
          gap: 4,
          fontSize: 12,
          width: 72
        }}>
                      Batch ID
                      <input type="number" value={unitBatchEdit} onChange={e => setUnitBatchEdit(Number(e.target.value) || 0)} style={{
            padding: '6px 8px',
            borderRadius: 4,
            border: '1px solid #90caf9',
            background: '#fff',
            fontSize: 12
          }} />
                    </label>
                    <label style={{
          display: 'flex',
          flexDirection: 'column',
          gap: 4,
          fontSize: 12,
          width: 64
        }}>
                      Location
                      <input type="text" inputMode="numeric" pattern="[0-9]*" value={unitLocationEdit} onChange={e => {
            if (/^\d*$/.test(e.target.value)) setUnitLocationEdit(e.target.value);
          }} style={{
            padding: '6px 8px',
            borderRadius: 4,
            border: '1px solid #90caf9',
            background: '#fff',
            fontSize: 12
          }} />
                    </label>
                    <label style={{
          display: 'flex',
          flexDirection: 'column',
          gap: 4,
          fontSize: 12,
          flex: 1
        }}>
                      Status
                      <select value={unitStatusEdit} onChange={e => setUnitStatusEdit(Number(e.target.value))} style={{
            padding: '6px 8px',
            borderRadius: 4,
            border: '1px solid #90caf9',
            background: '#fff',
            fontSize: 12
          }}>
                        <option value={0}>NOT_USED (0)</option>
                        <option value={1}>USED (1)</option>
                      </select>
                    </label>
                    <label style={{
          display: 'flex',
          flexDirection: 'column',
          gap: 4,
          fontSize: 12,
          flex: 1
        }}>
                      Target
                      <select value={unitTargetEdit} onChange={e => setUnitTargetEdit(e.target.value)} style={{
            padding: '6px 8px',
            borderRadius: 4,
            border: '1px solid #90caf9',
            background: '#fff',
            fontSize: 12
          }}>
                        <option value="none">TO_NONE (0)</option>
                        <option value="to_loading">TO_LOADING (1)</option>
                        <option value="to_buffer">TO_BUFFER (2)</option>
                        <option value="to_process">TO_PROCESS (3)</option>
                        <option value="to_unload">TO_UNLOAD (4)</option>
                        <option value="to_avoid">TO_AVOID (5)</option>
                      </select>
                    </label>
                    <button type="button" disabled={unitSaving} onClick={handleUnitSave} style={{
          padding: '6px 12px',
          borderRadius: 4,
          border: '1px solid #1565c0',
          background: '#1565c0',
          color: '#fff',
          fontWeight: 700,
          cursor: 'pointer',
          fontSize: 11,
          whiteSpace: 'nowrap'
        }}>
                      {unitSaving ? '...' : 'Save to PLC'}
                    </button>
                  </div>
                </div>}
            </div>
          </DraggablePanel>
  );
}
