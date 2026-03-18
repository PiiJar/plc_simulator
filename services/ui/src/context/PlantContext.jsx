import React, { createContext, useContext, useState } from 'react';

const PlantContext = createContext(null);

export function PlantProvider({ children }) {
  const [config, setConfig] = useState(null);
  const [configurationsLoading, setConfigurationsLoading] = useState(true);
  const [stations, setStations] = useState([]);
  const [tanks, setTanks] = useState([]);
  const [transporters, setTransporters] = useState([]);
  const [batches, setBatches] = useState([]);
  const [units, setUnits] = useState([]);

  const [customers, setCustomers] = useState([]);
  const [selectedCustomer, setSelectedCustomer] = useState('');
  const [selectedPlant, setSelectedPlant] = useState('');
  const [customerPlants, setCustomerPlants] = useState([]);
  const [plantStatus, setPlantStatus] = useState(null);

  const value = {
    config, setConfig,
    configurationsLoading, setConfigurationsLoading,
    stations, setStations,
    tanks, setTanks,
    transporters, setTransporters,
    batches, setBatches,
    units, setUnits,
    customers, setCustomers,
    selectedCustomer, setSelectedCustomer,
    selectedPlant, setSelectedPlant,
    customerPlants, setCustomerPlants,
    plantStatus, setPlantStatus,
  };

  return <PlantContext.Provider value={value}>{children}</PlantContext.Provider>;
}

export const usePlant = () => useContext(PlantContext);
