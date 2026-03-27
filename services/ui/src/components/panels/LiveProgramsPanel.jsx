import React, { useState, useEffect } from 'react';
import { DraggablePanel } from '../index';

export default function LiveProgramsPanel({ onClose }) {
  const [programs, setPrograms] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  const fetchLivePrograms = async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch('/api/live-programs');
      if (!res.ok) throw new Error(`Failed to fetch: ${res.statusText}`);
      const data = await res.json();
      setPrograms(data);
    } catch (err) {
      console.error(err);
      setError('Failed to fetch data: ' + err.message);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchLivePrograms();
    // Vapaaehtoinen automaattinen päivitys (esim. painamalla nappia toistaiseksi helpompi)
    const interval = setInterval(fetchLivePrograms, 5000);
    return () => clearInterval(interval);
  }, []);

  return (
    <DraggablePanel title="Live Programs (IN_PROCESS)" onClose={onClose} width={500}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12, maxHeight: '80vh', overflowY: 'auto' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <button onClick={fetchLivePrograms} disabled={loading} style={{ padding: '4px 12px' }}>
            {loading ? 'Refreshing...' : 'Refresh now'}
          </button>
        </div>

        {error && <div style={{ color: '#c62828', fontWeight: 600 }}>{error}</div>}

        {programs.length === 0 && !loading && !error && (
          <div style={{ fontStyle: 'italic', color: '#666' }}>No active (IN_PROCESS) programs on the line.</div>
        )}

        {programs.map(prog => (
          <div key={prog.unit_id} style={{ border: '1px solid #ccc', borderRadius: 4, padding: 8, background: '#f9f9f9' }}>
            <h4 style={{ margin: '0 0 8px 0' }}>Unit {prog.unit_id} (ProgId: {prog.program_id})</h4>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13, background: '#fff' }}>
              <thead>
                <tr style={{ background: '#eee', borderBottom: '1px solid #ccc' }}>
                  <th style={{ padding: 4, textAlign: 'left', borderRight: '1px solid #eee' }}>Stage</th>
                  <th style={{ padding: 4, textAlign: 'left', borderRight: '1px solid #eee' }}>Station</th>
                  <th style={{ padding: 4, textAlign: 'right', borderRight: '1px solid #eee' }}>MinTime (s)</th>
                  <th style={{ padding: 4, textAlign: 'right' }}>CalTime (s)</th>
                </tr>
              </thead>
              <tbody>
                {prog.steps.map(step => {
                  const isDelayed = step.cal_time > step.min_time;
                  return (
                    <tr key={step.stage} style={{ 
                      borderBottom: '1px solid #eee', 
                      backgroundColor: isDelayed ? '#fff3cd' : 'transparent', // Keltainen korostus
                      color: isDelayed ? '#d32f2f' : 'inherit',
                      fontWeight: isDelayed ? 'bold' : 'normal'
                    }}>
                      <td style={{ padding: 4, borderRight: '1px solid #eee' }}>{step.stage}</td>
                      <td style={{ padding: 4, borderRight: '1px solid #eee' }}>{step.station_name}</td>
                      <td style={{ padding: 4, textAlign: 'right', borderRight: '1px solid #eee' }}>{step.min_time}</td>
                      <td style={{ padding: 4, textAlign: 'right' }}>{step.cal_time}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        ))}
      </div>
    </DraggablePanel>
  );
}
