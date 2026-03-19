import React from 'react';
import { api } from '../api/client';

/**
 * Toolbar — unified toolbar component for guard and main renders.
 * Replaces ~530 lines of duplicated JSX in App.jsx.
 *
 * @param {boolean} isConfigLoaded — false = guard mode (most buttons disabled)
 */
export default function Toolbar({
  plcStatus, plcToggling, setPlcToggling, setPlcStatus,
  selectedCustomer, selectedPlant, plantStatus,
  showCustomer, showConfig, showCalibration, showProduction, showBatches, showTasks,
  setShowCustomer, setShowCalibration, setShowProduction, setShowBatches, setShowTasks,
  onConfigClick,
  isResetting, productionStartTime, productionDuration,
  handleStart, handleReset,
  isConfigLoaded,
}) {
  const guard = !isConfigLoaded;

  // ─── button style helper ───
  const panelBtn = (icon, label, active, onClick, disabled = false) => (
    <button
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{
        padding: '8px 12px', fontSize: '12px', fontWeight: 600, borderRadius: '4px',
        border: '1px solid #ccc',
        background: disabled ? '#fff' : active ? '#1976d2' : '#fff',
        color: disabled ? '#aaa' : active ? '#fff' : '#333',
        cursor: disabled ? 'default' : 'pointer',
        opacity: disabled ? 0.5 : 1,
        width: 80,
        display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2,
      }}
    >
      <span style={{ fontSize: 18 }}>{icon}</span>
      <span>{label}</span>
    </button>
  );

  return (
    <div style={{
      padding: '12px 24px',
      background: '#fff',
      borderBottom: '1px solid #ddd',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      gap: '16px',
    }}>
      {/* ─── LEFT: logo + PLC + customer ─── */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
        <img src="/Codesys_logo.png" alt="CODESYS" style={{ height: 56, borderRadius: 6, objectFit: 'contain' }} />

        {/* PLC status indicator + toggle */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span
            title={plcStatus.runtime_status === 'running' ? 'PLC Running' : 'PLC Stopped'}
            style={{
              width: 12, height: 12, borderRadius: '50%',
              background: plcStatus.runtime_status === 'running' ? '#4caf50' : '#f44336',
              boxShadow: `0 0 6px ${plcStatus.runtime_status === 'running' ? '#4caf50' : '#f44336'}`,
              flexShrink: 0,
            }}
          />
          {plcStatus.runtime_status === 'running' ? (
            <button
              disabled={plcToggling}
              onClick={async () => {
                setPlcToggling(true);
                try { await api.post('/api/plc/stop'); } catch {}
                setTimeout(async () => {
                  try { const r = await api.get('/api/plc/status'); if (r.ok) setPlcStatus(await r.json()); } catch {}
                  setPlcToggling(false);
                }, 3000);
              }}
              title="Stop PLC"
              style={{
                width: 34, height: 34,
                border: '2px solid #c62828', borderRadius: 6, cursor: 'pointer',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                background: '#ffebee',
                opacity: plcToggling ? 0.5 : 1,
                transition: 'background 0.2s',
              }}
            >
              <svg width="14" height="14" viewBox="0 0 14 14"><rect x="1" y="1" width="12" height="12" rx="1" fill="#c62828" /></svg>
            </button>
          ) : (
            <button
              disabled={plcToggling}
              onClick={async () => {
                setPlcToggling(true);
                try { await api.post('/api/plc/start'); } catch {}
                setTimeout(async () => {
                  try { const r = await api.get('/api/plc/status'); if (r.ok) setPlcStatus(await r.json()); } catch {}
                  setPlcToggling(false);
                }, 2000);
              }}
              title="Start PLC"
              style={{
                width: 34, height: 34,
                border: '2px solid #2e7d32', borderRadius: 6, cursor: 'pointer',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                background: '#e8f5e9',
                opacity: plcToggling ? 0.5 : 1,
                transition: 'background 0.2s',
              }}
            >
              <svg width="14" height="16" viewBox="0 0 14 16"><polygon points="1,0 14,8 1,16" fill="#2e7d32" /></svg>
            </button>
          )}
        </div>

        <div style={{ width: 1, height: 32, background: '#ddd' }} />

        {/* Customer / Plant display */}
        {guard ? (
          /* Guard: simple text */
          selectedCustomer && selectedPlant && (
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <span style={{ fontSize: 14, fontWeight: 600, color: '#333' }}>{selectedCustomer}</span>
              <span style={{ color: '#999', fontSize: 13 }}>/</span>
              <span style={{ fontSize: 13, color: '#666' }}>{selectedPlant}</span>
            </div>
          )
        ) : (
          /* Main: card-style with plant status */
          <div style={{ minWidth: 280, minHeight: 38, display: 'flex', alignItems: 'center' }}>
            {selectedCustomer && selectedPlant && (
              <div style={{
                padding: '6px 14px',
                background: plantStatus?.isConfigured ? '#e8f5e9' : '#fff3e0',
                border: `1px solid ${plantStatus?.isConfigured ? '#a5d6a7' : '#ffcc80'}`,
                borderRadius: 4, lineHeight: 1.4, width: '100%',
              }}>
                <div style={{ fontSize: 13, fontWeight: 700, color: '#333' }}>
                  {selectedCustomer} / {selectedPlant}
                </div>
                {plantStatus?.analysis?.summary && (
                  <div style={{ fontSize: 12, color: '#2e7d32' }}>{plantStatus.analysis.summary}</div>
                )}
              </div>
            )}
          </div>
        )}
      </div>

      {/* ─── CENTER: panel buttons ─── */}
      <div style={{ display: 'flex', gap: 8 }}>
        {panelBtn('👤', 'Customer', showCustomer, () => setShowCustomer(v => !v))}
        {panelBtn('⚙️', 'Config', showConfig, onConfigClick, guard)}
        {panelBtn('🎯', 'Calibrate', showCalibration, () => setShowCalibration(v => !v), guard)}
        {panelBtn('🏭', 'Production', showProduction, () => setShowProduction(v => !v), guard)}
        {panelBtn('📦', 'Units', showBatches, () => setShowBatches(v => !v), guard)}
        {panelBtn('📋', 'Tasks', showTasks, () => setShowTasks(v => !v), guard)}
        {panelBtn('📅', 'Schedule', false, () => window.open('/schedule.html', '_blank'), guard)}
        {panelBtn('📊', 'Dashboard', false, () => window.open('/dashboard.html', '_blank'), guard)}
      </div>

      {/* ─── RIGHT: time + Start/Reset ─── */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
        {/* Production time display — only in main mode */}
        {!guard && (
          <div style={{ width: 220, textAlign: 'right', fontFamily: 'monospace', fontSize: 12, lineHeight: '1.4' }}>
            <div style={{ color: '#333', fontWeight: 600, whiteSpace: 'nowrap' }}>
              {productionStartTime
                ? `Start: ${productionStartTime.toLocaleString('fi-FI', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' })}`
                : '\u00A0'}
            </div>
            <div style={{ color: '#333', fontWeight: 600, whiteSpace: 'nowrap' }}>
              {productionStartTime
                ? (() => {
                    const s = Math.floor(productionDuration / 1000);
                    const h = Math.floor(s / 3600);
                    const m = Math.floor((s % 3600) / 60);
                    const sec = s % 60;
                    return `Elapsed: ${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`;
                  })()
                : '\u00A0'}
            </div>
          </div>
        )}

        <button
          onClick={guard ? undefined : handleStart}
          disabled={guard || !!productionStartTime}
          style={{
            padding: '8px 0', fontSize: '13px', fontWeight: 600,
            border: 'none', borderRadius: '4px',
            background: '#4caf50', color: '#fff',
            width: 100, textAlign: 'center',
            cursor: guard || productionStartTime ? 'default' : 'pointer',
            opacity: guard ? 0.5 : 1,
            transition: 'all 0.2s',
          }}
        >
          {!guard && productionStartTime ? 'RUN' : 'START'}
        </button>

        <button
          onClick={handleReset}
          disabled={!selectedCustomer || !selectedPlant || isResetting}
          style={{
            padding: '8px 0', fontSize: '13px', fontWeight: 600,
            border: 'none', borderRadius: '4px',
            cursor: (!selectedCustomer || !selectedPlant || isResetting) ? 'not-allowed' : 'pointer',
            background: isResetting ? '#b71c1c' : (!selectedCustomer || !selectedPlant) ? '#666' : '#f44336',
            color: '#fff',
            opacity: (!selectedCustomer || !selectedPlant) ? 0.5 : 1,
            width: 100, textAlign: 'center',
            transition: 'all 0.2s',
          }}
        >
          {isResetting ? 'RESETTING…' : 'RESET'}
        </button>
      </div>
    </div>
  );
}
