import React from 'react';
import { DraggablePanel } from '../index';

/**
 * TasksPanel — Manual task entry + executing tasks + task lists per transporter + unassigned tasks.
 * Extracted from App.jsx V3d.
 */
export default function TasksPanel({
  onClose,
  transporters,
  taskInputs, setTaskInputs,
  manualTasks,
  transporterStates,
  batches,
  transporterTasks,
  elapsedMs,
  handleSendTask,
  handleCancelManualTask,
}) {
  return (
    <DraggablePanel title="Tasks" onClose={onClose} width={Math.max(800, transporters.length * 220)}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        {/* Manuaalinen tehtävän anto - nostimet rinnakkain */}
        <div style={{ display: 'flex', gap: 12 }}>
          {transporters.map((t) => {
            const inputs = taskInputs[t.id] || { lift: '', sink: '' };
            return (
              <div key={t.id} style={{
                flex: 1,
                display: 'flex',
                flexDirection: 'column',
                gap: 6,
                padding: 8,
                border: '1px solid #ccc',
                borderRadius: 4,
                background: '#f9f9f9'
              }}>
                <div style={{ fontWeight: 700, fontSize: 13, textAlign: 'center', marginBottom: 2 }}>Transporter {t.id}</div>
                <div style={{ display: 'flex', gap: 4 }}>
                  <input
                    type="number"
                    value={inputs.lift}
                    onChange={(e) => setTaskInputs((prev) => ({ ...prev, [t.id]: { ...inputs, lift: e.target.value } }))}
                    placeholder="Lift"
                    style={{ flex: 1, padding: '4px 6px', borderRadius: 4, border: '1px solid #ccc', fontSize: 11 }}
                  />
                  <input
                    type="number"
                    value={inputs.sink}
                    onChange={(e) => setTaskInputs((prev) => ({ ...prev, [t.id]: { ...inputs, sink: e.target.value } }))}
                    placeholder="Sink"
                    style={{ flex: 1, padding: '4px 6px', borderRadius: 4, border: '1px solid #ccc', fontSize: 11 }}
                  />
                  <button
                    onClick={() => handleSendTask(t.id, inputs.lift, inputs.sink)}
                    style={{ padding: '4px 12px', borderRadius: 4, border: '1px solid #4caf50', background: '#e8f5e9', fontWeight: 600, cursor: 'pointer', fontSize: 11, whiteSpace: 'nowrap' }}
                  >
                    Set
                  </button>
                </div>
              </div>
            );
          })}
        </div>

        {/* Jonossa olevat manuaaliset tehtävät */}
        {manualTasks.length > 0 && (
          <div style={{
            padding: 8,
            border: '1px solid #ff9800',
            borderRadius: 4,
            background: '#fff3e0'
          }}>
            <div style={{ fontWeight: 700, fontSize: 12, marginBottom: 6, color: '#e65100' }}>
              ⏳ Queued Manual Tasks ({manualTasks.length})
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              {manualTasks.map((mt) => (
                <div key={mt.id} style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  padding: '4px 8px',
                  background: '#fff',
                  borderRadius: 3,
                  fontSize: 11,
                  border: '1px solid #ffcc80'
                }}>
                  <span>
                    <strong>T{mt.transporter_id}</strong>
                    {' '}{mt.lift_station_id} → {mt.sink_station_id}
                    {' '}
                    <span style={{ color: mt.status === 'fitted' ? '#2e7d32' : '#bf360c', fontWeight: 600 }}>
                      [{mt.status}]
                    </span>
                    {mt.fitted_start_s != null && (
                      <span style={{ color: '#666', marginLeft: 6 }}>
                        start: {mt.fitted_start_s.toFixed(0)}s
                      </span>
                    )}
                  </span>
                  <button
                    onClick={() => handleCancelManualTask(mt.id)}
                    style={{
                      padding: '2px 8px',
                      borderRadius: 3,
                      border: '1px solid #ef5350',
                      background: '#ffebee',
                      color: '#c62828',
                      cursor: 'pointer',
                      fontSize: 10,
                      fontWeight: 600
                    }}
                  >
                    ✕
                  </button>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Suorituksessa oleva tehtävä */}
        <div style={{ display: 'flex', gap: 12 }}>
          {transporters.map((t) => {
            const tState = transporterStates.find(s => s.id === t.id);
            const state = tState ? tState.state : {};
            const carriedBatch = batches.find((b) => b.location === t.id);
            const batchId = state.pending_batch_id != null ? state.pending_batch_id : (carriedBatch ? carriedBatch.batch_id : null);
            const hasTask = batchId != null || (state.lift_station_target != null && state.sink_station_target != null && state.operation !== 'idle');

            return (
              <div key={`exec-${t.id}`} style={{
                flex: 1,
                padding: 8,
                border: '1px solid #2196f3',
                borderRadius: 4,
                background: '#e3f2fd',
                minHeight: 60
              }}>
                <div style={{ fontWeight: 700, fontSize: 12, marginBottom: 4, color: '#1565c0' }}>Executing Task</div>
                {hasTask ? (
                  <div style={{ fontSize: 12 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                      <span><strong>Batch:</strong> {batchId != null ? `B${batchId}` : '-'}</span>
                      <span><strong>Op:</strong> {state.operation || 'idle'}</span>
                    </div>
                    <div style={{ marginTop: 2 }}>
                      <strong>Route:</strong> {state.lift_station_target || '?'} → {state.sink_station_target || '?'}
                    </div>
                  </div>
                ) : (
                  <div style={{ fontSize: 12, color: '#666', fontStyle: 'italic' }}>Idle</div>
                )}
              </div>
            );
          })}
        </div>

        {/* Tehtävälistat nostimittain */}
        <div style={{ display: 'flex', gap: 12 }}>
          {transporters.map((t) => {
            const tasksForTransporter = transporterTasks
              .filter(task => task.transporter_id === t.id)
              .sort((a, b) => a.task_start_time - b.task_start_time);
            return (
              <div key={`tasks-${t.id}`} style={{
                flex: 1,
                border: '1px solid #ddd',
                borderRadius: 4,
                padding: 8,
                background: '#fff'
              }}>
                <div style={{ fontWeight: 700, fontSize: 12, marginBottom: 8, paddingBottom: 4 }}>
                  Transporter {t.id} - Tasks ({tasksForTransporter.length})
                </div>
                <div style={{ fontSize: 11, maxHeight: 400, overflowY: 'auto' }}>
                  {tasksForTransporter.length === 0 ? (
                    <div style={{ padding: '4px 0', fontStyle: 'italic', color: '#666' }}>No tasks</div>
                  ) : (
                    <table style={{ width: '100%', borderCollapse: 'collapse' }}>
                      <thead>
                        <tr style={{ borderBottom: '2px solid #ddd' }}>
                          <th style={{ textAlign: 'left', padding: '4px 4px', fontWeight: 600, color: '#666' }}>Unit</th>
                          <th style={{ textAlign: 'right', padding: '4px 4px', fontWeight: 600, color: '#666' }}>Lift</th>
                          <th style={{ textAlign: 'right', padding: '4px 4px', fontWeight: 600, color: '#666' }}>Sink</th>
                          <th style={{ textAlign: 'right', padding: '4px 4px', fontWeight: 600, color: '#666' }}>Start</th>
                        </tr>
                      </thead>
                      <tbody>
                        {tasksForTransporter.map((task, idx) => {
                          const now = elapsedMs;
                          const relStart = Math.round(task.task_start_time - now);
                          const sign = relStart >= 0 ? '+' : '';
                          const absSec = Math.abs(relStart);
                          const mm = String(Math.floor(absSec / 60)).padStart(2, '0');
                          const ss = String(absSec % 60).padStart(2, '0');
                          const startStr = `${sign}${mm}:${ss}`;
                          return (
                            <tr key={idx} style={{
                              background: task.is_manual ? '#fff3e0' : '#e8f5e9',
                              borderBottom: idx < tasksForTransporter.length - 1 ? '1px solid #f0f0f0' : 'none'
                            }}>
                              <td style={{ textAlign: 'left', padding: '2px 4px', fontWeight: 600, fontSize: '10px' }}>
                                U{task.unit_id}
                              </td>
                              <td style={{ textAlign: 'right', padding: '2px 4px', fontFamily: 'monospace', fontSize: '10px' }}>{task.lift_station_id}</td>
                              <td style={{ textAlign: 'right', padding: '2px 4px', fontFamily: 'monospace', fontSize: '10px' }}>{task.sink_station_id}</td>
                              <td style={{ textAlign: 'right', padding: '2px 4px', fontFamily: 'monospace', color: '#999', fontSize: '10px' }}>{startStr}</td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  )}
                </div>
              </div>
            );
          })}
        </div>

        {/* Jakamattomien tehtävien lista */}
        <div style={{
          border: '1px solid #ddd',
          borderRadius: 4,
          padding: 8,
          background: '#fff'
        }}>
          <div style={{ fontWeight: 700, fontSize: 12, marginBottom: 8, paddingBottom: 4 }}>
            Unassigned Tasks ({transporterTasks.filter(task => task.transporter_id === null).length})
          </div>
          <div style={{ fontSize: 11, maxHeight: 400, overflowY: 'auto' }}>
            {transporterTasks.filter(task => task.transporter_id === null).length === 0 ? (
              <div style={{ padding: '4px 0', fontStyle: 'italic', color: '#666' }}>No unassigned tasks</div>
            ) : (
              <table style={{ width: '100%', borderCollapse: 'collapse' }}>
                <thead>
                  <tr style={{ borderBottom: '2px solid #ddd' }}>
                    <th style={{ textAlign: 'right', padding: '4px 4px', fontWeight: 600, color: '#666', width: '50px' }}>Lift</th>
                    <th style={{ textAlign: 'right', padding: '4px 4px', fontWeight: 600, color: '#666', width: '50px' }}>Sink</th>
                    <th style={{ textAlign: 'left', padding: '4px 8px', fontWeight: 600, color: '#666' }}>Task</th>
                  </tr>
                </thead>
                <tbody>
                  {transporterTasks
                    .filter(task => task.transporter_id === null)
                    .sort((a, b) => a.task_start_time - b.task_start_time)
                    .map((task, idx) => {
                      const now = elapsedMs;
                      const relStart = Math.round(task.task_start_time - now);
                      const relEnd = Math.round(task.task_finished_time - now);
                      const startStr = relStart > 0 ? `+${relStart}` : `${relStart}`;
                      const endStr = relEnd > 0 ? `+${relEnd}` : `${relEnd}`;
                      return (
                        <tr key={idx} style={{
                          borderBottom: idx < transporterTasks.filter(t => t.transporter_id === null).length - 1 ? '1px solid #f0f0f0' : 'none'
                        }}>
                          <td style={{ textAlign: 'right', padding: '2px 4px', fontFamily: 'monospace', color: '#999', fontSize: '10px' }}>{startStr}</td>
                          <td style={{ textAlign: 'right', padding: '2px 4px', fontFamily: 'monospace', color: '#999', fontSize: '10px' }}>{endStr}</td>
                          <td style={{ textAlign: 'left', padding: '2px 8px' }}>
                            <span style={{ fontWeight: 600 }}>B{task.batch_id}</span>
                            {' - '}
                            <span>{task.lift_station_id} → {task.sink_station_id}</span>
                          </td>
                        </tr>
                      );
                    })
                  }
                </tbody>
              </table>
            )}
          </div>
        </div>
      </div>
    </DraggablePanel>
  );
}
