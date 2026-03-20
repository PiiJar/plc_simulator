import React from 'react';
import { DraggablePanel } from '../index';

/**
 * ProductionPanel — Production setup and batch creation.
 * Extracted from App.jsx V3b.
 */
export default function ProductionPanel({
  onClose,
  productionError,
  productionPrograms, productionProgramDetails,
  productionSetup, setProductionSetup,
  productionRows,
  stations,
  productionSaving, productionSetupSaving,
  handleProductionRowChange, handleRemoveProductionRow, handleAddProductionRow,
  handleSaveProductionSetup, handleCreateProduction,
  fetchBatchesFromApi, fetchUnitsFromApi,
  setShowProduction,
}) {
  return (
    <DraggablePanel title="Production" onClose={onClose}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        {productionError && (
          <div style={{ color: '#c62828', fontWeight: 600, fontSize: 13 }}>{productionError}</div>
        )}

        {productionPrograms.length === 0 ? (
          <div style={{ color: '#666', fontSize: 13 }}>No treatment programs found in this setup.</div>
        ) : (
          <>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10, padding: 10, border: '1px solid #eee', borderRadius: 6, background: '#fafafa' }}>
              <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                Start Station
                <select
                  value={productionSetup.start_station}
                  onChange={(e) => setProductionSetup((s) => ({ ...s, start_station: e.target.value }))}
                  style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc', background: '#fff', cursor: 'pointer' }}
                >
                  <option value="">-- select --</option>
                  {stations.map((st) => (
                    <option key={st.number} value={st.number}>{st.number} - {st.name || `Station ${st.number}`}</option>
                  ))}
                </select>
              </label>
              <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                Finishing Station
                <select
                  value={productionSetup.finish_station}
                  onChange={(e) => setProductionSetup((s) => ({ ...s, finish_station: e.target.value }))}
                  style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc', background: '#fff', cursor: 'pointer' }}
                >
                  <option value="">-- select --</option>
                  {stations.map((st) => (
                    <option key={st.number} value={st.number}>{st.number} - {st.name || `Station ${st.number}`}</option>
                  ))}
                </select>
              </label>
              <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                Loading Time (s)
                <input type="number" min="0" step="1" value={productionSetup.loading_time_s}
                  onChange={(e) => setProductionSetup((s) => ({ ...s, loading_time_s: e.target.value }))}
                  style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc' }}
                />
              </label>
              <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                Unloading Time (s)
                <input type="number" min="0" step="1" value={productionSetup.unloading_time_s}
                  onChange={(e) => setProductionSetup((s) => ({ ...s, unloading_time_s: e.target.value }))}
                  style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc' }}
                />
              </label>
              <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13, gridColumn: 'span 2' }}>
                Duration (hours)
                <input type="number" min="0" step="0.5" value={productionSetup.duration_hours}
                  onChange={(e) => setProductionSetup((s) => ({ ...s, duration_hours: e.target.value }))}
                  placeholder="Target production time in hours"
                  style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc' }}
                />
              </label>
              <div style={{ gridColumn: 'span 2', display: 'flex', gap: 8 }} />
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              {productionRows.map((row, idx) => (
                <div key={`prod-row-${idx}`} style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr 1fr auto', gap: 8, alignItems: 'center', padding: 8, border: '1px solid #eee', borderRadius: 6, background: '#fafafa' }}>
                  <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                    Count
                    <input type="number" min="1" step="1" value={row.count}
                      onChange={(e) => handleProductionRowChange(idx, 'count', e.target.value)}
                      style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc' }}
                    />
                  </label>
                  <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                    Treatment program
                    <select value={row.program}
                      onChange={(e) => handleProductionRowChange(idx, 'program', Number(e.target.value))}
                      style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc', background: '#fff', cursor: 'pointer' }}
                    >
                      {productionProgramDetails.map((p) => (
                        <option key={p.number} value={p.number}>{p.filename}</option>
                      ))}
                    </select>
                  </label>
                  <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                    Start Station
                    <select value={row.start_station}
                      onChange={(e) => handleProductionRowChange(idx, 'start_station', e.target.value)}
                      style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc', background: '#fff', cursor: 'pointer' }}
                    >
                      <option value="">-- default --</option>
                      {stations.map((st) => (
                        <option key={st.number} value={st.number}>{st.number} - {st.name || `Station ${st.number}`}</option>
                      ))}
                    </select>
                  </label>
                  <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                    End Station
                    <select value={row.end_station}
                      onChange={(e) => handleProductionRowChange(idx, 'end_station', e.target.value)}
                      style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc', background: '#fff', cursor: 'pointer' }}
                    >
                      <option value="">-- default --</option>
                      {stations.map((st) => (
                        <option key={st.number} value={st.number}>{st.number} - {st.name || `Station ${st.number}`}</option>
                      ))}
                    </select>
                  </label>
                  <div style={{ display: 'flex', justifyContent: 'flex-end', alignItems: 'center', gap: 8 }}>
                    {productionPrograms.length > 1 && productionRows.length > 1 && (
                      <button type="button" onClick={() => handleRemoveProductionRow(idx)}
                        style={{ padding: '8px 12px', borderRadius: 4, border: '1px solid #f44336', background: '#ffebee', cursor: 'pointer', fontSize: 12 }}
                      >Remove</button>
                    )}
                  </div>
                </div>
              ))}
            </div>

            <div style={{ display: 'flex', gap: 8 }}>
              <button type="button" onClick={handleAddProductionRow}
                disabled={productionPrograms.length <= 1}
                style={{ padding: '10px 12px', borderRadius: 6, border: '1px solid #ccc', background: '#fff', fontWeight: 600, cursor: productionPrograms.length <= 1 ? 'not-allowed' : 'pointer' }}
              >Add row</button>
              <button type="button"
                onClick={async () => {
                  const setupSuccess = await handleSaveProductionSetup();
                  if (!setupSuccess) return;
                  const createSuccess = await handleCreateProduction();
                  if (createSuccess) {
                    await fetchBatchesFromApi();
                    await fetchUnitsFromApi();
                    setShowProduction(false);
                  }
                }}
                disabled={productionSaving || productionSetupSaving}
                style={{ padding: '10px 16px', borderRadius: 6, border: '1px solid #2196f3', background: '#e3f2fd', fontWeight: 700, cursor: 'pointer' }}
              >
                {productionSaving || productionSetupSaving ? 'Creating…' : 'Create'}
              </button>
            </div>
          </>
        )}
      </div>
    </DraggablePanel>
  );
}
