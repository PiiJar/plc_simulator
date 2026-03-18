import React from 'react';

export default function ToolbarButtons({
  disabled,
  showCustomer, setShowCustomer,
  showConfig, setShowConfig,
  showProduction, setShowProduction,
  showBatches, setShowBatches,
  showTasks, setShowTasks
}) {
  const btnStyle = (active, isDisabled) => ({
    padding: '8px 12px',
    fontSize: '12px',
    fontWeight: 600,
    border: '1px solid #ccc',
    borderRadius: '4px',
    background: active ? '#1976d2' : '#fff',
    color: active ? '#fff' : '#333',
    cursor: isDisabled ? 'not-allowed' : 'pointer',
    opacity: isDisabled ? 0.5 : 1,
    height: 36,
    width: 90,
    whiteSpace: 'nowrap',
    transition: 'all 0.2s',
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 2
  });

  return (
    <div style={{ display: 'flex', gap: '8px' }}>
      <button 
        style={btnStyle(showCustomer, false)} 
        onClick={() => setShowCustomer(!showCustomer)}
      >
        <span style={{ fontSize: 14 }}>🏢</span>
        Plant
      </button>
      
      <button 
        disabled={disabled}
        style={btnStyle(showConfig, disabled)} 
        onClick={() => setShowConfig(!showConfig)}
      >
        <span style={{ fontSize: 14 }}>⚙️</span>
        Layout
      </button>

      <button 
        disabled={disabled}
        style={btnStyle(showProduction, disabled)} 
        onClick={() => setShowProduction(!showProduction)}
      >
        <span style={{ fontSize: 14 }}>📊</span>
        Production
      </button>

      <button 
        disabled={disabled}
        style={btnStyle(showBatches, disabled)} 
        onClick={() => setShowBatches(!showBatches)}
      >
        <span style={{ fontSize: 14 }}>📦</span>
        Units
      </button>

      <button 
        disabled={disabled}
        style={btnStyle(showTasks, disabled)} 
        onClick={() => setShowTasks(!showTasks)}
      >
        <span style={{ fontSize: 14 }}>📋</span>
        Tasks
      </button>
    </div>
  );
}
