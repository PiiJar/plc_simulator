import React from 'react';

export default function PlcStatusButton({ status, toggling, onToggle }) {
  const isRunning = status === 'running';
  const isContainerDown = status === 'container_stopped' || status === 'not_found';
  const statusColor = isRunning ? '#4caf50' : isContainerDown ? '#9e9e9e' : '#f44336';
  const statusLabel = isRunning ? 'PLC RUN' : isContainerDown ? 'Container stopped' : 'PLC STOP';
  
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      <span
        title={statusLabel}
        style={{
          width: 12, height: 12, borderRadius: '50%',
          background: statusColor,
          boxShadow: `0 0 6px ${statusColor}`,
          flexShrink: 0
        }}
      />
      <button
        disabled={toggling || isContainerDown}
        onClick={onToggle}
        title={isContainerDown ? 'Container not running' : isRunning ? "PLC → STOP" : "PLC → RUN"}
        style={{
          width: 34, height: 34,
          border: `2px solid ${isRunning ? '#c62828' : '#2e7d32'}`,
          borderRadius: 6, cursor: 'pointer',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          background: isRunning ? '#ffebee' : '#e8f5e9',
          opacity: toggling ? 0.5 : 1,
          transition: 'background 0.2s'
        }}
      >
        {isRunning ? (
          <svg width="14" height="14" viewBox="0 0 14 14">
            <rect x="1" y="1" width="12" height="12" rx="1" fill="#c62828" />
          </svg>
        ) : (
          <svg width="14" height="16" viewBox="0 0 14 16">
            <polygon points="1,0 14,8 1,16" fill="#2e7d32" />
          </svg>
        )}
      </button>
    </div>
  );
}
