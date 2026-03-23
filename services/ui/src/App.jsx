
import React, { useEffect, useState, useRef, useMemo } from "react";
import { api } from './api/client';
import * as d3 from "d3";

// Import modular StationLayout component
import StationLayout from './components/StationLayout';
import DraggablePanel from './components/StationLayout/helpers/DraggablePanel';


// Load color palette at startup (runtime, no rebuild needed)
import { loadPalette } from './hooks/useColorPalette';
import Toolbar from './components/Toolbar';
import CustomerPanel from './components/panels/CustomerPanel';
import ConfigPanel from './components/panels/ConfigPanel';
import ProductionPanel from './components/panels/ProductionPanel';
import UnitsPanel from './components/panels/UnitsPanel';
import TasksPanel from './components/panels/TasksPanel';

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
        const res = await api.get('/api/plc/status');
        if (res.ok) {
          const data = await res.json();
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
        const [configRes, transportersRes, stationsRes, tanksRes] = await Promise.all([
          api.get('/api/config/layout_config.json'),
          api.get('/api/config/transporters.json'),
          api.get('/api/config/stations.json'),
          api.get('/api/config/tanks.json')
        ]);

        // If any config fetch fails (no customer selected), show waiting state
        if (!configRes.ok || !stationsRes.ok || !transportersRes.ok) {
          console.log("No configuration loaded — waiting for customer/plant selection");
          setLoadError(null);  // Not an error, just no selection yet
          return;
        }

        const configData = await configRes.json();
        const transportersData = await transportersRes.json();
        const stationsData = await stationsRes.json();
        const tanksData = tanksRes.ok ? await tanksRes.json() : { tanks: [] };
        
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
          const resetRes = await api.post(`/api/reset-transporters`);
          const resetData = await resetRes.json();
          if (resetData.success && resetData.transporters) {
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
      const res = await api.get('/api/transporter-tasks');
      const data = await res.json();
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
        const [tasksRes, manualRes] = await Promise.all([
          api.get('/api/transporter-tasks'),
          api.get('/api/manual-tasks')
        ]);
        if (cancelled) return;
        const tasksData = await tasksRes.json();
        const manualData = await manualRes.json();
        if (tasksData && Array.isArray(tasksData.tasks)) {
          setTransporterTasks(tasksData.tasks);
        }
        if (manualData && Array.isArray(manualData.tasks)) {
          setManualTasks(manualData.tasks);
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
        const res = await api.get('/api/scheduler/state');
        const data = await res.json();
        if (cancelled) return;
        if (data.state && typeof data.state.avgDepartureIntervalSec === 'number') {
          setAvgCycleSec(data.state.avgDepartureIntervalSec);
        }
        if (data.productionStats) {
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
        const res = await api.get('/api/customers');
        const data = await res.json();
        if (data.success) {
          setCustomers(data.customers);
        }
      } catch (error) {
        console.error('Failed to load customers:', error);
        setCustomerError('Failed to load customers');
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
        const res = await api.get(`/api/customers/${encodeURIComponent(selectedCustomer)}/plants`);
        const data = await res.json();
        if (data.success) {
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
        const res = await api.get(`/api/customers/${encodeURIComponent(selectedCustomer)}/plants/${encodeURIComponent(selectedPlant)}/simulation-purpose`);
        const data = await res.json();
        if (data.success) {
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
        const res = await api.get(`/api/customers/${encodeURIComponent(selectedCustomer)}/plants/${encodeURIComponent(selectedPlant)}/status`);
        const data = await res.json();
        if (data.success) {
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
        const res = await api.get('/api/transporter-states');
        const data = await res.json();
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
      const res = await api.get(`/api/sim/time`);
      const data = await res.json();
      if (typeof data.time === 'number') {
        const backendRunning = typeof data.running === 'boolean' ? data.running : isRunning;
        setElapsedMs((prev) => {
          if (backendRunning) return data.time;
          // When paused, never jump forward; keep the smaller of UI and backend
          return Math.min(prev, data.time);
        });
      }
      if (typeof data.speedMultiplier === 'number') {
        setSpeed(data.speedMultiplier);
      }
      if (typeof data.running === 'boolean') {
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
    const res = await api.get(url, { cache: 'no-store' }); // url voi olla jo suhteellinen
    if (!res.ok) throw new Error('Failed to load batches');
    const data = await res.json();
    if (data && Array.isArray(data.batches)) {
      setBatches(data.batches);
    }
    return data;
  };

  const fetchUnitsFromApi = async () => {
    try {
      const res = await api.get(`/api/units?ts=${Date.now()}`, { cache: 'no-store' });
      if (!res.ok) throw new Error('Failed to load units');
      const data = await res.json();
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
      const res = await api.get(`/api/avoid-statuses`);
      if (!res.ok) throw new Error('Failed to load avoid statuses');
      const data = await res.json();
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
      const res = await api.get(`/api/plant-setups`);
      if (!res.ok) throw new Error('Failed to load plant setups');
      const data = await res.json();
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
      const res = await api.get(`/api/production-setup`);
      const data = await res.json();
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
      const res = await api.get(`/api/treatment-programs`);
      if (!res.ok) throw new Error('Failed to load treatment programs');
      const data = await res.json();
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
      const res = await api.post(`/api/avoid-statuses`, { stationNumber: String(stationNumber), avoid_status: newStatus });
      if (!res.ok) throw new Error('Failed to update avoid status');
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
      const res = await api.put(`/api/units/${uid}`, {
          batch_id: Number(unitBatchEdit) || 0,
          location: newLoc,
          status: Number(unitStatusEdit) || 0,
          target: unitTargetEdit || 'none'
        });
      if (!res.ok) {
        const err = await res.json().catch(() => ({}));
        throw new Error(err.error || 'Unit save failed');
      }
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
      const res = await api.delete(`/api/batches/${batchId}`);
      if (!res.ok) {
        const err = await res.json().catch(() => ({}));
        throw new Error(err.error || 'Delete failed');
      }
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
      const res = await api.request(url, { method, body: payload });
      if (!res.ok) {
        const err = await res.json().catch(() => ({}));
        throw new Error(err.error || 'Save failed');
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
      const res = await api.post(`/api/production`, { pairs });
      const data = await res.json();
      if (!res.ok || !data.success) {
        throw new Error(data.error || 'Failed to create production files');
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
      const res = await api.post(`/api/production-setup`, payload);
      const data = await res.json();
      console.log('Production setup response:', data);
      if (!res.ok || !data.success) {
        throw new Error(data.error || 'Failed to save production setup');
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
        const res = await api.post('/api/sim/start');
        const data = await res.json();
        if (typeof data.time === 'number') setElapsedMs(data.time);
        if (typeof data.speedMultiplier === 'number') setSpeed(data.speedMultiplier);
        if (typeof data.running === 'boolean') {
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
    setElapsedMs(0);
    setAvgCycleSec(0);
    setProductionStartTime(null);
    setProductionDuration(0);
    setShowCustomer(false);
    lastTickRef.current = null;

    try {
      console.log(`[RESET] Uploading config: ${selectedCustomer}/${selectedPlant}`);
      const response = await api.post('/api/reset', { customer: selectedCustomer, plant: selectedPlant });

      const result = await response.json();

      if (result.success) {
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
      const res = await api.post(`/api/command/move`, { transporterId, lift_station: liftNumber, sink_station: sinkNumber });
      const data = await res.json();
      if (data.queued) {
        console.log(`Manual task queued: T${transporterId} ${liftNumber}→${sinkNumber} (id=${data.taskId})`);
        // Päivitä manual tasks heti
        const manualRes = await api.get('/api/manual-tasks');
        const manualData = await manualRes.json();
        if (manualData && Array.isArray(manualData.tasks)) {
          setManualTasks(manualData.tasks);
        }
      }

      if (!isRunning) {
        const startRes = await api.post(`/api/sim/start`);
        const startData = await startRes.json();
        if (typeof startData.time === 'number') setElapsedMs(startData.time);
        if (typeof startData.running === 'boolean') {
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
        <Toolbar
          plcStatus={plcStatus} plcToggling={plcToggling}
          setPlcToggling={setPlcToggling} setPlcStatus={setPlcStatus}
          selectedCustomer={selectedCustomer} selectedPlant={selectedPlant}
          showCustomer={showCustomer} showConfig={false}
          showProduction={false} showBatches={false} showTasks={false}
          setShowCustomer={setShowCustomer}
          setShowProduction={() => {}} setShowBatches={() => {}} setShowTasks={() => {}}
          onConfigClick={() => {}}
          isResetting={isResetting}
          productionStartTime={null} productionDuration={0}
          handleStart={() => {}} handleReset={handleReset}
          isConfigLoaded={false}
        />
        <div style={{ flex: 1, overflow: 'hidden', padding: '16px' }} />
        {showCustomer && (
          <CustomerPanel
            onClose={() => { setShowCustomer(false); setCustomerError(''); }}
            customerError={customerError} setCustomerError={setCustomerError}
            selectedCustomer={selectedCustomer} setSelectedCustomer={setSelectedCustomer}
            customers={customers} setCustomers={setCustomers}
            selectedPlant={selectedPlant} setSelectedPlant={setSelectedPlant}
            customerPlants={customerPlants} setCustomerPlants={setCustomerPlants}
            creatingCustomer={creatingCustomer} setCreatingCustomer={setCreatingCustomer}
            newCustomerName={newCustomerName} setNewCustomerName={setNewCustomerName}
            creatingPlant={creatingPlant} setCreatingPlant={setCreatingPlant}
            newPlantName={newPlantName} setNewPlantName={setNewPlantName}
            plantStatus={plantStatus} setPlantStatus={setPlantStatus}
            simPurpose={simPurpose} setSimPurpose={setSimPurpose}
            simPurposeForm={simPurposeForm} setSimPurposeForm={setSimPurposeForm}
            selectedTemplate={selectedTemplate} setSelectedTemplate={setSelectedTemplate}
            plantSetups={plantSetups}
            copyingTemplate={copyingTemplate} setCopyingTemplate={setCopyingTemplate}
          />
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
      <Toolbar
        plcStatus={plcStatus} plcToggling={plcToggling}
        setPlcToggling={setPlcToggling} setPlcStatus={setPlcStatus}
        selectedCustomer={selectedCustomer} selectedPlant={selectedPlant}
        plantStatus={plantStatus}
        showCustomer={showCustomer} showConfig={showConfig}
        showProduction={showProduction} showBatches={showBatches} showTasks={showTasks}
        setShowCustomer={setShowCustomer}
        setShowProduction={setShowProduction}
        setShowBatches={setShowBatches} setShowTasks={setShowTasks}
        onConfigClick={() => {
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
        isResetting={isResetting}
        productionStartTime={productionStartTime} productionDuration={productionDuration}
        handleStart={handleStart} handleReset={handleReset}
        isConfigLoaded={true}
      />
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



          {showConfig && configForm && (
            <ConfigPanel
              onClose={() => { setShowConfig(false); setConfigError(''); }}
              configForm={configForm} setConfigForm={setConfigForm}
              configError={configError} setConfigError={setConfigError}
              configSaving={configSaving} setConfigSaving={setConfigSaving}
              config={config} setConfig={setConfig}
              setShowConfig={setShowConfig}
            />
          )}

          {showCustomer && (
            <CustomerPanel
              onClose={() => { setShowCustomer(false); setCustomerError(''); }}
              customerError={customerError} setCustomerError={setCustomerError}
              selectedCustomer={selectedCustomer} setSelectedCustomer={setSelectedCustomer}
              customers={customers} setCustomers={setCustomers}
              selectedPlant={selectedPlant} setSelectedPlant={setSelectedPlant}
              customerPlants={customerPlants} setCustomerPlants={setCustomerPlants}
              creatingCustomer={creatingCustomer} setCreatingCustomer={setCreatingCustomer}
              newCustomerName={newCustomerName} setNewCustomerName={setNewCustomerName}
              creatingPlant={creatingPlant} setCreatingPlant={setCreatingPlant}
              newPlantName={newPlantName} setNewPlantName={setNewPlantName}
              plantStatus={plantStatus} setPlantStatus={setPlantStatus}
              simPurpose={simPurpose} setSimPurpose={setSimPurpose}
              simPurposeForm={simPurposeForm} setSimPurposeForm={setSimPurposeForm}
              selectedTemplate={selectedTemplate} setSelectedTemplate={setSelectedTemplate}
              plantSetups={plantSetups}
              copyingTemplate={copyingTemplate} setCopyingTemplate={setCopyingTemplate}
            />
          )}

          {showProduction && (
            <ProductionPanel
              onClose={() => { setShowProduction(false); setProductionError(''); }}
              productionError={productionError}
              productionPrograms={productionPrograms}
              productionProgramDetails={productionProgramDetails}
              productionSetup={productionSetup} setProductionSetup={setProductionSetup}
              productionRows={productionRows}
              stations={stations}
              productionSaving={productionSaving}
              productionSetupSaving={productionSetupSaving}
              handleProductionRowChange={handleProductionRowChange}
              handleRemoveProductionRow={handleRemoveProductionRow}
              handleAddProductionRow={handleAddProductionRow}
              handleSaveProductionSetup={handleSaveProductionSetup}
              handleCreateProduction={handleCreateProduction}
              fetchBatchesFromApi={fetchBatchesFromApi}
              fetchUnitsFromApi={fetchUnitsFromApi}
              setShowProduction={setShowProduction}
            />
          )}

        {showBatches && (
          <UnitsPanel
            onClose={() => { setShowBatches(false); resetBatchForm(); }}
            batchError={batchError}
            units={units}
            selectedUnitId={selectedUnitId}
            unitBatchEdit={unitBatchEdit} setUnitBatchEdit={setUnitBatchEdit}
            unitLocationEdit={unitLocationEdit} setUnitLocationEdit={setUnitLocationEdit}
            unitStatusEdit={unitStatusEdit} setUnitStatusEdit={setUnitStatusEdit}
            unitTargetEdit={unitTargetEdit} setUnitTargetEdit={setUnitTargetEdit}
            unitSaving={unitSaving}
            handleUnitSelect={handleUnitSelect}
            handleUnitSave={handleUnitSave}
          />
        )}


        {showTasks && (
          <TasksPanel
            onClose={() => setShowTasks(false)}
            transporters={transporters}
            taskInputs={taskInputs} setTaskInputs={setTaskInputs}
            manualTasks={manualTasks}
            transporterStates={transporterStates}
            batches={batches}
            transporterTasks={transporterTasks}
            elapsedMs={elapsedMs}
            handleSendTask={handleSendTask}
            handleCancelManualTask={handleCancelManualTask}
          />
        )}
    </div>
  );
}
