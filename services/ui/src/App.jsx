
import React, { useEffect, useState, useRef, useMemo } from "react";
import * as d3 from "d3";

// Import modular StationLayout component
import StationLayout from './components/StationLayout';
import DraggablePanel from './components/StationLayout/helpers/DraggablePanel';
import CalibrationPanel from './components/CalibrationPanel';

// Load color palette at startup (runtime, no rebuild needed)
import { loadPalette } from './hooks/useColorPalette';

import { api, request } from './api/client';

// MiniPieChart moved to ./components/StationLayout/helpers/MiniPieChart.jsx
// DraggablePanel moved to ./components/StationLayout/helpers/DraggablePanel.jsx
// StationLayout moved to ./components/StationLayout/index.jsx

// Preload palette on module load
loadPalette();

export default function App() {
  const [config, setConfig] = useState(null);
  const [loadError, setLoadError] = useState(null);
  const [isRunning, setIsRunning] = useState(false);
  const [isResetting, setIsResetting] = useState(false);
  const [elapsedMs, setElapsedMs] = useState(0);
  const [speed, setSpeed] = useState(1);
  const [avgCycleSec, setAvgCycleSec] = useState(0); // Keskimääräinen linjaanlähtöväli
  const [productionStats, setProductionStats] = useState({ queueLength: 0, inProgressCount: 0, completedCount: 0, totalBatches: 0 });
  const [showBatches, setShowBatches] = useState(false);
  const [showTasks, setShowTasks] = useState(false);
  const [showProduction, setShowProduction] = useState(false);
  const [productionPrograms, setProductionPrograms] = useState([]);
  const [productionProgramDetails, setProductionProgramDetails] = useState([]);
  const [productionRows, setProductionRows] = useState([]);
  const [productionSaving, setProductionSaving] = useState(false);
  const [productionError, setProductionError] = useState('');
  const [productionSetup, setProductionSetup] = useState({
    start_station: '',
    finish_station: '',
    loading_time_s: '',
    unloading_time_s: '',
    duration_hours: ''
  });
  const [productionSetupSaving, setProductionSetupSaving] = useState(false);
  const [taskInputs, setTaskInputs] = useState({}); // { [transporterId]: { lift: '', sink: '' } }
  const [transporters, setTransporters] = useState([]);
  const [stations, setStations] = useState([]);
  const [tanks, setTanks] = useState([]);
  const [batches, setBatches] = useState([]);
  const [units, setUnits] = useState([]);
  const [transporterTasks, setTransporterTasks] = useState([]);
  const [manualTasks, setManualTasks] = useState([]);        // Käsin annetut tehtävät (pending queue)
  const [avoidStatuses, setAvoidStatuses] = useState({}); // { [stationNumber]: 0|1|2 }
  const [transporterStates, setTransporterStates] = useState([]); // backend snapshots
  const [displayTransporterStates, setDisplayTransporterStates] = useState([]); // interpolated for smooth UI
  const [debugTransporterId, setDebugTransporterId] = useState(null);
  const [editingBatchId, setEditingBatchId] = useState(null);
  const [plantSetups, setPlantSetups] = useState([]);
  const [selectedPlantSetup, setSelectedPlantSetup] = useState('');
  // Customer management
  const [showCustomer, setShowCustomer] = useState(false);
  const [customers, setCustomers] = useState([]);
  const [selectedCustomer, setSelectedCustomer] = useState('');
  const [selectedPlant, setSelectedPlant] = useState('');
  const [customerPlants, setCustomerPlants] = useState([]);
  const [customerError, setCustomerError] = useState('');
  const [creatingCustomer, setCreatingCustomer] = useState(false);
  const [newCustomerName, setNewCustomerName] = useState('');
  const [creatingPlant, setCreatingPlant] = useState(false);
  const [newPlantName, setNewPlantName] = useState('');
  // Plant status and template
  const [plantStatus, setPlantStatus] = useState(null);
  const [selectedTemplate, setSelectedTemplate] = useState('');
  const [copyingTemplate, setCopyingTemplate] = useState(false);
  // Simulation purpose form
  const [simPurpose, setSimPurpose] = useState(null);
  const [simPurposeForm, setSimPurposeForm] = useState({ country: '', city: '', purpose: '' });
  const [simPurposeSaving, setSimPurposeSaving] = useState(false);
  // PLC Runtime state
  const [plcStatus, setPlcStatus] = useState({ runtime_status: 'unknown', plc_alive: false, connected: false, cycle_count: 0 });
  const [plcToggling, setPlcToggling] = useState(false);
  const [productionQueue, setProductionQueue] = useState(0);
  const [productionStartTime, setProductionStartTime] = useState(null);
  const [productionDuration, setProductionDuration] = useState(0);
  // Layout config editor
  const [showConfig, setShowConfig] = useState(false);
  const [showCalibration, setShowCalibration] = useState(false);
  const [configForm, setConfigForm] = useState(null);
  const [configSaving, setConfigSaving] = useState(false);
  const [configError, setConfigError] = useState('');
  const emptyBatchForm = {
    unit_id: '',
    batch_id: '',
    location: '',
    treatment_program: '',
    stage: '',
    min_time_s: '',
    max_time_s: '',
    calc_time_s: '',
    start_time: ''
  };
  const [batchForm, setBatchForm] = useState(emptyBatchForm);
  const [batchSaving, setBatchSaving] = useState(false);
  const [batchError, setBatchError] = useState('');
  const [selectedUnitId, setSelectedUnitId] = useState('');
  const [unitLocationEdit, setUnitLocationEdit] = useState('');
  const [unitBatchEdit, setUnitBatchEdit] = useState(0);
  const [unitStatusEdit, setUnitStatusEdit] = useState(0);
  const [unitTargetEdit, setUnitTargetEdit] = useState('none');
  const [unitSaving, setUnitSaving] = useState(false);
  const lastTickRef = useRef(null);
  const elapsedMsRef = useRef(0);
  const latestSnapshotRef = useRef({ timeMs: performance.now(), transporters: [] });

  // Load saved customer/plant selection from backend on startup
  useEffect(() => {
    // Poll PLC runtime status every 2 seconds
    const pollPlcStatus = async () => {
      try {
        const data = await api.get('/api/plc/status');
        if (data) {
          setPlcStatus(data);
          if (typeof data.production_queue === 'number') setProductionQueue(data.production_queue);
        }
      } catch (err) { /* ignore */ }
    };
    pollPlcStatus();
    const plcInterval = setInterval(pollPlcStatus, 2000);
    return () => clearInterval(plcInterval);
  }, []);

  useEffect(() => {
    const initializeData = async () => {
      try {
        console.log("Loading configuration files...");
        // Try to load config from current plant setup via API
        // If no customer/plant is selected yet, the API will return errors — this is OK
        const [configRes, transportersRes, stationsRes, tanksRes] = await Promise.allSettled([
          api.get('/api/config/layout_config.json'),
          api.get('/api/config/transporters.json'),
          api.get('/api/config/stations.json'),
          api.get('/api/config/tanks.json')
        ]);

        // If any core config fetch fails (no customer selected), show waiting state
        if (configRes.status === 'rejected' || stationsRes.status === 'rejected' || transportersRes.status === 'rejected') {
          console.log("No configuration loaded — waiting for customer/plant selection");
          setLoadError(null);  // Not an error, just no selection yet
          return;
        }

        const configData = configRes.value;
        const transportersData = transportersRes.value;
        const stationsData = stationsRes.value;
        const tanksData = tanksRes.status === 'fulfilled' ? tanksRes.value : { tanks: [] };
        
        console.log("Config loaded:", configData.layout);
        console.log("Transporters loaded:", transportersData.transporters.length);
        console.log("Stations loaded:", stationsData.stations.length);
        console.log("Tanks loaded:", tanksData.tanks?.length || 0);
        
        setConfig(configData.layout);
        setTransporters(transportersData.transporters);
        setStations(stationsData.stations);
        setTanks(tanksData.tanks || []);

        try {
          await fetchBatchesFromApi();
          await fetchUnitsFromApi();
        } catch (err) {
          console.warn('Could not load batches/units, proceeding without them');
        }

        try {
          await loadAvoidStatuses();
        } catch (err) {
          console.warn('Could not load avoid statuses, using defaults');
        }

        try {
          await loadPlantSetups();
        } catch (err) {
          console.warn('Could not load plant setups');
        }

        // Load current sim time and speed from backend if available
        await syncSimTime();
        
        // Reset transporter states to ensure they match current configuration
        try {
          const resetData = await api.post(`/api/reset-transporters`);
          if (resetData && resetData.success && resetData.transporters) {
            console.log("Transporter states reset on load:", resetData.transporters.length);
            setTransporterStates(resetData.transporters);
            setDisplayTransporterStates(resetData.transporters);
            latestSnapshotRef.current = { timeMs: performance.now(), transporters: resetData.transporters };
          } else {
            throw new Error('Reset failed');
          }
        } catch (error) {
          console.log("Could not reset transporter states, generating locally");
          generateInitialStates(transportersData.transporters, stationsData.stations);
        }
        
        console.log("All data loaded successfully!");
        setLoadError(null);
      } catch (error) {
        console.error("Error loading configuration:", error);
        setLoadError('Configuration loading failed');
      }
    };
    
    initializeData();
  }, []);

  // Poll batches so erä-palkit päivittyvät backend-kirjoituksista
  useEffect(() => {
    let cancelled = false;
    const fetchBatchesAndUnits = async () => {
      try {
        const data = await fetchBatchesFromApi();
        if (cancelled) return;
        if (data && Array.isArray(data.batches)) {
          setBatches(data.batches);
        }
        await fetchUnitsFromApi();
      } catch (err) {
        // silently ignore polling errors
      }
    };
    fetchBatchesAndUnits();
    const id = setInterval(fetchBatchesAndUnits, 2000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  // Poll transporter tasks from backend
  const fetchTransporterTasks = async () => {
    try {
      const data = await api.get('/api/transporter-tasks');
      if (data && Array.isArray(data.tasks)) {
        setTransporterTasks(data.tasks);
      }
    } catch (err) {
      // silently ignore polling errors
    }
  };

  useEffect(() => {
    let cancelled = false;
    const fetchTasks = async () => {
      try {
        const [tasksRes, manualRes] = await Promise.allSettled([
          api.get('/api/transporter-tasks'),
          api.get('/api/manual-tasks')
        ]);
        if (cancelled) return;
        
        if (tasksRes.status === 'fulfilled' && tasksRes.value && Array.isArray(tasksRes.value.tasks)) {
          setTransporterTasks(tasksRes.value.tasks);
        }
        if (manualRes.status === 'fulfilled' && manualRes.value && Array.isArray(manualRes.value.tasks)) {
          setManualTasks(manualRes.value.tasks);
        }
      } catch (err) {
        // silently ignore polling errors
      }
    };
    fetchTasks();
    const id = setInterval(fetchTasks, 2000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  // Poll scheduler state for avg departure interval
  useEffect(() => {
    let cancelled = false;
    const fetchSchedulerState = async () => {
      try {
        const data = await api.get('/api/scheduler/state');
        if (cancelled) return;
        if (data && data.state && typeof data.state.avgDepartureIntervalSec === 'number') {
          setAvgCycleSec(data.state.avgDepartureIntervalSec);
        }
        if (data && data.productionStats) {
          setProductionStats(data.productionStats);
        }
      } catch (err) {
        // silently ignore polling errors
      }
    };
    fetchSchedulerState();
    const id = setInterval(fetchSchedulerState, 2000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  useEffect(() => {
    if (!showBatches) return undefined;
    let cancelled = false;
    const run = async () => {
      try {
        const data = await fetchBatchesFromApi();
        if (!cancelled && data && Array.isArray(data.batches)) {
          setBatches(data.batches);
        }
        if (!cancelled) await fetchUnitsFromApi();
      } catch (err) {
        // ignore
      }
    };
    run();
    return () => { cancelled = true; };
  }, [showBatches]);

  useEffect(() => {
    if (!showProduction) return undefined;
    let cancelled = false;
    const run = async () => {
      await loadTreatmentPrograms();
      if (cancelled) return;
      setProductionSetup((prev) => applyProductionDefaults(prev, stations, prev));
    };
    run();
    return () => { cancelled = true; };
  }, [showProduction, stations]);

  // Load customers when Customer panel is opened OR when there's a saved selection
  useEffect(() => {
    // Load customers if panel is open OR if there's a saved customer selection
    if (!showCustomer) return;
    const loadCustomers = async () => {
      try {
        const data = await api.get('/api/customers');
        if (data && data.success) {
          setCustomers(data.customers);
        }
      } catch (error) {
        console.error('Failed to load customers:', error);
        setCustomerError(error.message || 'Failed to load customers');
      }
    };
    loadCustomers();
  }, [showCustomer]);

  // Load plants when customer is selected
  useEffect(() => {
    if (!selectedCustomer) {
      setCustomerPlants([]);
      return;
    }
    const loadPlants = async () => {
      try {
        const data = await api.get(`/api/customers/${encodeURIComponent(selectedCustomer)}/plants`);
        if (data && data.success) {
          setCustomerPlants(data.plants);
        }
      } catch (error) {
        console.error('Failed to load plants:', error);
      }
    };
    loadPlants();
  }, [selectedCustomer]);

  // Load simulation purpose when plant is selected
  useEffect(() => {
    if (!selectedCustomer || !selectedPlant) {
      setSimPurpose(null);
      setSimPurposeForm({ country: '', city: '', purpose: '' });
      return;
    }
    const loadSimPurpose = async () => {
      try {
        const data = await api.get(`/api/customers/${encodeURIComponent(selectedCustomer)}/plants/${encodeURIComponent(selectedPlant)}/simulation-purpose`);
        if (data && data.success) {
          setSimPurpose(data.data);
          setSimPurposeForm({
            country: data.data.plant?.country || '',
            city: data.data.plant?.town || '',
            purpose: data.data.purpose || ''
          });
        }
      } catch (error) {
        console.error('Failed to load simulation purpose:', error);
      }
    };
    loadSimPurpose();
  }, [selectedCustomer, selectedPlant]);

  // Load plant status when plant is selected
  useEffect(() => {
    if (!selectedCustomer || !selectedPlant) {
      setPlantStatus(null);
      return;
    }
    const loadPlantStatus = async () => {
      try {
        const data = await api.get(`/api/customers/${encodeURIComponent(selectedCustomer)}/plants/${encodeURIComponent(selectedPlant)}/status`);
        if (data && data.success) {
          setPlantStatus(data);
        }
      } catch (error) {
        console.error('Failed to load plant status:', error);
      }
    };
    loadPlantStatus();
  }, [selectedCustomer, selectedPlant]);

  // Poll transporter states from backend so movement is visible
  useEffect(() => {
    let cancelled = false;
    const fetchStates = async () => {
      try {
        const data = await api.get('/api/transporter-states');
        if (!cancelled && data && Array.isArray(data.transporters) && data.transporters.length > 0) {
          setTransporterStates(data.transporters);
          setDisplayTransporterStates(data.transporters);
          latestSnapshotRef.current = { timeMs: performance.now(), transporters: data.transporters };
        }
      } catch (err) {
        console.error('Error polling transporter states:', err);
      }
    };

    fetchStates();
    const id = setInterval(fetchStates, 400);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  // Interpolate/extrapolate between polls for smoother motion
  useEffect(() => {
    let rafId;
    let lastRef = null;
    const tick = () => {
      const snapshot = latestSnapshotRef.current;
      if (snapshot.transporters !== lastRef) {
        lastRef = snapshot.transporters;
        setDisplayTransporterStates(snapshot.transporters);
      }
      rafId = requestAnimationFrame(tick);
    };
    rafId = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(rafId);
  }, []);

  // Keep production programs in sync with current plant setup
  useEffect(() => {
    loadTreatmentPrograms();
    loadProductionSetup();
  }, [selectedPlantSetup]);

  // Track current elapsed in a ref for pause handling without jumps
  useEffect(() => {
    elapsedMsRef.current = elapsedMs;
  }, [elapsedMs]);

  // Simulation clock: synced purely from backend (no UI-side interpolation)
  // This avoids drift when speedMultiplier causes backend to skip ticks

  // Simulation clock: sync from backend every 500ms (sole time source)
  useEffect(() => {
    let cancelled = false;
    const tick = async () => {
      if (cancelled) return;
      await syncSimTime();
    };
    tick(); // initial sync
    const id = setInterval(tick, 500);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [isRunning]);

  // Production duration timer — ticks every second while production is running
  useEffect(() => {
    if (!productionStartTime) return;
    const id = setInterval(() => {
      setProductionDuration(Date.now() - productionStartTime.getTime());
    }, 1000);
    return () => clearInterval(id);
  }, [productionStartTime]);

  // Initialize task inputs per transporter when list is loaded
  useEffect(() => {
    if (transporters.length === 0) return;
    setTaskInputs((prev) => {
      const next = { ...prev };
      transporters.forEach((t) => {
        if (!next[t.id]) {
          next[t.id] = { lift: '', sink: '' };
        }
      });
      return next;
    });
  }, [transporters]);

  const syncSimTime = async () => {
    try {
      const data = await api.get(`/api/sim/time`);
      if (data && typeof data.time === 'number') {
        const backendRunning = typeof data.running === 'boolean' ? data.running : isRunning;
        setElapsedMs((prev) => {
          if (backendRunning) return data.time;
          // When paused, never jump forward; keep the smaller of UI and backend
          return Math.min(prev, data.time);
        });
      }
      if (data && typeof data.speedMultiplier === 'number') {
        setSpeed(data.speedMultiplier);
      }
      if (data && typeof data.running === 'boolean') {
        setIsRunning(data.running);
        lastTickRef.current = data.running ? Date.now() : null;
      }
    } catch (err) {
      // ignore sync errors
    }
  };
  
  const generateInitialStates = (transportersList, stationsList) => {
    const initialStates = transportersList
      .filter(t => t.model === "2D")
      .map(transporter => {
        const startStation = stationsList.find(
          s => s.number === transporter.start_station
        );
        
        return {
          id: transporter.id,
          model: transporter.model,
          state: {
            x_position: startStation ? startStation.x_position : 0,
            z_position: 0,
            operation: "idle",
            current_station: transporter.start_station,
            load: null
          }
        };
      });
    
    setTransporterStates(initialStates);
    setDisplayTransporterStates(initialStates);
    latestSnapshotRef.current = { timeMs: performance.now(), transporters: initialStates };
    return initialStates;
  };

  const fetchBatchesFromApi = async () => {
    const url = `/api/batches?ts=${Date.now()}`;
    const data = await api.get(url, { cache: 'no-store' });
    if (data && Array.isArray(data.batches)) {
      setBatches(data.batches);
    }
    return data;
  };

  const fetchUnitsFromApi = async () => {
    try {
      const data = await api.get(`/api/units?ts=${Date.now()}`, { cache: 'no-store' });
      if (data && Array.isArray(data.units)) {
        setUnits(data.units);
      }
      return data;
    } catch (err) {
      console.warn('Could not load units:', err);
      return { units: [] };
    }
  };

  const loadAvoidStatuses = async () => {
    try {
      const data = await api.get(`/api/avoid-statuses`);
      if (data && data.stations) {
        const statusMap = {};
        Object.entries(data.stations).forEach(([stationNum, info]) => {
          statusMap[stationNum] = info.avoid_status || 0;
        });
        setAvoidStatuses(statusMap);
      }
    } catch (err) {
      console.warn('Could not load avoid statuses:', err);
    }
  };

  const loadPlantSetups = async () => {
    try {
      const data = await api.get(`/api/plant-setups`);
      if (data && Array.isArray(data.setups)) {
        setPlantSetups(data.setups);
        setSelectedPlantSetup(data.current || '');
      }
    } catch (err) {
      console.warn('Could not load plant setups:', err);
    }
  };

  const loadProductionSetup = async () => {
    try {
      const data = await api.get(`/api/production-setup`);
      if (data && data.success && data.setup) {
        setProductionSetup((prev) => applyProductionDefaults({
          start_station: data.setup.start_station ?? '',
          finish_station: data.setup.finish_station ?? '',
          loading_time_s: data.setup.loading_time_s ?? '',
          unloading_time_s: data.setup.unloading_time_s ?? '',
          duration_hours: data.setup.duration_hours ?? ''
        }, stations, prev));
      }
    } catch (err) {
      console.warn('Could not load production setup:', err);
    }
  };

  const applyProductionDefaults = (incoming, stationsList = [], previous = null) => {
    const next = { ...incoming };
    const loadingStations = Array.isArray(stationsList)
      ? stationsList.filter((s) => (s?.name || '').toLowerCase() === 'loading')
      : [];
    const unloadingStations = Array.isArray(stationsList)
      ? stationsList.filter((s) => (s?.name || '').toLowerCase() === 'unloading')
      : [];

    const loadingStart = loadingStations.reduce((acc, s) => {
      const n = Number(s?.number);
      if (!Number.isFinite(n)) return acc;
      return acc == null ? n : Math.min(acc, n);
    }, null);

    const unloadingFinish = unloadingStations.reduce((acc, s) => {
      const n = Number(s?.number);
      if (!Number.isFinite(n)) return acc;
      return acc == null ? n : Math.max(acc, n);
    }, null);

    // Only apply defaults when fields are empty; never override user input
    const prevState = previous || incoming;
    if ((prevState.start_station === '' || prevState.start_station == null) && loadingStart != null) {
      next.start_station = loadingStart;
    }
    if ((prevState.finish_station === '' || prevState.finish_station == null) && unloadingFinish != null) {
      next.finish_station = unloadingFinish;
    }
    const loadingEmpty = prevState.loading_time_s === '' || prevState.loading_time_s == null || Number(prevState.loading_time_s) <= 0;
    const unloadingEmpty = prevState.unloading_time_s === '' || prevState.unloading_time_s == null || Number(prevState.unloading_time_s) <= 0;
    const durationEmpty = prevState.duration_hours === '' || prevState.duration_hours == null || Number(prevState.duration_hours) <= 0;

    if (loadingEmpty) {
      next.loading_time_s = 60;
    }
    if (unloadingEmpty) {
      next.unloading_time_s = 60;
    }
    if (durationEmpty) {
      next.duration_hours = 1;
    }
    return next;
  };

  const syncProductionRowsWithPrograms = (programs) => {
    setProductionRows((rows) => {
      if (!Array.isArray(programs) || programs.length === 0) return [];
      
      // Ensure programs are numbers
      const validPrograms = programs.map(p => Number(p)).filter(n => Number.isFinite(n));
      if (validPrograms.length === 0) return [];

      const validSet = new Set(validPrograms);
      const defaultProgram = validPrograms[0];

      let next = rows.map(r => {
        const p = Number(r.program);
        const c = Number(r.count);
        return {
          program: validSet.has(p) ? p : defaultProgram,
          count: (Number.isInteger(c) && c > 0) ? c : 1,
          start_station: r.start_station || '',
          end_station: r.end_station || ''
        };
      });

      if (next.length === 0) {
        next = [{ program: defaultProgram, count: 1, start_station: '', end_station: '' }];
      }
      
      return next;
    });
  };

  const loadTreatmentPrograms = async () => {
    try {
      const data = await api.get(`/api/treatment-programs`);
      if (data && Array.isArray(data.programs)) {
        setProductionPrograms(data.programs);
        setProductionProgramDetails(data.programDetails || []);
        syncProductionRowsWithPrograms(data.programs);
      }
    } catch (err) {
      console.warn('Could not load treatment programs:', err);
      setProductionPrograms([]);
      setProductionProgramDetails([]);
      setProductionRows([]);
    }
  };

  const handleAvoidStatusChange = async (stationNumber, newStatus) => {
    try {
      await api.post(`/api/avoid-statuses`, { stationNumber: String(stationNumber), avoid_status: newStatus });
      await loadAvoidStatuses();
    } catch (err) {
      console.error('Error updating avoid status:', err);
    }
  };

  const resetBatchForm = () => {
    setEditingBatchId(null);
    setBatchForm(emptyBatchForm);
    setBatchError('');
    setSelectedUnitId('');
    setUnitLocationEdit('');
    setUnitBatchEdit(0);
    setUnitStatusEdit(0);
    setUnitTargetEdit('none');
  };

  // Käsittele Unit-valinnan muutos dropdownista
  const handleUnitSelect = (unitIdStr) => {
    setSelectedUnitId(unitIdStr);
    if (unitIdStr === '') {
      setUnitLocationEdit('');
      setUnitBatchEdit(0);
      setUnitStatusEdit(0);
      setUnitTargetEdit('none');
      return;
    }
    const uid = Number(unitIdStr);
    const unit = units.find(u => u.unit_id === uid);
    if (unit) {
      setUnitLocationEdit(String(unit.location || 0));
      setUnitBatchEdit(unit.batch_id || 0);
      setUnitStatusEdit(unit.status || 0);
      setUnitTargetEdit(unit.target || 'none');
    }
  };

  // Tallenna yksittäisen Unitin lokaation ja/tai statuksen muutos
  const handleUnitSave = async () => {
    if (selectedUnitId === '') return;
    const uid = Number(selectedUnitId);
    const newLoc = Number(unitLocationEdit);
    if (!Number.isFinite(newLoc)) { setBatchError('Invalid location'); return; }
    setUnitSaving(true);
    setBatchError('');
    try {
      await api.put(`/api/units/${uid}`, {
        batch_id: Number(unitBatchEdit) || 0,
        location: newLoc,
        status: Number(unitStatusEdit) || 0,
        target: unitTargetEdit || 'none'
      });
      await fetchUnitsFromApi();
    } catch (err) {
      setBatchError(err.message || 'Unit save failed');
    } finally {
      setUnitSaving(false);
    }
  };

  const handleEditBatch = (batch) => {
    setShowBatches(true);
    setEditingBatchId(batch.batch_id);
    // Etsi batchiin liittyvä unit
    const unit = units.find(u => u.batch_id === batch.batch_id);
    if (unit) {
      setSelectedUnitId(String(unit.unit_id));
      setUnitLocationEdit(String(unit.location));
      setUnitStatusEdit(unit.status || 'used');
      setUnitTargetEdit(unit.target || 'none');
    } else {
      setSelectedUnitId('');
      setUnitLocationEdit('');
      setUnitStatusEdit('used');
      setUnitTargetEdit('none');
    }
    setBatchForm({
      unit_id: unit ? unit.unit_id : '',
      batch_id: batch.batch_id != null ? Math.round(batch.batch_id) : '',
      location: batch.location != null ? Math.round(batch.location) : '',
      treatment_program: batch.treatment_program != null ? Math.round(batch.treatment_program) : '',
      stage: batch.stage != null ? Math.round(batch.stage) : '',
      min_time_s: batch.min_time_s != null ? Math.round(batch.min_time_s) : '',
      max_time_s: batch.max_time_s != null ? Math.round(batch.max_time_s) : '',
      calc_time_s: batch.calc_time_s != null ? Math.round(batch.calc_time_s) : '',
      start_time: batch.start_time != null ? Math.round(batch.start_time) : ''
    });
    setBatchError('');
  };

  const handleDeleteBatch = async (batchId) => {
    if (!window.confirm(`Delete batch ${batchId}?`)) return;
    try {
      await api.delete(`/api/batches/${batchId}`);
      await fetchBatchesFromApi();
      await fetchUnitsFromApi();
      if (editingBatchId === batchId) {
        resetBatchForm();
      }
    } catch (err) {
      setBatchError(err.message || 'Delete failed');
    }
  };

  const handleBatchSubmit = async (e) => {
    e.preventDefault();
    setBatchSaving(true);
    setBatchError('');
    const toInt = (v) => {
      const n = Number(v);
      return Number.isFinite(n) ? Math.round(n) : 0;
    };
    const payload = {
      batch_id: toInt(batchForm.batch_id),
      location: toInt(batchForm.location),
      treatment_program: toInt(batchForm.treatment_program),
      stage: toInt(batchForm.stage),
      min_time_s: toInt(batchForm.min_time_s),
      max_time_s: toInt(batchForm.max_time_s),
      calc_time_s: Number.isFinite(Number(batchForm.calc_time_s)) ? Math.round(Number(batchForm.calc_time_s)) : toInt(batchForm.min_time_s),
      start_time: Number.isFinite(Number(batchForm.start_time)) ? Math.round(Number(batchForm.start_time)) : 0
    };
    // Lisää unit_id payloadiin jos annettu (muuten serveri generoi automaattisesti)
    if (batchForm.unit_id !== '' && Number.isFinite(Number(batchForm.unit_id))) {
      payload.unit_id = Math.round(Number(batchForm.unit_id));
    }

    const method = editingBatchId != null ? 'PUT' : 'POST';
    const url = editingBatchId != null
      ? `/api/batches/${editingBatchId}`
      : '/api/batches';

    try {
      if (method === 'PUT') {
        await api.put(url, payload);
      } else {
        await api.post(url, payload);
      }
      await fetchBatchesFromApi();
      await fetchUnitsFromApi();
      resetBatchForm();
    } catch (err) {
      setBatchError(err.message || 'Save failed');
    } finally {
      setBatchSaving(false);
    }
  };

  const handleProductionRowChange = (idx, key, value) => {
    setProductionRows((rows) => rows.map((r, i) => {
      if (i !== idx) return r;
      if (key === 'count') {
        // Allow empty while typing; keep as string to avoid forced 0/leading zero
        const nextCount = value === '' ? '' : String(value);
        return { ...r, count: nextCount };
      }
      return { ...r, [key]: value };
    }));
  };

  const handleAddProductionRow = () => {
    const defaultProg = productionPrograms.length > 0 ? Number(productionPrograms[0]) : '';
    setProductionRows((rows) => [...rows, { program: defaultProg, count: 1, start_station: '', end_station: '' }]);
  };

  const handleRemoveProductionRow = (idx) => {
    setProductionRows((rows) => rows.filter((_, i) => i !== idx));
  };

  const handleCreateProduction = async () => {
    setProductionError('');
    // Apply defaults synchronously for this submit path
    const withDefaults = applyProductionDefaults(productionSetup, stations, productionSetup);
    if (withDefaults !== productionSetup) {
      setProductionSetup(withDefaults);
    }
    if (productionPrograms.length === 0) {
      setProductionError('No treatment programs found in current setup');
      return false;
    }

    const validPrograms = new Set(productionPrograms.map((p) => Number(p)));
    console.log('Creating production with rows:', productionRows);
    
    if (productionRows.length === 0) {
       // Fallback: if rows are empty but we have programs, try to create default
       if (productionPrograms.length > 0) {
         const defaultRow = { program: Number(productionPrograms[0]), count: 1, start_station: '', end_station: '' };
         console.log('Rows empty, using default:', defaultRow);
         // We can't update state and use it immediately, so we use a local var
         const pairs = [defaultRow];
         // Proceed with pairs...
         return await submitProductionPairs(pairs, validPrograms);
       }
    }

    const pairs = productionRows.map((row) => ({
      program: Number(row.program),
      count: Number(row.count),
      start_station: row.start_station ? Number(row.start_station) : null,
      end_station: row.end_station ? Number(row.end_station) : null
    }));
    console.log('Mapped pairs:', pairs);

    return await submitProductionPairs(pairs, validPrograms);
  };

  const submitProductionPairs = async (pairs, validPrograms) => {
    for (const pair of pairs) {
      if (!validPrograms.has(pair.program)) {
        setProductionError(`Program ${pair.program} is not in the current setup`);
        return false;
      }
      if (!Number.isInteger(pair.count) || pair.count <= 0) {
        setProductionError('Counts must be positive integers');
        return false;
      }
    }

    try {
      setProductionSaving(true);
      const data = await api.post(`/api/production`, { pairs });
      if (!data || !data.success) {
        throw new Error(data?.error || 'Failed to create production files');
      }
      syncProductionRowsWithPrograms(productionPrograms);
      return true;
    } catch (err) {
      setProductionError(err.message || 'Failed to create production files');
      return false;
    } finally {
      setProductionSaving(false);
    }
  };

  const handleSaveProductionSetup = async () => {
    setProductionError('');
    try {
      setProductionSetupSaving(true);
      const withDefaults = applyProductionDefaults(productionSetup, stations, productionSetup);
      if (withDefaults !== productionSetup) {
        setProductionSetup(withDefaults);
      }
      const payload = {
        start_station: withDefaults.start_station === '' ? null : Number(withDefaults.start_station),
        finish_station: withDefaults.finish_station === '' ? null : Number(withDefaults.finish_station),
        loading_time_s: Number(withDefaults.loading_time_s) || 0,
        unloading_time_s: Number(withDefaults.unloading_time_s) || 0,
        duration_hours: withDefaults.duration_hours === '' ? null : Number(withDefaults.duration_hours)
      };
      console.log('Saving production setup:', payload);
      const data = await api.post(`/api/production-setup`, payload);
      console.log('Production setup response:', data);
      if (!data || !data.success) {
        throw new Error(data?.error || 'Failed to save production setup');
      }
      return true;
    } catch (err) {
      console.error('Production setup error:', err);
      setProductionError(err.message || 'Failed to save production setup');
      return false;
    } finally {
      setProductionSetupSaving(false);
    }
  };

  const handleStart = async () => {
    if (productionQueue === 1) return; // already running
    try {
      // Set production_queue = 1 on PLC
      await api.post('/api/production-queue', { value: 1 });
      setProductionQueue(1);
      setProductionStartTime(new Date());
      // Also start sim clock if not running
      if (!isRunning) {
        const data = await api.post('/api/sim/start');
        if (data && typeof data.time === 'number') setElapsedMs(data.time);
        if (data && typeof data.speedMultiplier === 'number') setSpeed(data.speedMultiplier);
        if (data && typeof data.running === 'boolean') {
          setIsRunning(data.running);
          lastTickRef.current = data.running ? Date.now() : null;
        } else {
          setIsRunning(true);
          lastTickRef.current = Date.now();
        }
      }
    } catch (err) {
      console.error('Failed to start production:', err);
    }
  };

  const handleReset = async () => {
    if (!selectedCustomer || !selectedPlant) {
      console.warn('RESET: No customer/plant selected');
      return;
    }

    setIsResetting(true);
    setIsRunning(false);
    setElapsedMs(Math.floor(Date.now() / 1000));
    setAvgCycleSec(0);
    setProductionStartTime(null);
    setProductionDuration(0);
    setShowCustomer(false);
    lastTickRef.current = null;

    try {
      console.log(`[RESET] Uploading config: ${selectedCustomer}/${selectedPlant}`);
      const result = await api.post('/api/reset', { customer: selectedCustomer, plant: selectedPlant });

      if (result && result.success) {
        // Update UI layout with the returned config data
        if (result.layoutConfig) setConfig(result.layoutConfig);
        if (result.stations) setStations(result.stations);
        if (result.tanks) setTanks(result.tanks);
        if (result.transporters) setTransporters(result.transporters);
        console.log(`[RESET] Uploaded ${result.stations?.length || 0} stations to PLC`);


      } else {
        console.error('[RESET] Failed:', result.error);
        alert(`Reset failed: ${result.error}`);
      }
    } catch (error) {
      console.error('[RESET] Error:', error);
      alert(`Reset error: ${error.message}`);
    } finally {
      setIsResetting(false);
    }
  };

  const handleSpeedChange = async (multiplier) => {
    setSpeed(multiplier);
    if (isRunning) {
      lastTickRef.current = Date.now();
    }
    try {
      await api.post(`/api/sim/speed`, { multiplier });
      // re-sync after speed change to keep clocks aligned
      await syncSimTime();
    } catch (err) {
      console.error('Error setting speed:', err);
    }
  };

  const handleSendTask = async (transporterId, liftValue, sinkValue) => {
    const liftNumber = Number(liftValue);
    const sinkNumber = Number(sinkValue);
    if (!Number.isFinite(liftNumber) || !Number.isFinite(sinkNumber)) {
      alert('Enter both lift and sink station (integer)');
      return;
    }
    const liftStation = stations.find((s) => s.number === liftNumber);
    const sinkStation = stations.find((s) => s.number === sinkNumber);
    if (!liftStation || !sinkStation) {
      alert('Station not found');
      return;
    }

    try {
      // Tehtävä menee jonoon — taskScheduler sovittaa idle-slottiin
      const data = await api.post(`/api/command/move`, { transporterId, lift_station: liftNumber, sink_station: sinkNumber });
      if (data && data.queued) {
        console.log(`Manual task queued: T${transporterId} ${liftNumber}→${sinkNumber} (id=${data.taskId})`);
        // Päivitä manual tasks heti
        const manualData = await api.get('/api/manual-tasks');
        if (manualData && Array.isArray(manualData.tasks)) {
          setManualTasks(manualData.tasks);
        }
      }

      if (!isRunning) {
        const startData = await api.post(`/api/sim/start`);
        if (startData && typeof startData.time === 'number') setElapsedMs(startData.time);
        if (startData && typeof startData.running === 'boolean') {
          setIsRunning(startData.running);
          lastTickRef.current = startData.running ? Date.now() : null;
        }
      }
    } catch (err) {
      console.error('Error sending move command:', err);
    }
  };

  const handleCancelManualTask = async (taskId) => {
    try {
      await api.delete(`/api/manual-tasks/${taskId}`);
      setManualTasks(prev => prev.filter(t => t.id !== taskId));
    } catch (err) {
      console.error('Error cancelling manual task:', err);
    }
  };

  const formatTime = (ms) => {
    const totalMs = Math.max(0, Math.floor(ms));
    const hours = Math.floor(totalMs / 3600000).toString().padStart(2, '0');
    const minutes = Math.floor((totalMs % 3600000) / 60000).toString().padStart(2, '0');
    const seconds = Math.floor((totalMs % 60000) / 1000).toString().padStart(2, '0');
    const millis = (totalMs % 1000).toString().padStart(3, '0');
    return `${hours}:${minutes}:${seconds}.${millis}`;
  };

  // Build batches from PLC unit data for Station time bars (real-time from Modbus)
  // NOTE: Must be BEFORE the conditional return below to satisfy React hooks rules
  const plcBatches = useMemo(() => {
    if (!Array.isArray(units)) return [];
    return units
      .filter(u => u.batch_code && u.batch_code > 0)
      .map(u => ({
        batch_id: u.batch_code,
        location: u.location,
        stage: u.batch_stage,
        state: u.batch_state,
        treatment_program: u.batch_program,
        min_time_s: u.batch_min_time || 0,
        max_time_s: u.batch_max_time || 0,
        calc_time_s: u.batch_cal_time || 0,
        start_time: u.batch_start_time || 0  // unix seconds (same as currentTimeSec)
      }));
  }, [units]);

  // Guard: use lightweight render while config is loading / not yet selected
  // Show the exact same toolbar as the main view, just with empty layout area
  if (!config) {
    return (
      <div style={{ 
        width: '100vw', 
        height: '100vh', 
        display: 'flex', 
        flexDirection: 'column',
        background: '#f5f5f5'
      }}>
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
            {/* Logo */}
            <img src="/Codesys_logo.png" alt="CODESYS" style={{ height: 36, borderRadius: 6, objectFit: 'contain' }} />

            {/* PLC status indicator + toggle button */}
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              {/* Status dot */}
              <span
                title={plcStatus.runtime_status === 'running' ? 'PLC Running' : 'PLC Stopped'}
                style={{
                  width: 12, height: 12, borderRadius: '50%',
                  background: plcStatus.runtime_status === 'running' ? '#4caf50' : '#f44336',
                  boxShadow: `0 0 6px ${plcStatus.runtime_status === 'running' ? '#4caf50' : '#f44336'}`,
                  flexShrink: 0
                }}
              />
              {/* Toggle button: shows the ACTION (what clicking will do) */}
              {plcStatus.runtime_status === 'running' ? (
                <button
                  disabled={plcToggling}
                  onClick={async () => {
                    setPlcToggling(true);
                    try { await api.post('/api/plc/stop'); } catch {}
                    setTimeout(async () => {
                      try { const d = await api.get('/api/plc/status'); if (d) setPlcStatus(d); } catch {}
                      setPlcToggling(false);
                    }, 3000);
                  }}
                  title="Stop PLC"
                  style={{
                    width: 34, height: 34,
                    border: '2px solid #c62828',
                    borderRadius: 6, cursor: 'pointer',
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    background: '#ffebee',
                    opacity: plcToggling ? 0.5 : 1,
                    transition: 'background 0.2s'
                  }}
                >
                  <svg width="14" height="14" viewBox="0 0 14 14">
                    <rect x="1" y="1" width="12" height="12" rx="1" fill="#c62828" />
                  </svg>
                </button>
              ) : (
                <button
                  disabled={plcToggling}
                  onClick={async () => {
                    setPlcToggling(true);
                    try { await api.post('/api/plc/start'); } catch {}
                    setTimeout(async () => {
                      try { const d = await api.get('/api/plc/status'); if (d) setPlcStatus(d); } catch {}
                      setPlcToggling(false);
                    }, 2000);
                  }}
                  title="Start PLC"
                  style={{
                    width: 34, height: 34,
                    border: '2px solid #2e7d32',
                    borderRadius: 6, cursor: 'pointer',
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    background: '#e8f5e9',
                    opacity: plcToggling ? 0.5 : 1,
                    transition: 'background 0.2s'
                  }}
                >
                  <svg width="14" height="16" viewBox="0 0 14 16">
                    <polygon points="1,0 14,8 1,16" fill="#2e7d32" />
                  </svg>
                </button>
              )}
            </div>

            {/* Divider */}
            <div style={{ width: 1, height: 32, background: '#ddd' }} />

            {/* Customer / Plant */}
            {selectedCustomer && selectedPlant && (
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <span style={{ fontSize: 14, fontWeight: 600, color: '#333' }}>{selectedCustomer}</span>
                <span style={{ color: '#999', fontSize: 13 }}>/</span>
                <span style={{ fontSize: 13, color: '#666' }}>{selectedPlant}</span>
              </div>
            )}

          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button
              onClick={() => setShowCustomer((v) => !v)}
              style={{
                padding: '8px 12px', fontSize: '12px', fontWeight: 600, borderRadius: '4px',
                border: '1px solid #ccc', background: showCustomer ? '#1976d2' : '#fff',
                color: showCustomer ? '#fff' : '#333', cursor: 'pointer', width: 80,
                display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2
              }}
            >
              <span style={{ fontSize: 18 }}>👤</span>
              <span>Customer</span>
            </button>
            <button disabled style={{
              padding: '8px 12px', fontSize: '12px', fontWeight: 600, borderRadius: '4px',
              border: '1px solid #ccc', background: '#fff', color: '#aaa', width: 80,
              display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2, cursor: 'default', opacity: 0.5
            }}>
              <span style={{ fontSize: 18 }}>⚙️</span>
              <span>Config</span>
            </button>
            <button disabled style={{
              padding: '8px 12px', fontSize: '12px', fontWeight: 600, borderRadius: '4px',
              border: '1px solid #ccc', background: '#fff', color: '#aaa', width: 80,
              display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2, cursor: 'default', opacity: 0.5
            }}>
              <span style={{ fontSize: 18 }}>🏭</span>
              <span>Production</span>
            </button>
            <button disabled style={{
              padding: '8px 12px', fontSize: '12px', fontWeight: 600, borderRadius: '4px',
              border: '1px solid #ccc', background: '#fff', color: '#aaa', width: 80,
              display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2, cursor: 'default', opacity: 0.5
            }}>
              <span style={{ fontSize: 18 }}>📦</span>
              <span>Units</span>
            </button>
            <button disabled style={{
              padding: '8px 12px', fontSize: '12px', fontWeight: 600, borderRadius: '4px',
              border: '1px solid #ccc', background: '#fff', color: '#aaa', width: 80,
              display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2, cursor: 'default', opacity: 0.5
            }}>
              <span style={{ fontSize: 18 }}>📋</span>
              <span>Tasks</span>
            </button>
            <button disabled style={{
              padding: '8px 12px', fontSize: '12px', fontWeight: 600, borderRadius: '4px',
              border: '1px solid #ccc', background: '#fff', color: '#aaa', width: 80,
              display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2, cursor: 'default', opacity: 0.5
            }}>
              <span style={{ fontSize: 18 }}>📅</span>
              <span>Schedule</span>
            </button>
            <button disabled style={{
              padding: '8px 12px', fontSize: '12px', fontWeight: 600, borderRadius: '4px',
              border: '1px solid #ccc', background: '#fff', color: '#aaa', width: 80,
              display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2, cursor: 'default', opacity: 0.5
            }}>
              <span style={{ fontSize: 18 }}>📊</span>
              <span>Dashboard</span>
            </button>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
            <button disabled style={{
              padding: '8px 16px', fontSize: '13px', fontWeight: 600,
              border: 'none', borderRadius: '4px',
              background: '#4caf50', color: '#fff', opacity: 0.5, cursor: 'default'
            }}>
              START
            </button>
            <button
              onClick={handleReset}
              disabled={!selectedCustomer || !selectedPlant || isResetting}
              style={{
                padding: '8px 16px', fontSize: '13px', fontWeight: 600,
                border: 'none', borderRadius: '4px',
                cursor: (!selectedCustomer || !selectedPlant || isResetting) ? 'not-allowed' : 'pointer',
                background: isResetting ? '#b71c1c' : (!selectedCustomer || !selectedPlant) ? '#666' : '#f44336',
                color: '#fff',
                opacity: (!selectedCustomer || !selectedPlant) ? 0.5 : 1,
                transition: 'all 0.2s'
              }}
            >
              {isResetting ? 'RESETTING…' : 'RESET'}
            </button>
          </div>
        </div>
        <div style={{ flex: 1, overflow: 'hidden', padding: '16px' }} />
        {showCustomer && (
          <DraggablePanel title="Customer" onClose={() => { setShowCustomer(false); setCustomerError(''); }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12, minWidth: 350 }}>
              {customerError && <div style={{ color: '#c62828', fontWeight: 600, fontSize: 13 }}>{customerError}</div>}
              <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                <label style={{ fontWeight: 600, fontSize: 13 }}>Select Customer</label>
                <select value={selectedCustomer} onChange={(e) => { setSelectedCustomer(e.target.value); setSelectedPlant(''); }} style={{ padding: 8, borderRadius: 4, border: '1px solid #ccc', fontSize: 13 }}>
                  <option value="">-- Select customer --</option>
                  {customers.map(c => <option key={c} value={c}>{c}</option>)}
                </select>
              </div>
              {selectedCustomer && (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  <label style={{ fontWeight: 600, fontSize: 13 }}>Select Plant</label>
                  <select value={selectedPlant} onChange={(e) => setSelectedPlant(e.target.value)} style={{ padding: 8, borderRadius: 4, border: '1px solid #ccc', fontSize: 13 }}>
                    <option value="">-- Select plant --</option>
                    {customerPlants.map(p => <option key={p} value={p}>{p}</option>)}
                  </select>
                </div>
              )}
            </div>
          </DraggablePanel>
        )}
      </div>
    );
  }

  const debugTransporterState = debugTransporterId != null
    ? transporterStates.find((t) => t.id === debugTransporterId)
    : null;
  const debugTransporter = debugTransporterId != null
    ? transporters.find((t) => t.id === debugTransporterId)
    : null;
  const debugStation = debugTransporterState
    ? stations.find((s) => s.number === debugTransporterState.state.current_station)
    : null;
  const debugBatchAtStation = debugTransporterState && debugStation
    ? batches.find((b) => b.location === debugStation.number)
    : null;
  const debugBatchOnTransporter = debugTransporterState
    ? batches.find((b) => b.location === debugTransporterState.id)
    : null;
  const deviceDelay = debugStation ? Number(debugStation.device_delay) || 0 : 0;
  const minRequired = debugBatchAtStation ? Number(debugBatchAtStation.min_time_s) || 0 : 0;
  const startSec = debugBatchAtStation ? Number(debugBatchAtStation.start_time) || 0 : 0;
  const elapsedSec = Math.max(0, elapsedMs - startSec);
  const extraWait = Math.max(0, minRequired - elapsedSec);
  const initialDelay = extraWait > deviceDelay ? extraWait : deviceDelay;
  const delayRemaining = debugTransporterState && debugTransporterState.state.phase === 1 && debugTransporterState.state.z_stage === 'delay_up'
    ? debugTransporterState.state.z_timer
    : initialDelay;
  const sortedBatches = Array.isArray(batches)
    ? [...batches].sort((a, b) => Number(a.batch_id) - Number(b.batch_id))
    : [];
  const batchFormTitle = editingBatchId != null ? `Edit batch ${editingBatchId}` : 'Add batch';

  return (
    <div style={{ 
      width: '100vw', 
      height: '100vh', 
      display: 'flex', 
      flexDirection: 'column',
      background: '#f5f5f5'
    }}>
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
          {/* Logo */}
          <img src="/Codesys_logo.png" alt="CODESYS" style={{ height: 36, borderRadius: 6, objectFit: 'contain' }} />

          {/* PLC status indicator + toggle button */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            {/* Status dot */}
            <span
              title={plcStatus.runtime_status === 'running' ? 'PLC Running' : 'PLC Stopped'}
              style={{
                width: 12, height: 12, borderRadius: '50%',
                background: plcStatus.runtime_status === 'running' ? '#4caf50' : '#f44336',
                boxShadow: `0 0 6px ${plcStatus.runtime_status === 'running' ? '#4caf50' : '#f44336'}`,
                flexShrink: 0
              }}
            />
            {/* Toggle button: shows the ACTION (what clicking will do) */}
            {plcStatus.runtime_status === 'running' ? (
              <button
                disabled={plcToggling}
                onClick={async () => {
                  setPlcToggling(true);
                  try { await api.post('/api/plc/stop'); } catch {}
                  setTimeout(async () => {
                    try { const d = await api.get('/api/plc/status'); if (d) setPlcStatus(d); } catch {}
                    setPlcToggling(false);
                  }, 3000);
                }}
                title="Stop PLC"
                style={{
                  width: 34, height: 34,
                  border: '2px solid #c62828',
                  borderRadius: 6, cursor: 'pointer',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  background: '#ffebee',
                  opacity: plcToggling ? 0.5 : 1,
                  transition: 'background 0.2s'
                }}
              >
                <svg width="14" height="14" viewBox="0 0 14 14">
                  <rect x="1" y="1" width="12" height="12" rx="1" fill="#c62828" />
                </svg>
              </button>
            ) : (
              <button
                disabled={plcToggling}
                onClick={async () => {
                  setPlcToggling(true);
                  try { await api.post('/api/plc/start'); } catch {}
                  setTimeout(async () => {
                    try { const d = await api.get('/api/plc/status'); if (d) setPlcStatus(d); } catch {}
                    setPlcToggling(false);
                  }, 2000);
                }}
                title="Start PLC"
                style={{
                  width: 34, height: 34,
                  border: '2px solid #2e7d32',
                  borderRadius: 6, cursor: 'pointer',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  background: '#e8f5e9',
                  opacity: plcToggling ? 0.5 : 1,
                  transition: 'background 0.2s'
                }}
              >
                <svg width="14" height="16" viewBox="0 0 14 16">
                  <polygon points="1,0 14,8 1,16" fill="#2e7d32" />
                </svg>
              </button>
            )}
          </div>

          {/* Divider */}
          <div style={{ width: 1, height: 32, background: '#ddd' }} />

          {/* Customer / Plant — card style, fixed min-width to prevent layout shift */}
          <div style={{
            minWidth: 280,
            minHeight: 38,
            display: 'flex',
            alignItems: 'center'
          }}>
            {selectedCustomer && selectedPlant && (
              <div style={{
                padding: '6px 14px',
                background: plantStatus?.isConfigured ? '#e8f5e9' : '#fff3e0',
                border: `1px solid ${plantStatus?.isConfigured ? '#a5d6a7' : '#ffcc80'}`,
                borderRadius: 4,
                lineHeight: 1.4,
                width: '100%'
              }}>
                <div style={{ fontSize: 13, fontWeight: 700, color: '#333' }}>
                  {selectedCustomer} / {selectedPlant}
                </div>
                {plantStatus?.analysis?.summary && (
                  <div style={{ fontSize: 12, color: '#2e7d32' }}>
                    {plantStatus.analysis.summary}
                  </div>
                )}
              </div>
            )}
          </div>

        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          <button
            onClick={() => setShowCustomer((v) => !v)}
            style={{
              padding: '8px 12px',
              fontSize: '12px',
              fontWeight: 600,
              borderRadius: '4px',
              border: '1px solid #ccc',
              background: showCustomer ? '#1976d2' : '#fff',
              color: showCustomer ? '#fff' : '#333',
              cursor: 'pointer',
              width: 80,
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 2
            }}
          >
            <span style={{ fontSize: 18 }}>👤</span>
            <span>Customer</span>
          </button>
          <button
            onClick={() => {
              // Initialize form with current config values
              if (config) {
                setConfigForm({
                  xDirection: config.xDirection || 'left-to-right',
                  yDirection: config.yDirection || 'top-to-bottom',
                  margins: {
                    singleLine: { ...(config.margins?.singleLine || { top: 200, right: 60, bottom: 200, left: 60 }) },
                    multiLine: { ...(config.margins?.multiLine || { top: 40, right: 60, bottom: 40, left: 60 }) }
                  },
                  grid: { ...(config.grid || { show: false, spacing: 100, color: '#e0e0e0' }) },
                  stations: { ...(config.stations || {}) },
                  transporters: { ...(config.transporters || {}) }
                });
              }
              setShowConfig((v) => !v);
            }}
            style={{
              padding: '8px 12px',
              fontSize: '12px',
              fontWeight: 600,
              borderRadius: '4px',
              border: '1px solid #ccc',
              background: showConfig ? '#1976d2' : '#fff',
              color: showConfig ? '#fff' : '#333',
              cursor: 'pointer',
              width: 80,
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 2
            }}
          >
            <span style={{ fontSize: 18 }}>⚙️</span>
            <span>Config</span>
          </button>
          <button
            onClick={() => setShowCalibration((v) => !v)}
            style={{
              padding: '8px 12px',
              fontSize: '12px',
              fontWeight: 600,
              borderRadius: '4px',
              border: '1px solid #ccc',
              background: showCalibration ? '#1976d2' : '#fff',
              color: showCalibration ? '#fff' : '#333',
              cursor: 'pointer',
              width: 80,
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 2
            }}
          >
            <span style={{ fontSize: 18 }}>🎯</span>
            <span>Calibrate</span>
          </button>
          <button
            onClick={() => setShowProduction((v) => !v)}
            style={{
              padding: '8px 12px',
              fontSize: '12px',
              fontWeight: 600,
              borderRadius: '4px',
              border: '1px solid #ccc',
              background: showProduction ? '#1976d2' : '#fff',
              color: showProduction ? '#fff' : '#333',
              cursor: 'pointer',
              width: 80,
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 2
            }}
          >
            <span style={{ fontSize: 18 }}>🏭</span>
            <span>Production</span>
          </button>
          <button
            onClick={() => setShowBatches((v) => !v)}
            style={{
              padding: '8px 12px',
              fontSize: '12px',
              fontWeight: 600,
              borderRadius: '4px',
              border: '1px solid #ccc',
              background: showBatches ? '#1976d2' : '#fff',
              color: showBatches ? '#fff' : '#333',
              cursor: 'pointer',
              width: 80,
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 2
            }}
          >
            <span style={{ fontSize: 18 }}>📦</span>
            <span>Units</span>
          </button>
          <button
            onClick={() => setShowTasks((v) => !v)}
            style={{
              padding: '8px 12px',
              fontSize: '12px',
              fontWeight: 600,
              borderRadius: '4px',
              border: '1px solid #ccc',
              background: showTasks ? '#1976d2' : '#fff',
              color: showTasks ? '#fff' : '#333',
              cursor: 'pointer',
              width: 80,
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 2
            }}
          >
            <span style={{ fontSize: 18 }}>📋</span>
            <span>Tasks</span>
          </button>
          <button
            onClick={() => window.open('/schedule.html', '_blank')}
            style={{
              padding: '8px 12px',
              fontSize: '12px',
              fontWeight: 600,
              borderRadius: '4px',
              border: '1px solid #ccc',
              background: '#fff',
              color: '#333',
              cursor: 'pointer',
              width: 80,
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 2
            }}
          >
            <span style={{ fontSize: 18 }}>📅</span>
            <span>Schedule</span>
          </button>
          <button
            onClick={() => window.open('/dashboard.html', '_blank')}
            style={{
              padding: '8px 12px',
              fontSize: '12px',
              fontWeight: 600,
              borderRadius: '4px',
              border: '1px solid #ccc',
              background: '#fff',
              color: '#333',
              cursor: 'pointer',
              width: 80,
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 2
            }}
          >
            <span style={{ fontSize: 18 }}>📊</span>
            <span>Dashboard</span>
          </button>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
          {/* Production time display — fixed width to prevent layout shift */}
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
          <button
            onClick={handleStart}
            disabled={!!productionStartTime}
            style={{
              padding: '8px 0',
              fontSize: '13px',
              fontWeight: 600,
              border: 'none',
              borderRadius: '4px',
              cursor: productionStartTime ? 'default' : 'pointer',
              background: '#4caf50',
              color: '#fff',
              width: 100,
              textAlign: 'center',
              transition: 'all 0.2s'
            }}
          >
            {productionStartTime ? 'RUN' : 'START'}
          </button>
          <button
            onClick={handleReset}
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
      </div>
      <div style={{ flex: 1, overflow: 'hidden', padding: '16px' }}>
        <StationLayout 
          config={config}
          stations={stations}
          tanks={tanks}
          transporters={transporters}
          transporterStates={displayTransporterStates}
          batches={plcBatches}
          units={units}
          currentSimMs={elapsedMs}
          avoidStatuses={avoidStatuses}
          onAvoidStatusChange={handleAvoidStatusChange}
          setDebugTransporterId={setDebugTransporterId}
          avgCycleSec={avgCycleSec}
          productionStats={productionStats}
        />
      </div>
      {debugTransporterState && debugTransporter && (
        <DraggablePanel onClose={() => setDebugTransporterId(null)} title={`Transporter ${debugTransporter.id} – debug`}>
          <div style={{ fontFamily: 'monospace', fontSize: 12, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
            <div>phase: {debugTransporterState.state.phase}</div>
            <div>z_stage: {debugTransporterState.state.z_stage}</div>
            <div>z_timer: {Number(debugTransporterState.state.z_timer || 0).toFixed(2)} s</div>
            <div>operation: {debugTransporterState.state.operation}</div>
            <div>current_station: {debugTransporterState.state.current_station}</div>
            <div>lift_target: {debugTransporterState.state.lift_station_target || '-'}</div>
            <div>sink_target: {debugTransporterState.state.sink_station_target || '-'}</div>
            <div>device_delay: {deviceDelay}s</div>
            <div>batch_at_station: {debugBatchAtStation ? debugBatchAtStation.batch_id : '-'}</div>
            <div>batch_on_transporter: {debugBatchOnTransporter ? debugBatchOnTransporter.batch_id : '-'}</div>
            <div>elapsed_at_station: {elapsedSec.toFixed(2)} s</div>
            <div>min_required: {minRequired}s</div>
            <div>extra_wait: {extraWait.toFixed(2)} s</div>
            <div>initial_delay: {initialDelay.toFixed(2)} s</div>
            <div>delay_remaining: {Number(delayRemaining || 0).toFixed(2)} s</div>
            <div>z_position: {Number(debugTransporterState.state.z_position || 0).toFixed(1)} mm</div>
            <div>velocity_z: {Number(debugTransporterState.state.velocity_z || 0).toFixed(1)} mm/s</div>
          </div>
          <div style={{ marginTop: 12, fontSize: 12, color: '#333' }}>
            <div style={{ fontWeight: 700, marginBottom: 4 }}>Transition conditions</div>
            <ul style={{ paddingLeft: 16, margin: 0, lineHeight: 1.4 }}>
              <li>Phase 1 → 2: z_stage == 'delay_up' && z_timer &lt;= 0 (starts immediately if initial_delay = 0)</li>
              <li>Phase 2 → 3: lift z_stage reaches 'done' after drip</li>
              <li>Phase 3 → 4: X-travel to sink complete (snap) → phase=4, z_stage='idle'</li>
              <li>Phase 4 → idle: lowering complete, z_stage 'done'</li>
            </ul>
            </div>
          </DraggablePanel>
      )}

          {/* Config Layout Editor Panel */}

          {/* Calibration Panel */}
          {showCalibration && (
            <CalibrationPanel
              onClose={() => setShowCalibration(false)}
              stations={stations}
              transporterStates={transporterStates}
            />
          )}

          {showConfig && configForm && (
            <DraggablePanel title="Layout Configuration" onClose={() => { setShowConfig(false); setConfigError(''); }} width={480}>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 16, minWidth: 400 }}>
                {configError && (
                  <div style={{ color: '#c62828', fontWeight: 600, fontSize: 13 }}>{configError}</div>
                )}

                {/* Direction settings */}
                <fieldset style={{ border: '1px solid #ddd', borderRadius: 6, padding: 12 }}>
                  <legend style={{ fontWeight: 600, fontSize: 13, padding: '0 8px' }}>Direction</legend>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                    <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                      X Direction
                      <select
                        value={configForm.xDirection}
                        onChange={(e) => setConfigForm(f => ({ ...f, xDirection: e.target.value }))}
                        style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc' }}
                      >
                        <option value="left-to-right">Left to Right</option>
                        <option value="right-to-left">Right to Left</option>
                      </select>
                    </label>
                    <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                      Y Direction
                      <select
                        value={configForm.yDirection}
                        onChange={(e) => setConfigForm(f => ({ ...f, yDirection: e.target.value }))}
                        style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc' }}
                      >
                        <option value="top-to-bottom">Top to Bottom</option>
                        <option value="bottom-to-top">Bottom to Top</option>
                      </select>
                    </label>
                  </div>
                </fieldset>

                {/* Grid settings */}
                <fieldset style={{ border: '1px solid #ddd', borderRadius: 6, padding: 12 }}>
                  <legend style={{ fontWeight: 600, fontSize: 13, padding: '0 8px' }}>Grid</legend>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 12, alignItems: 'end' }}>
                    <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                      <input
                        type="checkbox"
                        checked={configForm.grid?.show || false}
                        onChange={(e) => setConfigForm(f => ({ ...f, grid: { ...f.grid, show: e.target.checked } }))}
                      />
                      Show Grid
                    </label>
                    <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                      Spacing
                      <input
                        type="number"
                        value={configForm.grid?.spacing || 100}
                        onChange={(e) => setConfigForm(f => ({ ...f, grid: { ...f.grid, spacing: Number(e.target.value) } }))}
                        style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #ccc', width: 80 }}
                      />
                    </label>
                    <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                      Color
                      <input
                        type="color"
                        value={configForm.grid?.color || '#e0e0e0'}
                        onChange={(e) => setConfigForm(f => ({ ...f, grid: { ...f.grid, color: e.target.value } }))}
                        style={{ padding: 2, borderRadius: 4, border: '1px solid #ccc', width: 60, height: 32 }}
                      />
                    </label>
                  </div>
                </fieldset>

                {/* Station settings */}
                <fieldset style={{ border: '1px solid #ddd', borderRadius: 6, padding: 12 }}>
                  <legend style={{ fontWeight: 600, fontSize: 13, padding: '0 8px' }}>Stations</legend>
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                    <div style={{ display: 'flex', gap: 16 }}>
                      <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                        <input
                          type="checkbox"
                          checked={configForm.stations?.showShadow !== false}
                          onChange={(e) => setConfigForm(f => ({ ...f, stations: { ...f.stations, showShadow: e.target.checked } }))}
                        />
                        Shadow
                      </label>
                      <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                        <input
                          type="checkbox"
                          checked={configForm.stations?.showLabels !== false}
                          onChange={(e) => setConfigForm(f => ({ ...f, stations: { ...f.stations, showLabels: e.target.checked } }))}
                        />
                        Labels
                      </label>
                      <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                        <input
                          type="checkbox"
                          checked={configForm.stations?.showAvoidCheckboxes !== false}
                          onChange={(e) => setConfigForm(f => ({ ...f, stations: { ...f.stations, showAvoidCheckboxes: e.target.checked } }))}
                        />
                        Avoid Checkboxes
                      </label>
                    </div>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                      <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                        Width (mm)
                        <input
                          type="number"
                          value={configForm.stations?.widthMM || 500}
                          onChange={(e) => setConfigForm(f => ({ ...f, stations: { ...f.stations, widthMM: Number(e.target.value) } }))}
                          style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #ccc' }}
                        />
                      </label>
                      <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                        Height (mm)
                        <input
                          type="number"
                          value={configForm.stations?.heightMM || 1200}
                          onChange={(e) => setConfigForm(f => ({ ...f, stations: { ...f.stations, heightMM: Number(e.target.value) } }))}
                          style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #ccc' }}
                        />
                      </label>
                    </div>
                  </div>
                </fieldset>

                {/* Transporter settings */}
                <fieldset style={{ border: '1px solid #ddd', borderRadius: 6, padding: 12 }}>
                  <legend style={{ fontWeight: 600, fontSize: 13, padding: '0 8px' }}>Transporters</legend>
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                    <div style={{ display: 'flex', gap: 16 }}>
                      <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                        <input
                          type="checkbox"
                          checked={configForm.transporters?.showUtilizationPie !== false}
                          onChange={(e) => setConfigForm(f => ({ ...f, transporters: { ...f.transporters, showUtilizationPie: e.target.checked } }))}
                        />
                        Utilization Pie
                      </label>
                      <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                        <input
                          type="checkbox"
                          checked={configForm.transporters?.showDriveLimits !== false}
                          onChange={(e) => setConfigForm(f => ({ ...f, transporters: { ...f.transporters, showDriveLimits: e.target.checked } }))}
                        />
                        Drive Limits
                      </label>
                    </div>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                      <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                        Height (mm)
                        <input
                          type="number"
                          value={configForm.transporters?.heightMM || 1400}
                          onChange={(e) => setConfigForm(f => ({ ...f, transporters: { ...f.transporters, heightMM: Number(e.target.value) } }))}
                          style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #ccc' }}
                        />
                      </label>
                      <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                        Width Scale
                        <input
                          type="number"
                          step="0.1"
                          min="0.1"
                          max="2"
                          value={configForm.transporters?.widthScaleFactor || 0.8}
                          onChange={(e) => setConfigForm(f => ({ ...f, transporters: { ...f.transporters, widthScaleFactor: Number(e.target.value) } }))}
                          style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #ccc' }}
                        />
                      </label>
                    </div>
                  </div>
                </fieldset>

                {/* Margins - Single Line */}
                <fieldset style={{ border: '1px solid #ddd', borderRadius: 6, padding: 12 }}>
                  <legend style={{ fontWeight: 600, fontSize: 13, padding: '0 8px' }}>Margins (Single Line)</legend>
                  <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 8 }}>
                    {['top', 'right', 'bottom', 'left'].map(side => (
                      <label key={side} style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 12 }}>
                        {side.charAt(0).toUpperCase() + side.slice(1)}
                        <input
                          type="number"
                          value={configForm.margins?.singleLine?.[side] || 60}
                          onChange={(e) => setConfigForm(f => ({
                            ...f,
                            margins: {
                              ...f.margins,
                              singleLine: { ...f.margins?.singleLine, [side]: Number(e.target.value) }
                            }
                          }))}
                          style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #ccc' }}
                        />
                      </label>
                    ))}
                  </div>
                </fieldset>

                {/* Margins - Multi Line */}
                <fieldset style={{ border: '1px solid #ddd', borderRadius: 6, padding: 12 }}>
                  <legend style={{ fontWeight: 600, fontSize: 13, padding: '0 8px' }}>Margins (Multi Line)</legend>
                  <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 8 }}>
                    {['top', 'right', 'bottom', 'left'].map(side => (
                      <label key={side} style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 12 }}>
                        {side.charAt(0).toUpperCase() + side.slice(1)}
                        <input
                          type="number"
                          value={configForm.margins?.multiLine?.[side] || 40}
                          onChange={(e) => setConfigForm(f => ({
                            ...f,
                            margins: {
                              ...f.margins,
                              multiLine: { ...f.margins?.multiLine, [side]: Number(e.target.value) }
                            }
                          }))}
                          style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #ccc' }}
                        />
                      </label>
                    ))}
                  </div>
                </fieldset>

                {/* Action buttons */}
                <div style={{ display: 'flex', gap: 12, justifyContent: 'flex-end', marginTop: 8 }}>
                  <button
                    onClick={() => { setShowConfig(false); setConfigError(''); }}
                    style={{
                      padding: '10px 20px',
                      borderRadius: 4,
                      border: '1px solid #ccc',
                      background: '#f5f5f5',
                      cursor: 'pointer',
                      fontWeight: 600,
                      fontSize: 13
                    }}
                  >
                    Cancel
                  </button>
                  <button
                    onClick={async () => {
                      setConfigSaving(true);
                      setConfigError('');
                      try {
                        // Build full layout config object
                        const fullConfig = {
                          layout: {
                            xDirection: configForm.xDirection,
                            yDirection: configForm.yDirection,
                            margins: configForm.margins,
                            grid: configForm.grid,
                            stations: configForm.stations,
                            transporters: configForm.transporters,
                            'cross-transporters': config['cross-transporters'] || {},
                            colors: config.colors || {}
                          }
                        };
                        
                        // Save to backend (file and runtime)
                        await api.put('/api/config/layout_config.json', fullConfig);
                        
                        // Update runtime config
                        setConfig(fullConfig.layout);
                        setShowConfig(false);
                      } catch (err) {
                        setConfigError(err.message || 'Failed to save');
                      } finally {
                        setConfigSaving(false);
                      }
                    }}
                    disabled={configSaving}
                    style={{
                      padding: '10px 20px',
                      borderRadius: 4,
                      border: 'none',
                      background: configSaving ? '#90caf9' : '#1976d2',
                      color: '#fff',
                      cursor: configSaving ? 'not-allowed' : 'pointer',
                      fontWeight: 600,
                      fontSize: 13
                    }}
                  >
                    {configSaving ? 'Saving...' : 'Save'}
                  </button>
                </div>
              </div>
            </DraggablePanel>
          )}

          {showCustomer && (
            <DraggablePanel title="Customer" onClose={() => { setShowCustomer(false); setCustomerError(''); }}>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 12, minWidth: 350 }}>
                {customerError && (
                  <div style={{ color: '#c62828', fontWeight: 600, fontSize: 13 }}>{customerError}</div>
                )}

                {/* Select existing customer */}
                <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  <label style={{ fontWeight: 600, fontSize: 13 }}>Select Customer</label>
                  {!creatingCustomer ? (
                    <div style={{ display: 'flex', gap: 8 }}>
                      <select
                        value={selectedCustomer}
                        onChange={async (e) => {
                          const newCustomer = e.target.value;
                          setSelectedCustomer(newCustomer);
                          setSelectedPlant('');
                          // Clear plant-related state when changing customer
                          setPlantStatus(null);
                          setSimPurpose(null);
                          setSimPurposeForm({ country: '', city: '', purpose: '' });
                          setSelectedTemplate('');
                          // Save selected customer to backend (plant is null until selected)
                          await api.post('/api/current-selection', { customer: newCustomer || null, plant: null });
                        }}
                        style={{ flex: 1, padding: 8, borderRadius: 4, border: '1px solid #ccc', fontSize: 13 }}
                      >
                        <option value="">-- Select customer --</option>
                        {customers.map(c => (
                          <option key={c} value={c}>{c}</option>
                        ))}
                      </select>
                      <button
                        onClick={() => {
                          // Open create form AND clear current selection
                          setCreatingCustomer(true);
                          setSelectedCustomer('');
                          setSelectedPlant('');
                          setPlantStatus(null);
                          setSimPurpose(null);
                          setSimPurposeForm({ country: '', city: '', purpose: '' });
                          setSelectedTemplate('');
                          // Clear backend selection
                          api.post('/api/current-selection', { customer: null, plant: null })
                            .catch(err => console.error('Failed to clear selection:', err));
                        }}
                        style={{
                          padding: '8px 12px',
                          borderRadius: 4,
                          border: 'none',
                          background: '#4caf50',
                          color: '#fff',
                          fontWeight: 600,
                          cursor: 'pointer',
                          fontSize: 13
                        }}
                      >
                        Create
                      </button>
                    </div>
                  ) : (
                    <div style={{ display: 'flex', gap: 8 }}>
                      <input
                        type="text"
                        value={newCustomerName}
                        onChange={(e) => setNewCustomerName(e.target.value)}
                        onKeyDown={async (e) => {
                          if (e.key === 'Enter' && newCustomerName.trim()) {
                            try {
                              const data = await api.post('/api/customers', { name: newCustomerName.trim() });
                              if (data && data.success) {
                                const newCustomer = newCustomerName.trim();
                                setCustomers(prev => [...prev, newCustomer].sort());
                                // SET the newly created customer as selected
                                setSelectedCustomer(newCustomer);
                                setSelectedPlant('');
                                setNewCustomerName('');
                                setCreatingCustomer(false);
                                setCustomerError('');
                                
                                // Clear plant-related state (but keep the new customer selected)
                                setPlantStatus(null);
                                setSimPurpose(null);
                                setSimPurposeForm({ country: '', city: '', purpose: '' });
                                setSelectedTemplate('');
                                
                                // Save the new customer selection to backend
                                try {
                                  await api.post('/api/current-selection', { customer: newCustomer, plant: null });
                                } catch (err) {
                                  console.error('Failed to save current selection:', err);
                                }
                              } else {
                                setCustomerError(data?.error || 'Failed to create customer');
                              }
                            } catch (error) {
                              setCustomerError('Failed to create customer');
                            }
                          } else if (e.key === 'Escape') {
                            setCreatingCustomer(false);
                            setNewCustomerName('');
                          }
                        }}
                        placeholder="Customer name (Enter to save, Esc to cancel)"
                        autoFocus
                        style={{ flex: 1, padding: 8, borderRadius: 4, border: '1px solid #4caf50', fontSize: 13 }}
                      />
                      <button
                        onClick={() => {
                          setCreatingCustomer(false);
                          setNewCustomerName('');
                        }}
                        style={{
                          padding: '8px 12px',
                          borderRadius: 4,
                          border: 'none',
                          background: '#9e9e9e',
                          color: '#fff',
                          fontWeight: 600,
                          cursor: 'pointer',
                          fontSize: 13
                        }}
                      >
                        Cancel
                      </button>
                    </div>
                  )}
                </div>

                {/* Select plant if customer selected */}
                {selectedCustomer && (
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                    <label style={{ fontWeight: 600, fontSize: 13 }}>Select Plant</label>
                    {!creatingPlant ? (
                      <div style={{ display: 'flex', gap: 8 }}>
                        <select
                          value={selectedPlant}
                          onChange={(e) => setSelectedPlant(e.target.value)}
                          style={{ flex: 1, padding: 8, borderRadius: 4, border: '1px solid #ccc', fontSize: 13 }}
                        >
                          <option value="">-- Select plant --</option>
                          {customerPlants.map(p => (
                            <option key={p} value={p}>{p}</option>
                          ))}
                        </select>
                        <button
                          onClick={() => setCreatingPlant(true)}
                          style={{
                            padding: '8px 12px',
                            borderRadius: 4,
                            border: 'none',
                            background: '#4caf50',
                            color: '#fff',
                            fontWeight: 600,
                            cursor: 'pointer',
                            fontSize: 13
                          }}
                        >
                          Create
                        </button>
                      </div>
                    ) : (
                      <div style={{ display: 'flex', gap: 8 }}>
                        <input
                          type="text"
                          value={newPlantName}
                          onChange={(e) => setNewPlantName(e.target.value)}
                          onKeyDown={async (e) => {
                            if (e.key === 'Enter' && newPlantName.trim()) {
                              try {
                                const data = await api.post(`/api/customers/${encodeURIComponent(selectedCustomer)}/plants`, { name: newPlantName.trim() });
                                if (data && data.success) {
                                  setCustomerPlants(prev => [...prev, newPlantName.trim()].sort());
                                  setSelectedPlant(newPlantName.trim());
                                  setNewPlantName('');
                                  setCreatingPlant(false);
                                  setCustomerError('');
                                } else {
                                  setCustomerError(data?.error || 'Failed to create plant');
                                }
                              } catch (error) {
                                setCustomerError('Failed to create plant');
                              }
                            } else if (e.key === 'Escape') {
                              setCreatingPlant(false);
                              setNewPlantName('');
                            }
                          }}
                          placeholder="Plant name (Enter to save, Esc to cancel)"
                          autoFocus
                          style={{ flex: 1, padding: 8, borderRadius: 4, border: '1px solid #4caf50', fontSize: 13 }}
                        />
                        <button
                          onClick={() => {
                            setCreatingPlant(false);
                            setNewPlantName('');
                          }}
                          style={{
                            padding: '8px 12px',
                            borderRadius: 4,
                            border: 'none',
                            background: '#9e9e9e',
                            color: '#fff',
                            fontWeight: 600,
                            cursor: 'pointer',
                            fontSize: 13
                          }}
                        >
                          Cancel
                        </button>
                      </div>
                    )}
                  </div>
                )}

                {/* Country and City fields (show when plant selected) */}
                {selectedCustomer && selectedPlant && (
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                      <label style={{ fontWeight: 600, fontSize: 12 }}>Country</label>
                      <input
                        type="text"
                        value={simPurposeForm.country}
                        onChange={(e) => setSimPurposeForm(prev => ({ ...prev, country: e.target.value }))}
                        placeholder="Country"
                        style={{ padding: 8, borderRadius: 4, border: '1px solid #ccc', fontSize: 13 }}
                      />
                    </div>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                      <label style={{ fontWeight: 600, fontSize: 12 }}>City</label>
                      <input
                        type="text"
                        value={simPurposeForm.city}
                        onChange={(e) => setSimPurposeForm(prev => ({ ...prev, city: e.target.value }))}
                        placeholder="City"
                        style={{ padding: 8, borderRadius: 4, border: '1px solid #ccc', fontSize: 13 }}
                      />
                    </div>
                  </div>
                )}

                {/* Setup template selection (only when plant not configured) */}
                {selectedCustomer && selectedPlant && plantStatus && !plantStatus.isConfigured && (
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                    <label style={{ fontWeight: 600, fontSize: 13 }}>Setup Template</label>
                    <div style={{ display: 'flex', gap: 8 }}>
                      <select
                        value={selectedTemplate}
                        onChange={(e) => setSelectedTemplate(e.target.value)}
                        style={{ flex: 1, padding: 8, borderRadius: 4, border: '1px solid #ccc', fontSize: 13 }}
                      >
                        <option value="">-- Select template --</option>
                        {plantSetups.map(t => (
                          <option key={t} value={t}>{t}</option>
                        ))}
                      </select>
                      <button
                        onClick={async () => {
                          if (!selectedTemplate) return;
                          setCopyingTemplate(true);
                          try {
                            const data = await api.post(
                              `/api/customers/${encodeURIComponent(selectedCustomer)}/plants/${encodeURIComponent(selectedPlant)}/copy-template`,
                              {
                                template: selectedTemplate,
                                customer: selectedCustomer,
                                plant: selectedPlant,
                                country: simPurposeForm.country,
                                city: simPurposeForm.city
                              }
                            );
                            if (data && data.success) {
                              // Reload plant status
                              const statusData = await api.get(`/api/customers/${encodeURIComponent(selectedCustomer)}/plants/${encodeURIComponent(selectedPlant)}/status`);
                              if (statusData && statusData.success) {
                                setPlantStatus(statusData);
                              }
                              // Reload simulation purpose
                              const purposeData = await api.get(`/api/customers/${encodeURIComponent(selectedCustomer)}/plants/${encodeURIComponent(selectedPlant)}/simulation-purpose`);
                              if (purposeData && purposeData.success) {
                                setSimPurpose(purposeData.data);
                                setSimPurposeForm({
                                  country: purposeData.data.plant?.country || '',
                                  city: purposeData.data.plant?.town || '',
                                  purpose: purposeData.data.purpose || ''
                                });
                              }
                              setSelectedTemplate('');
                              setCustomerError('');
                            } else {
                              setCustomerError(data?.error || 'Failed to copy template');
                            }
                          } catch (error) {
                            setCustomerError('Failed to copy template');
                          }
                          setCopyingTemplate(false);
                        }}
                        disabled={!selectedTemplate || copyingTemplate}
                        style={{
                          padding: '8px 12px',
                          borderRadius: 4,
                          border: 'none',
                          background: (!selectedTemplate || copyingTemplate) ? '#ccc' : '#4caf50',
                          color: '#fff',
                          fontWeight: 600,
                          cursor: (!selectedTemplate || copyingTemplate) ? 'not-allowed' : 'pointer',
                          fontSize: 13
                        }}
                      >
                        {copyingTemplate ? 'Copying...' : 'Copy'}
                      </button>
                    </div>
                  </div>
                )}

                {/* Current selection summary */}
                {selectedCustomer && selectedPlant && plantStatus && (
                  <div style={{ 
                    padding: 12, 
                    background: plantStatus.isConfigured ? '#e8f5e9' : '#fff3e0', 
                    border: `1px solid ${plantStatus.isConfigured ? '#a5d6a7' : '#ffcc80'}`,
                    borderRadius: 4, 
                    fontSize: 13,
                    marginTop: 8
                  }}>
                    <div style={{ fontWeight: 700, marginBottom: 4 }}>
                      {selectedCustomer} / {selectedPlant}
                    </div>
                    {plantStatus.isConfigured ? (
                      <div style={{ color: '#2e7d32' }}>
                        {plantStatus.analysis?.summary}
                      </div>
                    ) : (
                      <div style={{ color: '#e65100' }}>
                        Not configured
                      </div>
                    )}
                  </div>
                )}
              </div>
            </DraggablePanel>
          )}

          {showProduction && (
            <DraggablePanel title="Production" onClose={() => { setShowProduction(false); setProductionError(''); }}>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                {productionError && (
                  <div style={{ color: '#c62828', fontWeight: 600, fontSize: 13 }}>{productionError}</div>
                )}

                {productionPrograms.length === 0 ? (
                  <div style={{ color: '#666', fontSize: 13 }}>No treatment programs found in this setup.</div>
                ) : (
                  <>
                    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10, padding: 10, border: '1px solid #eee', borderRadius: 6, background: '#fafafa' }}>
                      <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                        Start Station
                        <select
                          value={productionSetup.start_station}
                          onChange={(e) => setProductionSetup((s) => ({ ...s, start_station: e.target.value }))}
                          style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc', background: '#fff', cursor: 'pointer' }}
                        >
                          <option value="">-- select --</option>
                          {stations.map((st) => (
                            <option key={st.number} value={st.number}>{st.number} - {st.name || `Station ${st.number}`}</option>
                          ))}
                        </select>
                      </label>
                      <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                        Finishing Station
                        <select
                          value={productionSetup.finish_station}
                          onChange={(e) => setProductionSetup((s) => ({ ...s, finish_station: e.target.value }))}
                          style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc', background: '#fff', cursor: 'pointer' }}
                        >
                          <option value="">-- select --</option>
                          {stations.map((st) => (
                            <option key={st.number} value={st.number}>{st.number} - {st.name || `Station ${st.number}`}</option>
                          ))}
                        </select>
                      </label>
                      <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                        Loading Time (s)
                        <input
                          type="number"
                          min="0"
                          step="1"
                          value={productionSetup.loading_time_s}
                          onChange={(e) => setProductionSetup((s) => ({ ...s, loading_time_s: e.target.value }))}
                          style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc' }}
                        />
                      </label>
                      <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                        Unloading Time (s)
                        <input
                          type="number"
                          min="0"
                          step="1"
                          value={productionSetup.unloading_time_s}
                          onChange={(e) => setProductionSetup((s) => ({ ...s, unloading_time_s: e.target.value }))}
                          style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc' }}
                        />
                      </label>
                      <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13, gridColumn: 'span 2' }}>
                        Duration (hours)
                        <input
                          type="number"
                          min="0"
                          step="0.5"
                          value={productionSetup.duration_hours}
                          onChange={(e) => setProductionSetup((s) => ({ ...s, duration_hours: e.target.value }))}
                          placeholder="Target production time in hours"
                          style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc' }}
                        />
                      </label>
                      <div style={{ gridColumn: 'span 2', display: 'flex', gap: 8 }}>
                        {/* Save setup button removed */}
                      </div>
                    </div>

                    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                      {productionRows.map((row, idx) => (
                        <div key={`prod-row-${idx}`} style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr 1fr auto', gap: 8, alignItems: 'center', padding: 8, border: '1px solid #eee', borderRadius: 6, background: '#fafafa' }}>
                          <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                            Count
                            <input
                              type="number"
                              min="1"
                              step="1"
                              value={row.count}
                              onChange={(e) => handleProductionRowChange(idx, 'count', e.target.value)}
                              style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc' }}
                            />
                          </label>
                          <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                            Treatment program
                            <select
                              value={row.program}
                              onChange={(e) => handleProductionRowChange(idx, 'program', Number(e.target.value))}
                              style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc', background: '#fff', cursor: 'pointer' }}
                            >
                              {productionProgramDetails.map((p) => (
                                <option key={p.number} value={p.number}>{p.filename}</option>
                              ))}
                            </select>
                          </label>
                          <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                            Start Station
                            <select
                              value={row.start_station}
                              onChange={(e) => handleProductionRowChange(idx, 'start_station', e.target.value)}
                              style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc', background: '#fff', cursor: 'pointer' }}
                            >
                              <option value="">-- default --</option>
                              {stations.map((st) => (
                                <option key={st.number} value={st.number}>{st.number} - {st.name || `Station ${st.number}`}</option>
                              ))}
                            </select>
                          </label>
                          <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 13 }}>
                            End Station
                            <select
                              value={row.end_station}
                              onChange={(e) => handleProductionRowChange(idx, 'end_station', e.target.value)}
                              style={{ padding: '8px 10px', borderRadius: 4, border: '1px solid #ccc', background: '#fff', cursor: 'pointer' }}
                            >
                              <option value="">-- default --</option>
                              {stations.map((st) => (
                                <option key={st.number} value={st.number}>{st.number} - {st.name || `Station ${st.number}`}</option>
                              ))}
                            </select>
                          </label>
                          <div style={{ display: 'flex', justifyContent: 'flex-end', alignItems: 'center', gap: 8 }}>
                            {productionPrograms.length > 1 && productionRows.length > 1 && (
                              <button
                                type="button"
                                onClick={() => handleRemoveProductionRow(idx)}
                                style={{ padding: '8px 12px', borderRadius: 4, border: '1px solid #f44336', background: '#ffebee', cursor: 'pointer', fontSize: 12 }}
                              >
                                Remove
                              </button>
                            )}
                          </div>
                        </div>
                      ))}
                    </div>

                    <div style={{ display: 'flex', gap: 8 }}>
                      <button
                        type="button"
                        onClick={handleAddProductionRow}
                        disabled={productionPrograms.length <= 1}
                        style={{ padding: '10px 12px', borderRadius: 6, border: '1px solid #ccc', background: '#fff', fontWeight: 600, cursor: productionPrograms.length <= 1 ? 'not-allowed' : 'pointer' }}
                      >
                        Add row
                      </button>
                      <button
                        type="button"
                        onClick={async () => {
                          const setupSuccess = await handleSaveProductionSetup();
                          if (!setupSuccess) return;
                          const createSuccess = await handleCreateProduction();
                          if (createSuccess) {
                            await fetchBatchesFromApi();
                            await fetchUnitsFromApi();
                            setShowProduction(false);
                          }
                        }}
                        disabled={productionSaving || productionSetupSaving}
                        style={{ padding: '10px 16px', borderRadius: 6, border: '1px solid #2196f3', background: '#e3f2fd', fontWeight: 700, cursor: 'pointer' }}
                      >
                        {productionSaving || productionSetupSaving ? 'Creating…' : 'Create'}
                      </button>
                    </div>
                  </>
                )}
              </div>
            </DraggablePanel>
          )}

        {showBatches && (
          <DraggablePanel title="Units" onClose={() => { setShowBatches(false); resetBatchForm(); }} width={880}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              {batchError && (
                <div style={{ color: '#c62828', fontWeight: 600, fontSize: 13 }}>{batchError}</div>
              )}

              {/* Unit list — read from PLC */}
              <div style={{ maxHeight: 260, overflowY: 'auto', border: '1px solid #eee', borderRadius: 6, padding: 8, background: '#fafafa' }}>
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
                  <thead>
                    <tr style={{ borderBottom: '2px solid #ccc', textAlign: 'left' }}>
                      <th style={{ padding: '3px 4px' }}>Unit</th>
                      <th style={{ padding: '3px 4px' }}>Loc</th>
                      <th style={{ padding: '3px 4px' }}>Status</th>
                      <th style={{ padding: '3px 4px' }}>Target</th>
                      <th style={{ padding: '3px 4px', borderLeft: '2px solid #90caf9' }}>Batch</th>
                      <th style={{ padding: '3px 4px' }}>State</th>
                      <th style={{ padding: '3px 4px' }}>Program</th>
                      <th style={{ padding: '3px 4px' }}>Stage</th>
                      <th style={{ padding: '3px 4px' }}>MinTime</th>
                      <th style={{ padding: '3px 4px' }}>MaxTime</th>
                      <th style={{ padding: '3px 4px' }}>CalcTime</th>
                      <th style={{ padding: '3px 4px' }}></th>
                    </tr>
                  </thead>
                  <tbody>
                    {units.map(u => {
                      const statusLabels = { 0: 'not_used', 1: 'used' };
                      const targetLabels = { 'none': 'none', 'to_loading': 'to_load', 'to_buffer': 'to_buf', 'to_process': 'to_proc', 'to_unload': 'to_unl', 'to_avoid': 'to_avoid', 0: 'none', 1: 'to_load', 2: 'to_buf', 3: 'to_proc', 4: 'to_unl', 5: 'to_avoid' };
                      const batchStateLabels = { 'not_processed': 'Not Processed', 'in_process': 'In Process', 'processed': 'Processed' };
                      const isUsed = u.status === 1;
                      const hasBatch = u.batch_code && u.batch_code !== 0;
                      const fmtTime = (s) => s != null && s !== 0 ? `${Math.floor(s/60)}:${String(s%60).padStart(2,'0')}` : '—';
                      return (
                        <tr key={u.unit_id} style={{ borderBottom: '1px solid #f0f0f0', opacity: isUsed ? 1 : 0.5 }}>
                          <td style={{ padding: '3px 4px', fontWeight: 700 }}>U{u.unit_id}</td>
                          <td style={{ padding: '3px 4px' }}>{u.location || '—'}</td>
                          <td style={{ padding: '3px 4px' }}>{statusLabels[u.status] || u.status}</td>
                          <td style={{ padding: '3px 4px' }}>{targetLabels[u.target] || u.target}</td>
                          <td style={{ padding: '3px 4px', borderLeft: '2px solid #90caf9', color: hasBatch ? '#1565c0' : '#999', fontWeight: hasBatch ? 700 : 400 }}>{hasBatch ? u.batch_code : '—'}</td>
                          <td style={{ padding: '3px 4px', color: hasBatch ? '#333' : '#999' }}>{hasBatch ? (batchStateLabels[u.batch_state] || u.batch_state) : '—'}</td>
                          <td style={{ padding: '3px 4px', color: hasBatch ? '#333' : '#999' }}>{hasBatch ? (u.batch_program ?? '—') : '—'}</td>
                          <td style={{ padding: '3px 4px', color: hasBatch ? '#333' : '#999' }}>{hasBatch ? (u.batch_stage ?? '—') : '—'}</td>
                          <td style={{ padding: '3px 4px', color: hasBatch ? '#333' : '#999' }}>{hasBatch ? fmtTime(u.batch_min_time) : '—'}</td>
                          <td style={{ padding: '3px 4px', color: hasBatch ? '#333' : '#999' }}>{hasBatch ? fmtTime(u.batch_max_time) : '—'}</td>
                          <td style={{ padding: '3px 4px', color: hasBatch ? '#333' : '#999' }}>{hasBatch ? fmtTime(u.batch_cal_time) : '—'}</td>
                          <td style={{ padding: '3px 4px' }}>
                            <button
                              onClick={() => handleUnitSelect(String(u.unit_id))}
                              style={{ padding: '3px 6px', borderRadius: 4, border: '1px solid #2196f3', background: selectedUnitId === String(u.unit_id) ? '#1565c0' : '#e3f2fd', color: selectedUnitId === String(u.unit_id) ? '#fff' : '#333', cursor: 'pointer', fontSize: 11 }}
                            >
                              Edit
                            </button>
                          </td>
                        </tr>
                      );
                    })}
                    {units.length === 0 && (
                      <tr><td colSpan={12} style={{ padding: 8, color: '#666', textAlign: 'center' }}>No units (PLC not connected?)</td></tr>
                    )}
                  </tbody>
                </table>
              </div>

              {/* Unit edit form */}
              {selectedUnitId !== '' && (
                <div style={{ border: '1px solid #90caf9', borderRadius: 6, padding: 10, background: '#e3f2fd', display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <div style={{ fontWeight: 700, fontSize: 14 }}>Edit Unit {selectedUnitId}</div>
                  <div style={{ display: 'flex', gap: 8, alignItems: 'flex-end' }}>
                    <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 12, width: 72 }}>
                      Batch ID
                      <input
                        type="number"
                        value={unitBatchEdit}
                        onChange={(e) => setUnitBatchEdit(Number(e.target.value) || 0)}
                        style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #90caf9', background: '#fff', fontSize: 12 }}
                      />
                    </label>
                    <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 12, width: 64 }}>
                      Location
                      <input
                        type="text"
                        inputMode="numeric"
                        pattern="[0-9]*"
                        value={unitLocationEdit}
                        onChange={(e) => { if (/^\d*$/.test(e.target.value)) setUnitLocationEdit(e.target.value); }}
                        style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #90caf9', background: '#fff', fontSize: 12 }}
                      />
                    </label>
                    <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 12, flex: 1 }}>
                      Status
                      <select
                        value={unitStatusEdit}
                        onChange={(e) => setUnitStatusEdit(Number(e.target.value))}
                        style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #90caf9', background: '#fff', fontSize: 12 }}
                      >
                        <option value={0}>NOT_USED (0)</option>
                        <option value={1}>USED (1)</option>
                      </select>
                    </label>
                    <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 12, flex: 1 }}>
                      Target
                      <select
                        value={unitTargetEdit}
                        onChange={(e) => setUnitTargetEdit(e.target.value)}
                        style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #90caf9', background: '#fff', fontSize: 12 }}
                      >
                        <option value="none">TO_NONE (0)</option>
                        <option value="to_loading">TO_LOADING (1)</option>
                        <option value="to_buffer">TO_BUFFER (2)</option>
                        <option value="to_process">TO_PROCESS (3)</option>
                        <option value="to_unload">TO_UNLOAD (4)</option>
                        <option value="to_avoid">TO_AVOID (5)</option>
                      </select>
                    </label>
                    <button
                      type="button"
                      disabled={unitSaving}
                      onClick={handleUnitSave}
                      style={{ padding: '6px 12px', borderRadius: 4, border: '1px solid #1565c0', background: '#1565c0', color: '#fff', fontWeight: 700, cursor: 'pointer', fontSize: 11, whiteSpace: 'nowrap' }}
                    >
                      {unitSaving ? '...' : 'Save to PLC'}
                    </button>
                  </div>
                </div>
              )}
            </div>
          </DraggablePanel>
        )}


        {showTasks && (
          <DraggablePanel title="Tasks" onClose={() => setShowTasks(false)} width={Math.max(800, transporters.length * 220)}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              {/* Manuaalinen tehtävän anto - nostimet rinnakkain */}
              <div style={{ display: 'flex', gap: 12 }}>
                {transporters.map((t) => {
                  const inputs = taskInputs[t.id] || { lift: '', sink: '' };
                  return (
                    <div key={t.id} style={{ 
                      flex: 1,
                      display: 'flex', 
                      flexDirection: 'column', 
                      gap: 6, 
                      padding: 8, 
                      border: '1px solid #ccc', 
                      borderRadius: 4,
                      background: '#f9f9f9'
                    }}>
                      <div style={{ fontWeight: 700, fontSize: 13, textAlign: 'center', marginBottom: 2 }}>Transporter {t.id}</div>
                      <div style={{ display: 'flex', gap: 4 }}>
                        <input
                          type="number"
                          value={inputs.lift}
                          onChange={(e) => setTaskInputs((prev) => ({ ...prev, [t.id]: { ...inputs, lift: e.target.value } }))}
                          placeholder="Lift"
                          style={{ flex: 1, padding: '4px 6px', borderRadius: 4, border: '1px solid #ccc', fontSize: 11 }}
                        />
                        <input
                          type="number"
                          value={inputs.sink}
                          onChange={(e) => setTaskInputs((prev) => ({ ...prev, [t.id]: { ...inputs, sink: e.target.value } }))}
                          placeholder="Sink"
                          style={{ flex: 1, padding: '4px 6px', borderRadius: 4, border: '1px solid #ccc', fontSize: 11 }}
                        />
                        <button
                          onClick={() => handleSendTask(t.id, inputs.lift, inputs.sink)}
                          style={{ padding: '4px 12px', borderRadius: 4, border: '1px solid #4caf50', background: '#e8f5e9', fontWeight: 600, cursor: 'pointer', fontSize: 11, whiteSpace: 'nowrap' }}
                        >
                          Set
                        </button>
                      </div>
                    </div>
                  );
                })}
              </div>

              {/* Jonossa olevat manuaaliset tehtävät */}
              {manualTasks.length > 0 && (
                <div style={{ 
                  padding: 8, 
                  border: '1px solid #ff9800', 
                  borderRadius: 4,
                  background: '#fff3e0'
                }}>
                  <div style={{ fontWeight: 700, fontSize: 12, marginBottom: 6, color: '#e65100' }}>
                    ⏳ Queued Manual Tasks ({manualTasks.length})
                  </div>
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                    {manualTasks.map((mt) => (
                      <div key={mt.id} style={{ 
                        display: 'flex', 
                        alignItems: 'center', 
                        justifyContent: 'space-between',
                        padding: '4px 8px', 
                        background: '#fff', 
                        borderRadius: 3, 
                        fontSize: 11,
                        border: '1px solid #ffcc80'
                      }}>
                        <span>
                          <strong>T{mt.transporter_id}</strong>
                          {' '}{mt.lift_station_id} → {mt.sink_station_id}
                          {' '}
                          <span style={{ color: mt.status === 'fitted' ? '#2e7d32' : '#bf360c', fontWeight: 600 }}>
                            [{mt.status}]
                          </span>
                          {mt.fitted_start_s != null && (
                            <span style={{ color: '#666', marginLeft: 6 }}>
                              start: {mt.fitted_start_s.toFixed(0)}s
                            </span>
                          )}
                        </span>
                        <button
                          onClick={() => handleCancelManualTask(mt.id)}
                          style={{ 
                            padding: '2px 8px', 
                            borderRadius: 3, 
                            border: '1px solid #ef5350', 
                            background: '#ffebee', 
                            color: '#c62828',
                            cursor: 'pointer', 
                            fontSize: 10, 
                            fontWeight: 600 
                          }}
                        >
                          ✕
                        </button>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {/* Suorituksessa oleva tehtävä */}
              <div style={{ display: 'flex', gap: 12 }}>
                {transporters.map((t) => {
                  const tState = transporterStates.find(s => s.id === t.id);
                  const state = tState ? tState.state : {};
                  const carriedBatch = batches.find((b) => b.location === t.id);
                  const batchId = state.pending_batch_id != null ? state.pending_batch_id : (carriedBatch ? carriedBatch.batch_id : null);
                  const hasTask = batchId != null || (state.lift_station_target != null && state.sink_station_target != null && state.operation !== 'idle');
                  
                  return (
                    <div key={`exec-${t.id}`} style={{ 
                      flex: 1,
                      padding: 8, 
                      border: '1px solid #2196f3', 
                      borderRadius: 4,
                      background: '#e3f2fd',
                      minHeight: 60
                    }}>
                      <div style={{ fontWeight: 700, fontSize: 12, marginBottom: 4, color: '#1565c0' }}>Executing Task</div>
                      {hasTask ? (
                        <div style={{ fontSize: 12 }}>
                          <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                            <span><strong>Batch:</strong> {batchId != null ? `B${batchId}` : '-'}</span>
                            <span><strong>Op:</strong> {state.operation || 'idle'}</span>
                          </div>
                          <div style={{ marginTop: 2 }}>
                            <strong>Route:</strong> {state.lift_station_target || '?'} → {state.sink_station_target || '?'}
                          </div>
                        </div>
                      ) : (
                        <div style={{ fontSize: 12, color: '#666', fontStyle: 'italic' }}>Idle</div>
                      )}
                    </div>
                  );
                })}
              </div>

              {/* Tehtävälistat nostimittain */}
              <div style={{ display: 'flex', gap: 12 }}>
                {transporters.map((t) => {
                  // Näytä vain tälle nostimelle jaetut tehtävät, järjestettynä alkuajan mukaan
                  const tasksForTransporter = transporterTasks
                    .filter(task => task.transporter_id === t.id)
                    .sort((a, b) => a.task_start_time - b.task_start_time);
                  return (
                    <div key={`tasks-${t.id}`} style={{ 
                      flex: 1,
                      border: '1px solid #ddd', 
                      borderRadius: 4,
                      padding: 8,
                      background: '#fff'
                    }}>
                      <div style={{ fontWeight: 700, fontSize: 12, marginBottom: 8, paddingBottom: 4 }}>
                        Transporter {t.id} - Tasks ({tasksForTransporter.length})
                      </div>
                      <div style={{ fontSize: 11, maxHeight: 400, overflowY: 'auto' }}>
                        {tasksForTransporter.length === 0 ? (
                          <div style={{ padding: '4px 0', fontStyle: 'italic', color: '#666' }}>No tasks</div>
                        ) : (
                          <table style={{ width: '100%', borderCollapse: 'collapse' }}>
                            <thead>
                              <tr style={{ borderBottom: '2px solid #ddd' }}>
                                <th style={{ textAlign: 'left', padding: '4px 4px', fontWeight: 600, color: '#666' }}>Unit</th>
                                <th style={{ textAlign: 'right', padding: '4px 4px', fontWeight: 600, color: '#666' }}>Lift</th>
                                <th style={{ textAlign: 'right', padding: '4px 4px', fontWeight: 600, color: '#666' }}>Sink</th>
                                <th style={{ textAlign: 'right', padding: '4px 4px', fontWeight: 600, color: '#666' }}>Start</th>
                              </tr>
                            </thead>
                            <tbody>
                              {tasksForTransporter.map((task, idx) => {
                                const now = elapsedMs;
                                const relStart = Math.round(task.task_start_time - now);
                                const sign = relStart >= 0 ? '+' : '';
                                const absSec = Math.abs(relStart);
                                const mm = String(Math.floor(absSec / 60)).padStart(2, '0');
                                const ss = String(absSec % 60).padStart(2, '0');
                                const startStr = `${sign}${mm}:${ss}`;
                                return (
                                  <tr key={idx} style={{ 
                                    background: task.is_manual ? '#fff3e0' : '#e8f5e9',
                                    borderBottom: idx < tasksForTransporter.length - 1 ? '1px solid #f0f0f0' : 'none'
                                  }}>
                                    <td style={{ textAlign: 'left', padding: '2px 4px', fontWeight: 600, fontSize: '10px' }}>
                                      U{task.unit_id}
                                    </td>
                                    <td style={{ textAlign: 'right', padding: '2px 4px', fontFamily: 'monospace', fontSize: '10px' }}>{task.lift_station_id}</td>
                                    <td style={{ textAlign: 'right', padding: '2px 4px', fontFamily: 'monospace', fontSize: '10px' }}>{task.sink_station_id}</td>
                                    <td style={{ textAlign: 'right', padding: '2px 4px', fontFamily: 'monospace', color: '#999', fontSize: '10px' }}>{startStr}</td>
                                  </tr>
                                );
                              })}
                            </tbody>
                          </table>
                        )}
                      </div>
                    </div>
                  );
                })}
              </div>

              {/* Jakamattomien tehtävien lista - lomakkeen alareunassa */}
              <div style={{ 
                border: '1px solid #ddd', 
                borderRadius: 4,
                padding: 8,
                background: '#fff'
              }}>
                <div style={{ fontWeight: 700, fontSize: 12, marginBottom: 8, paddingBottom: 4 }}>
                  Unassigned Tasks ({transporterTasks.filter(task => task.transporter_id === null).length})
                </div>
                <div style={{ fontSize: 11, maxHeight: 400, overflowY: 'auto' }}>
                  {transporterTasks.filter(task => task.transporter_id === null).length === 0 ? (
                    <div style={{ padding: '4px 0', fontStyle: 'italic', color: '#666' }}>No unassigned tasks</div>
                  ) : (
                    <table style={{ width: '100%', borderCollapse: 'collapse' }}>
                      <thead>
                        <tr style={{ borderBottom: '2px solid #ddd' }}>
                          <th style={{ textAlign: 'right', padding: '4px 4px', fontWeight: 600, color: '#666', width: '50px' }}>Lift</th>
                          <th style={{ textAlign: 'right', padding: '4px 4px', fontWeight: 600, color: '#666', width: '50px' }}>Sink</th>
                          <th style={{ textAlign: 'left', padding: '4px 8px', fontWeight: 600, color: '#666' }}>Task</th>
                        </tr>
                      </thead>
                      <tbody>
                        {transporterTasks
                          .filter(task => task.transporter_id === null)
                          .sort((a, b) => a.task_start_time - b.task_start_time)
                          .map((task, idx) => {
                            const now = elapsedMs;
                            const relStart = Math.round(task.task_start_time - now);
                            const relEnd = Math.round(task.task_finished_time - now);
                            const startStr = relStart > 0 ? `+${relStart}` : `${relStart}`;
                            const endStr = relEnd > 0 ? `+${relEnd}` : `${relEnd}`;
                            return (
                              <tr key={idx} style={{ 
                                borderBottom: idx < transporterTasks.filter(t => t.transporter_id === null).length - 1 ? '1px solid #f0f0f0' : 'none'
                              }}>
                                <td style={{ textAlign: 'right', padding: '2px 4px', fontFamily: 'monospace', color: '#999', fontSize: '10px' }}>{startStr}</td>
                                <td style={{ textAlign: 'right', padding: '2px 4px', fontFamily: 'monospace', color: '#999', fontSize: '10px' }}>{endStr}</td>
                                <td style={{ textAlign: 'left', padding: '2px 8px' }}>
                                  <span style={{ fontWeight: 600 }}>B{task.batch_id}</span>
                                  {' - '}
                                  <span>{task.lift_station_id} → {task.sink_station_id}</span>
                                </td>
                              </tr>
                            );
                          })
                        }
                      </tbody>
                    </table>
                  )}
                </div>
              </div>
            </div>
          </DraggablePanel>
        )}
    </div>
  );
}
