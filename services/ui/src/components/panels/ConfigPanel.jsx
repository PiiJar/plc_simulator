import React from 'react';
import DraggablePanel from '../StationLayout/helpers/DraggablePanel';
import { api } from '../../api/client';

export default function ConfigPanel({
  showConfig, setShowConfig,
  configForm, setConfigForm,
  configError, setConfigError,
  configSaving, setConfigSaving,
  config, setConfig
}) {
  if (!showConfig || !configForm) return null;

  return (
    <DraggablePanel title="Layout Configuration" onClose={() => { setShowConfig(false); setConfigError(''); }} width={480}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16, minWidth: 400 }}>
        {configError && (
          <div style={{ color: '#c62828', fontWeight: 600, fontSize: 13 }}>{configError}</div>
        )}

        {/* Direction settings */}
        <fieldset style={{ border: '1px solid #ddd', borderRadius: 6, padding: 12 }}>
          <legend style={{ fontWeight: 600, fontSize: 13, padding: '0 8px' }}>Direction</legend>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
              X Direction
              <select
                value={configForm.xDirection}
                onChange={e => setConfigForm(p => ({ ...p, xDirection: e.target.value }))}
                style={{ padding: 6, borderRadius: 4, border: '1px solid #ccc' }}
              >
                <option value="left-to-right">Left to Right →</option>
                <option value="right-to-left">Right to Left ←</option>
              </select>
            </label>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
              Y Direction
              <select
                value={configForm.yDirection}
                onChange={e => setConfigForm(p => ({ ...p, yDirection: e.target.value }))}
                style={{ padding: 6, borderRadius: 4, border: '1px solid #ccc' }}
              >
                <option value="top-to-bottom">Top to Bottom ↓</option>
                <option value="bottom-to-top">Bottom to Top ↑</option>
              </select>
            </label>
          </div>
        </fieldset>

        {/* Container / Margins */}
        <fieldset style={{ border: '1px solid #ddd', borderRadius: 6, padding: 12 }}>
          <legend style={{ fontWeight: 600, fontSize: 13, padding: '0 8px' }}>Container & Margins</legend>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
              Margin Left
              <input
                type="number"
                value={configForm.margins.left}
                onChange={e => setConfigForm(p => ({ ...p, margins: { ...p.margins, left: Number(e.target.value) } }))}
                style={{ padding: 6, borderRadius: 4, border: '1px solid #ccc' }}
              />
            </label>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
              Margin Top
              <input
                type="number"
                value={configForm.margins.top}
                onChange={e => setConfigForm(p => ({ ...p, margins: { ...p.margins, top: Number(e.target.value) } }))}
                style={{ padding: 6, borderRadius: 4, border: '1px solid #ccc' }}
              />
            </label>
          </div>
        </fieldset>

        {/* Grid settings */}
        <fieldset style={{ border: '1px solid #ddd', borderRadius: 6, padding: 12 }}>
          <legend style={{ fontWeight: 600, fontSize: 13, padding: '0 8px' }}>Grid Resolution</legend>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
              Step X (mm)
              <input
                type="number"
                value={configForm.grid.stepX}
                onChange={e => setConfigForm(p => ({ ...p, grid: { ...p.grid, stepX: Number(e.target.value) } }))}
                style={{ padding: 6, borderRadius: 4, border: '1px solid #ccc' }}
              />
            </label>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
              Step Y (mm)
              <input
                type="number"
                value={configForm.grid.stepY}
                onChange={e => setConfigForm(p => ({ ...p, grid: { ...p.grid, stepY: Number(e.target.value) } }))}
                style={{ padding: 6, borderRadius: 4, border: '1px solid #ccc' }}
              />
            </label>
          </div>
        </fieldset>

        {/* Button row */}
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 12, marginTop: 8 }}>
          <button
            onClick={() => {
              // Initialize form with current config values
              if (config) {
                setConfigForm({
                  xDirection: config.xDirection || 'left-to-right',
                  yDirection: config.yDirection || 'top-to-bottom',
                  margins: config.margins || { top: 120, right: 100, bottom: 50, left: 100 },
                  grid: config.grid || { stepX: 100, stepY: 600 },
                  stations: config.stations || { type: 'horizontal', rowHeight: 600, yOffsets: {} },
                  transporters: config.transporters || { railYOffset: -40, type: 'horizontal', groupHeight: 60 }
                });
              }
            }}
            disabled={configSaving}
            style={{
              padding: '10px 16px',
              borderRadius: 4,
              border: '1px solid #ccc',
              background: '#fff',
              cursor: configSaving ? 'not-allowed' : 'pointer',
              fontWeight: 600,
              fontSize: 13
            }}
          >
            Reset Form
          </button>
          <button
            onClick={() => { setShowConfig(false); setConfigError(''); }}
            disabled={configSaving}
            style={{
              padding: '10px 16px',
              borderRadius: 4,
              border: '1px solid #ccc',
              background: '#fff',
              cursor: configSaving ? 'not-allowed' : 'pointer',
              fontWeight: 600,
              fontSize: 13
            }}
          >
            Cancel
          </button>
          <button
            onClick={async () => {
              setConfigSaving(true);
              setConfigError('');
              try {
                // Build full layout config object
                const fullConfig = {
                  layout: {
                    xDirection: configForm.xDirection,
                    yDirection: configForm.yDirection,
                    margins: configForm.margins,
                    grid: configForm.grid,
                    stations: configForm.stations,
                    transporters: configForm.transporters,
                    'cross-transporters': config?.['cross-transporters'] || {},
                    colors: config?.colors || {}
                  }
                };
                
                // Save to backend (file and runtime)
                await api.put('/api/config/layout_config.json', fullConfig);
                
                // Update runtime config
                setConfig(fullConfig.layout);
                setShowConfig(false);
              } catch (err) {
                setConfigError(err.message || 'Failed to save');
              } finally {
                setConfigSaving(false);
              }
            }}
            disabled={configSaving}
            style={{
              padding: '10px 20px',
              borderRadius: 4,
              border: 'none',
              background: configSaving ? '#90caf9' : '#1976d2',
              color: '#fff',
              cursor: configSaving ? 'not-allowed' : 'pointer',
              fontWeight: 600,
              fontSize: 13
            }}
          >
            {configSaving ? 'Saving...' : 'Save'}
          </button>
        </div>
      </div>
    </DraggablePanel>
  );
}
