import React from 'react';
import { formatTime } from '../../utils/formatTime';

export default function SimControls({
  disabled,
  elapsedMs,
  speed,
  onSpeedChange,
  productionStartTime,
  isResetting,
  onStart,
  onReset,
  selectedCustomer,
  selectedPlant
}) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
      <div style={{ 
        fontFamily: 'monospace', 
        fontSize: '18px', 
        background: '#e0e0e0', 
        padding: '4px 12px', 
        borderRadius: '4px',
        marginRight: 8,
        opacity: disabled ? 0.5 : 1
      }}>
        {formatTime(elapsedMs)}
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
        <button
          disabled={disabled}
          onClick={() => onSpeedChange(1)}
          style={{
            padding: '2px 8px', fontSize: 11, fontWeight: 600,
            background: speed === 1 ? '#1976d2' : '#e0e0e0',
            color: speed === 1 ? '#fff' : '#333',
            border: 'none', borderRadius: 4, cursor: disabled ? 'not-allowed' : 'pointer',
            opacity: disabled ? 0.5 : 1
          }}
        >1×</button>
        <button
          disabled={disabled}
          onClick={() => onSpeedChange(2)}
          style={{
            padding: '2px 8px', fontSize: 11, fontWeight: 600,
            background: speed === 2 ? '#1976d2' : '#e0e0e0',
            color: speed === 2 ? '#fff' : '#333',
            border: 'none', borderRadius: 4, cursor: disabled ? 'not-allowed' : 'pointer',
            opacity: disabled ? 0.5 : 1
          }}
        >2×</button>
        <button
          disabled={disabled}
          onClick={() => onSpeedChange(4)}
          style={{
            padding: '2px 8px', fontSize: 11, fontWeight: 600,
            background: speed === 4 ? '#1976d2' : '#e0e0e0',
            color: speed === 4 ? '#fff' : '#333',
            border: 'none', borderRadius: 4, cursor: disabled ? 'not-allowed' : 'pointer',
            opacity: disabled ? 0.5 : 1
          }}
        >4×</button>
        <button
          disabled={disabled}
          onClick={() => onSpeedChange(8)}
          style={{
            padding: '2px 8px', fontSize: 11, fontWeight: 600,
            background: speed === 8 ? '#1976d2' : '#e0e0e0',
            color: speed === 8 ? '#fff' : '#333',
            border: 'none', borderRadius: 4, cursor: disabled ? 'not-allowed' : 'pointer',
            opacity: disabled ? 0.5 : 1
          }}
        >8×</button>
      </div>

      <button
        onClick={onStart}
        disabled={!selectedCustomer || !selectedPlant || productionStartTime}
        style={{
          padding: '8px 0',
          fontSize: '13px',
          fontWeight: 600,
          border: 'none',
          borderRadius: '4px',
          cursor: (!selectedCustomer || !selectedPlant || productionStartTime) ? 'not-allowed' : 'pointer',
          background: productionStartTime ? '#4caf50' : '#1976d2',
          color: '#fff',
          opacity: (!selectedCustomer || !selectedPlant) ? 0.5 : 1,
          width: 80,
          textAlign: 'center',
          transition: 'all 0.2s'
        }}
      >
        {productionStartTime ? 'RUN' : 'START'}
      </button>

      <button
        onClick={onReset}
        disabled={!selectedCustomer || !selectedPlant || isResetting}
        style={{
          padding: '8px 0',
          fontSize: '13px',
          fontWeight: 600,
          border: 'none',
          borderRadius: '4px',
          cursor: (!selectedCustomer || !selectedPlant || isResetting) ? 'not-allowed' : 'pointer',
          background: isResetting ? '#b71c1c' : (!selectedCustomer || !selectedPlant) ? '#666' : '#f44336',
          color: '#fff',
          opacity: (!selectedCustomer || !selectedPlant) ? 0.5 : 1,
          width: 100,
          textAlign: 'center',
          transition: 'all 0.2s'
        }}
      >
        {isResetting ? 'RESETTING…' : 'RESET'}
      </button>
    </div>
  );
}
