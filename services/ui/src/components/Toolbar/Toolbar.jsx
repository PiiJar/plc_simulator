import React from 'react';
import PlcStatusButton from './PlcStatusButton';
import PlantBadge from './PlantBadge';
import ToolbarButtons from './ToolbarButtons';
import SimControls from './SimControls';

export default function Toolbar({
  config,
  plcStatus,
  plcToggling,
  onTogglePlc,
  selectedCustomer,
  selectedPlant,
  plantStatus,
  showCustomer,
  setShowCustomer,
  showConfig,
  setShowConfig,
  showProduction,
  setShowProduction,
  showBatches,
  setShowBatches,
  showTasks,
  setShowTasks,
  elapsedMs,
  speed,
  onSpeedChange,
  productionStartTime,
  isResetting,
  onStart,
  onReset
}) {
  return (
    <div style={{ 
      padding: '12px 24px', 
      background: '#fff', 
      borderBottom: '1px solid #ddd',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      gap: '16px'
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
        <img src="/Codesys_logo.png" alt="CODESYS" style={{ height: 36, borderRadius: 6, objectFit: 'contain' }} />
        
        <PlcStatusButton 
          status={plcStatus?.runtime_status} 
          toggling={plcToggling} 
          onToggle={onTogglePlc} 
        />
        
        <PlantBadge 
          customer={selectedCustomer} 
          plant={selectedPlant} 
          status={plantStatus} 
        />
      </div>

      <ToolbarButtons 
        disabled={!config}
        showCustomer={showCustomer} setShowCustomer={setShowCustomer}
        showConfig={showConfig} setShowConfig={setShowConfig}
        showProduction={showProduction} setShowProduction={setShowProduction}
        showBatches={showBatches} setShowBatches={setShowBatches}
        showTasks={showTasks} setShowTasks={setShowTasks}
      />

      <SimControls 
        disabled={!config}
        elapsedMs={elapsedMs}
        speed={speed}
        onSpeedChange={onSpeedChange}
        productionStartTime={productionStartTime}
        isResetting={isResetting}
        onStart={onStart}
        onReset={onReset}
        selectedCustomer={selectedCustomer}
        selectedPlant={selectedPlant}
      />
    </div>
  );
}
