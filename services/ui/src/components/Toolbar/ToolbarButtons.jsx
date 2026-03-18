import React from 'react';

export default function ToolbarButtons({
  disabled,
  showCustomer, setShowCustomer,
  showConfig, setShowConfig,
  showProduction, setShowProduction,
  showBatches, setShowBatches,
  showTasks, setShowTasks
}) {
  

  return (
    <div style={{ display: 'flex', gap: '8px' }}>
      <button 
        className={`toolbar-btn ${showCustomer ? 'toolbar-btn--active' : ''}`} 
        onClick={() => setShowCustomer(!showCustomer)}
      >
        <span style={{ fontSize: 14 }}>🏢</span>
        Plant
      </button>
      
      <button 
        disabled={disabled}
        className={`toolbar-btn ${showConfig ? 'toolbar-btn--active' : ''}`} 
        onClick={() => setShowConfig(!showConfig)}
      >
        <span style={{ fontSize: 14 }}>⚙️</span>
        Layout
      </button>

      <button 
        disabled={disabled}
        className={`toolbar-btn ${showProduction ? 'toolbar-btn--active' : ''}`} 
        onClick={() => setShowProduction(!showProduction)}
      >
        <span style={{ fontSize: 14 }}>📊</span>
        Production
      </button>

      <button 
        disabled={disabled}
        className={`toolbar-btn ${showBatches ? 'toolbar-btn--active' : ''}`} 
        onClick={() => setShowBatches(!showBatches)}
      >
        <span style={{ fontSize: 14 }}>📦</span>
        Units
      </button>

      <button 
        disabled={disabled}
        className={`toolbar-btn ${showTasks ? 'toolbar-btn--active' : ''}`} 
        onClick={() => setShowTasks(!showTasks)}
      >
        <span style={{ fontSize: 14 }}>📋</span>
        Tasks
      </button>
    </div>
  );
}
