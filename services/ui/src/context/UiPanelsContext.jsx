import React, { createContext, useContext, useState } from 'react';

const UiPanelsContext = createContext(null);

export function UiPanelsProvider({ children }) {
  const [showBatches, setShowBatches] = useState(false);
  const [showTasks, setShowTasks] = useState(false);
  const [showProduction, setShowProduction] = useState(false);
  const [showCustomer, setShowCustomer] = useState(false);
  const [showConfig, setShowConfig] = useState(false);
  const [showCalibration, setShowCalibration] = useState(false);
  const [debugTransporterId, setDebugTransporterId] = useState(null);

  const value = {
    showBatches, setShowBatches,
    showTasks, setShowTasks,
    showProduction, setShowProduction,
    showCustomer, setShowCustomer,
    showConfig, setShowConfig,
    showCalibration, setShowCalibration,
    debugTransporterId, setDebugTransporterId
  };

  return <UiPanelsContext.Provider value={value}>{children}</UiPanelsContext.Provider>;
}

export const useUiPanels = () => useContext(UiPanelsContext);
