import React from 'react';
import { DraggablePanel } from '../index';
import { api } from '../../api/client';

/**
 * ConfigPanel — Layout configuration form (grid, stations, transporters, margins).
 * Extracted from App.jsx V3e.
 */
export default function ConfigPanel({
  onClose,
  configForm, setConfigForm,
  configError, setConfigError,
  configSaving, setConfigSaving,
  config, setConfig,
  setShowConfig,
}) {
  return (
    <DraggablePanel title="Layout Configuration" onClose={onClose} width={480}>
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
                onChange={(e) => setConfigForm(f => ({ ...f, xDirection: e.target.value }))}
                style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc' }}
              >
                <option value="left-to-right">Left to Right</option>
                <option value="right-to-left">Right to Left</option>
              </select>
            </label>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
              Y Direction
              <select
                value={configForm.yDirection}
                onChange={(e) => setConfigForm(f => ({ ...f, yDirection: e.target.value }))}
                style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc' }}
              >
                <option value="top-to-bottom">Top to Bottom</option>
                <option value="bottom-to-top">Bottom to Top</option>
              </select>
            </label>
          </div>
        </fieldset>

        {/* Grid settings */}
        <fieldset style={{ border: '1px solid #ddd', borderRadius: 6, padding: 12 }}>
          <legend style={{ fontWeight: 600, fontSize: 13, padding: '0 8px' }}>Grid</legend>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 12, alignItems: 'end' }}>
            <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
              <input
                type="checkbox"
                checked={configForm.grid?.show || false}
                onChange={(e) => setConfigForm(f => ({ ...f, grid: { ...f.grid, show: e.target.checked } }))}
              />
              Show Grid
            </label>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
              Spacing
              <input
                type="number"
                value={configForm.grid?.spacing || 100}
                onChange={(e) => setConfigForm(f => ({ ...f, grid: { ...f.grid, spacing: Number(e.target.value) } }))}
                style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #ccc', width: 80 }}
              />
            </label>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
              Color
              <input
                type="color"
                value={configForm.grid?.color || '#e0e0e0'}
                onChange={(e) => setConfigForm(f => ({ ...f, grid: { ...f.grid, color: e.target.value } }))}
                style={{ padding: 2, borderRadius: 4, border: '1px solid #ccc', width: 60, height: 32 }}
              />
            </label>
          </div>
        </fieldset>

        {/* Station settings */}
        <fieldset style={{ border: '1px solid #ddd', borderRadius: 6, padding: 12 }}>
          <legend style={{ fontWeight: 600, fontSize: 13, padding: '0 8px' }}>Stations</legend>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            <div style={{ display: 'flex', gap: 16 }}>
              <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                <input
                  type="checkbox"
                  checked={configForm.stations?.showShadow !== false}
                  onChange={(e) => setConfigForm(f => ({ ...f, stations: { ...f.stations, showShadow: e.target.checked } }))}
                />
                Shadow
              </label>
              <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                <input
                  type="checkbox"
                  checked={configForm.stations?.showLabels !== false}
                  onChange={(e) => setConfigForm(f => ({ ...f, stations: { ...f.stations, showLabels: e.target.checked } }))}
                />
                Labels
              </label>
              <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                <input
                  type="checkbox"
                  checked={configForm.stations?.showAvoidCheckboxes !== false}
                  onChange={(e) => setConfigForm(f => ({ ...f, stations: { ...f.stations, showAvoidCheckboxes: e.target.checked } }))}
                />
                Avoid Checkboxes
              </label>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                Width (mm)
                <input
                  type="number"
                  value={configForm.stations?.widthMM || 500}
                  onChange={(e) => setConfigForm(f => ({ ...f, stations: { ...f.stations, widthMM: Number(e.target.value) } }))}
                  style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #ccc' }}
                />
              </label>
              <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                Height (mm)
                <input
                  type="number"
                  value={configForm.stations?.heightMM || 1200}
                  onChange={(e) => setConfigForm(f => ({ ...f, stations: { ...f.stations, heightMM: Number(e.target.value) } }))}
                  style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #ccc' }}
                />
              </label>
            </div>
          </div>
        </fieldset>

        {/* Transporter settings */}
        <fieldset style={{ border: '1px solid #ddd', borderRadius: 6, padding: 12 }}>
          <legend style={{ fontWeight: 600, fontSize: 13, padding: '0 8px' }}>Transporters</legend>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            <div style={{ display: 'flex', gap: 16 }}>
              <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                <input
                  type="checkbox"
                  checked={configForm.transporters?.showUtilizationPie !== false}
                  onChange={(e) => setConfigForm(f => ({ ...f, transporters: { ...f.transporters, showUtilizationPie: e.target.checked } }))}
                />
                Utilization Pie
              </label>
              <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                <input
                  type="checkbox"
                  checked={configForm.transporters?.showDriveLimits !== false}
                  onChange={(e) => setConfigForm(f => ({ ...f, transporters: { ...f.transporters, showDriveLimits: e.target.checked } }))}
                />
                Drive Limits
              </label>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                Height (mm)
                <input
                  type="number"
                  value={configForm.transporters?.heightMM || 1400}
                  onChange={(e) => setConfigForm(f => ({ ...f, transporters: { ...f.transporters, heightMM: Number(e.target.value) } }))}
                  style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #ccc' }}
                />
              </label>
              <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                Width Scale
                <input
                  type="number"
                  step="0.1"
                  min="0.1"
                  max="2"
                  value={configForm.transporters?.widthScaleFactor || 0.8}
                  onChange={(e) => setConfigForm(f => ({ ...f, transporters: { ...f.transporters, widthScaleFactor: Number(e.target.value) } }))}
                  style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #ccc' }}
                />
              </label>
            </div>
          </div>
        </fieldset>

        {/* Margins - Single Line */}
        <fieldset style={{ border: '1px solid #ddd', borderRadius: 6, padding: 12 }}>
          <legend style={{ fontWeight: 600, fontSize: 13, padding: '0 8px' }}>Margins (Single Line)</legend>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 8 }}>
            {['top', 'right', 'bottom', 'left'].map(side => (
              <label key={side} style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 12 }}>
                {side.charAt(0).toUpperCase() + side.slice(1)}
                <input
                  type="number"
                  value={configForm.margins?.singleLine?.[side] || 60}
                  onChange={(e) => setConfigForm(f => ({
                    ...f,
                    margins: {
                      ...f.margins,
                      singleLine: { ...f.margins?.singleLine, [side]: Number(e.target.value) }
                    }
                  }))}
                  style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #ccc' }}
                />
              </label>
            ))}
          </div>
        </fieldset>

        {/* Margins - Multi Line */}
        <fieldset style={{ border: '1px solid #ddd', borderRadius: 6, padding: 12 }}>
          <legend style={{ fontWeight: 600, fontSize: 13, padding: '0 8px' }}>Margins (Multi Line)</legend>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 8 }}>
            {['top', 'right', 'bottom', 'left'].map(side => (
              <label key={side} style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 12 }}>
                {side.charAt(0).toUpperCase() + side.slice(1)}
                <input
                  type="number"
                  value={configForm.margins?.multiLine?.[side] || 40}
                  onChange={(e) => setConfigForm(f => ({
                    ...f,
                    margins: {
                      ...f.margins,
                      multiLine: { ...f.margins?.multiLine, [side]: Number(e.target.value) }
                    }
                  }))}
                  style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #ccc' }}
                />
              </label>
            ))}
          </div>
        </fieldset>

        {/* Action buttons */}
        <div style={{ display: 'flex', gap: 12, justifyContent: 'flex-end', marginTop: 8 }}>
          <button
            onClick={() => { setShowConfig(false); setConfigError(''); }}
            style={{
              padding: '10px 20px',
              borderRadius: 4,
              border: '1px solid #ccc',
              background: '#f5f5f5',
              cursor: 'pointer',
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
                const fullConfig = {
                  layout: {
                    xDirection: configForm.xDirection,
                    yDirection: configForm.yDirection,
                    margins: configForm.margins,
                    grid: configForm.grid,
                    stations: configForm.stations,
                    transporters: configForm.transporters,
                    'cross-transporters': config['cross-transporters'] || {},
                    colors: config.colors || {}
                  }
                };

                const res = await api.put('/api/config/layout_config.json', fullConfig);

                if (!res.ok) {
                  throw new Error('Failed to save configuration');
                }

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
