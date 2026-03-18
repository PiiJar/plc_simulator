import React, { useState, useEffect, useCallback } from 'react';
import DraggablePanel from './StationLayout/helpers/DraggablePanel';

/**
 * CalibrationPanel — Teaching mode for measuring transporter kinematics
 * 
 * Workflow:
 *   1. User selects test stations per transporter
 *   2. "Start" sends plan + starts calibration
 *   3. PLC runs test moves, panel polls status
 *   4. Results displayed when measurements complete
 *   5. "Calculate" fills g_move in PLC
 *   6. "Save" writes movement_times.json to customer folder
 */

const STEP_LABELS = {
  0: 'Idle',
  10: 'Task 1 (dry→wet): issuing',
  11: 'Task 1 (dry→wet): waiting acceptance',
  12: 'Task 1 (dry→wet): running + X velocity measurement',
  20: 'Task 2 (wet→dry): issuing',
  21: 'Task 2 (wet→dry): waiting acceptance',
  22: 'Task 2 (wet→dry): running',
  30: 'Reading results from measurements',
  40: 'Advancing to next transporter',
  100: 'Measurement complete',
  200: 'Calculating movement times',
  999: 'Complete'
};

function getStepLabel(step) {
  return STEP_LABELS[step] || `Step ${step}`;
}

function getStepColor(step) {
  if (step === 0) return '#888';
  if (step >= 10 && step < 100) return '#f57c00';
  if (step === 100) return '#1976d2';
  if (step === 200) return '#7b1fa2';
  if (step === 999) return '#2e7d32';
  return '#333';
}

// Wet station = kind 1. Everything else = dry.
const isWetStation = (s) => (Number(s.kind) || 0) === 1;

export default function CalibrationPanel({ onClose, stations, transporterStates }) {
  const activeTransporters = (transporterStates || []).filter(t => t?.state?.status >= 3);
  
  // Form state: plan per transporter
  const [plans, setPlans] = useState({});
  const [calStatus, setCalStatus] = useState({ step: 0, tid: 0, results: [] });
  const [polling, setPolling] = useState(false);
  const [saving, setSaving] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [existingFile, setExistingFile] = useState(null);

  // Filter stations reachable by a given transporter (within x drive limits)
  const stationsForTransporter = (t) => {
    const xMin = t?.state?.x_min_drive_limit || 0;
    const xMax = t?.state?.x_max_drive_limit || 0;
    if (xMin === 0 && xMax === 0) return stations || [];
    return (stations || []).filter(s => s.x_position >= xMin && s.x_position <= xMax);
  };

  // Stable key that changes when transporters' drive limits change
  const transporterLimitsKey = activeTransporters.map(t => {
    const s = t?.state;
    return `${t.id}:${s?.x_min_drive_limit||0}-${s?.x_max_drive_limit||0}`;
  }).join('|');

  // Initialize default plans for active transporters
  useEffect(() => {
    if (!stations?.length || !activeTransporters.length) return;
    const defaults = {};
    activeTransporters.forEach(t => {
      const reachable = stationsForTransporter(t);
      const wet = reachable.filter(isWetStation);
      const dry = reachable.filter(s => !isWetStation(s));
      defaults[t.id] = {
        wet_station: wet[0]?.number || 0,
        dry_station: dry[0]?.number || 0
      };
    });
    if (Object.keys(defaults).length > 0) {
      setPlans(defaults);
    }
  }, [transporterLimitsKey, stations]);

  // Check for existing calibration file
  useEffect(() => {
    fetch('/api/calibrate/file')
      .then(r => r.ok ? r.json() : null)
      .then(data => setExistingFile(data))
      .catch(() => setExistingFile(null));
  }, []);

  // Poll calibration status
  const pollStatus = useCallback(async () => {
    try {
      const res = await fetch('/api/calibrate/status');
      if (res.ok) {
        const data = await res.json();
        setCalStatus(data);
        return data;
      }
    } catch (err) {
      console.error('CAL poll error:', err);
    }
    return null;
  }, []);

  useEffect(() => {
    pollStatus();
    let timer;
    if (polling) {
      timer = setInterval(pollStatus, 500);
    }
    return () => clearInterval(timer);
  }, [polling, pollStatus]);

  // Auto-start polling when calibration is active
  useEffect(() => {
    if (calStatus.step > 0 && calStatus.step < 999 && !polling) {
      setPolling(true);
    }
    if (calStatus.step === 0 || calStatus.step === 999) {
      setPolling(false);
    }
  }, [calStatus.step]);

  const updatePlan = (tid, field, value) => {
    setPlans(prev => ({
      ...prev,
      [tid]: { ...prev[tid], [field]: parseInt(value) || 0 }
    }));
  };

  const handleStart = async () => {
    setError('');
    try {
      // Send plans
      const planArray = Object.entries(plans).map(([id, plan]) => ({
        id: parseInt(id),
        ...plan
      }));
      const planRes = await fetch('/api/calibrate/plan', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ transporters: planArray })
      });
      if (!planRes.ok) {
        const err = await planRes.json();
        throw new Error(err.error || 'Failed to send plan');
      }

      // Start calibration
      const startRes = await fetch('/api/calibrate/start', { method: 'POST' });
      if (!startRes.ok) {
        const err = await startRes.json();
        throw new Error(err.error || 'Failed to start');
      }

      setPolling(true);
    } catch (err) {
      setError(err.message);
    }
  };

  const handleCalculate = async () => {
    setError('');
    try {
      const res = await fetch('/api/calibrate/calculate', { method: 'POST' });
      if (!res.ok) {
        const err = await res.json();
        throw new Error(err.error || 'Failed to calculate');
      }
      setPolling(true);
    } catch (err) {
      setError(err.message);
    }
  };

  const handleSave = async () => {
    setError('');
    setSaving(true);
    try {
      const res = await fetch('/api/calibrate/save', { method: 'POST' });
      if (!res.ok) {
        const err = await res.json();
        throw new Error(err.error || 'Failed to save');
      }
      const data = await res.json();
      // Success — no popup needed, status already visible in panel
    } catch (err) {
      setError(err.message);
    } finally {
      setSaving(false);
    }
  };

  const handleAbort = async () => {
    setError('');
    try {
      await fetch('/api/calibrate/abort', { method: 'POST' });
      setPolling(false);
      await pollStatus();
    } catch (err) {
      setError(err.message);
    }
  };

  const handleLoadExisting = async () => {
    if (!existingFile) return;
    setError('');
    setSuccess('');
    setLoading(true);
    try {
      const res = await fetch('/api/calibrate/load', { method: 'POST' });
      if (!res.ok) {
        const err = await res.json();
        throw new Error(err.error || 'Failed to load calibration');
      }
      const data = await res.json();
      setSuccess(`Calibration loaded for ${data.transporters} transporter(s)`);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const isRunning = calStatus.step > 0 && calStatus.step < 100;
  const isMeasureDone = calStatus.step === 100;
  const isComplete = calStatus.step === 999;
  const isIdle = calStatus.step === 0;

  const selectStyle = {
    padding: '4px 6px',
    fontSize: '12px',
    borderRadius: '3px',
    border: '1px solid #ccc',
    width: '100%'
  };

  const btnStyle = (color = '#1976d2') => ({
    padding: '8px 16px',
    fontSize: '13px',
    fontWeight: 600,
    borderRadius: '4px',
    border: 'none',
    background: color,
    color: '#fff',
    cursor: 'pointer'
  });

  return (
    <DraggablePanel title="Calibration — Teaching Mode" onClose={onClose} width={560}>
      <div style={{ padding: '12px 16px', fontSize: '13px' }}>

        {/* Status bar */}
        <div style={{
          padding: '8px 12px',
          marginBottom: 12,
          borderRadius: '4px',
          background: '#f5f5f5',
          border: '1px solid #e0e0e0',
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center'
        }}>
          <div>
            <strong>Status:</strong>{' '}
            <span style={{ color: getStepColor(calStatus.step), fontWeight: 600 }}>
              {getStepLabel(calStatus.step)}
            </span>
          </div>
          {calStatus.tid > 0 && (
            <div style={{ color: '#666' }}>
              Transporter: <strong>T{calStatus.tid}</strong>
            </div>
          )}
        </div>

        {error && (
          <div style={{ color: '#d32f2f', marginBottom: 8, fontSize: '12px' }}>
            Error: {error}
          </div>
        )}
        {success && (
          <div style={{ color: '#2e7d32', marginBottom: 8, fontSize: '12px' }}>
            {success}
          </div>
        )}

        {/* Per-transporter plan */}
        {activeTransporters.map(t => {
          const plan = plans[t.id] || {};
          const result = (calStatus.results || []).find(r => r.id === t.id) || {};
          const hasResults = result.x_max > 0;

          return (
            <div key={t.id} style={{
              marginBottom: 12,
              padding: '10px 12px',
              border: '1px solid #ddd',
              borderRadius: '6px',
              background: '#fafafa'
            }}>
              <div style={{ fontWeight: 700, marginBottom: 8, color: '#333' }}>
                Transporter {t.id}
              </div>

              {/* Plan inputs */}
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '6px 12px', marginBottom: 8 }}>
                <label style={{ fontSize: '11px', color: '#666' }}>
                  Wet station
                  <select style={selectStyle} value={plan.wet_station || ''}
                    disabled={!isIdle} onChange={e => updatePlan(t.id, 'wet_station', e.target.value)}>
                    <option value="">--</option>
                    {stationsForTransporter(t).filter(isWetStation).map(s => <option key={s.number} value={s.number}>{s.number}</option>)}
                  </select>
                </label>
                <label style={{ fontSize: '11px', color: '#666' }}>
                  Dry station
                  <select style={selectStyle} value={plan.dry_station || ''}
                    disabled={!isIdle} onChange={e => updatePlan(t.id, 'dry_station', e.target.value)}>
                    <option value="">--</option>
                    {stationsForTransporter(t).filter(s => !isWetStation(s)).map(s => <option key={s.number} value={s.number}>{s.number}</option>)}
                  </select>
                </label>
              </div>

              {/* Results */}
              {hasResults && (
                <div style={{
                  fontSize: '11px',
                  background: '#e8f5e9',
                  padding: '6px 8px',
                  borderRadius: '4px',
                  display: 'grid',
                  gridTemplateColumns: '1fr 1fr 1fr',
                  gap: '2px 12px'
                }}>
                  <span>Lift wet: <b>{result.lift_wet?.toFixed(2)}s</b></span>
                  <span>Sink wet: <b>{result.sink_wet?.toFixed(2)}s</b></span>
                  <span>v_max: <b>{result.x_max} mm/s</b></span>
                  <span>Lift dry: <b>{result.lift_dry?.toFixed(2)}s</b></span>
                  <span>Sink dry: <b>{result.sink_dry?.toFixed(2)}s</b></span>
                  <span>t_acc: <b>{result.x_acc?.toFixed(2)}s</b></span>
                  <span></span>
                  <span></span>
                  <span>t_dec: <b>{result.x_dec?.toFixed(2)}s</b></span>
                </div>
              )}
            </div>
          );
        })}

        {/* Action buttons */}
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 8 }}>
          {isIdle && (
            <button style={btnStyle('#f57c00')} onClick={handleStart}>
              Start Calibration
            </button>
          )}
          {isRunning && (
            <button style={btnStyle('#d32f2f')} onClick={handleAbort}>
              Abort
            </button>
          )}
          {isMeasureDone && (
            <button style={btnStyle('#1976d2')} onClick={handleCalculate}>
              Calculate Movement Times
            </button>
          )}
          {isComplete && (
            <>
              <button style={btnStyle('#2e7d32')} onClick={handleSave} disabled={saving}>
                {saving ? 'Saving...' : 'Save to Customer'}
              </button>
              <button style={btnStyle('#888')} onClick={handleAbort}>
                Reset
              </button>
            </>
          )}
          {existingFile && (
            <button style={{ ...btnStyle('#1565c0'), marginLeft: 'auto' }} onClick={handleLoadExisting} disabled={loading}>
              {loading ? 'Loading...' : 'Load Existing'}
            </button>
          )}
        </div>

      </div>
    </DraggablePanel>
  );
}
