import React, { useState } from 'react';
import * as d3 from 'd3';
import useLayoutScales from './hooks/useLayoutScales';
import ProductionBar from './subcomponents/ProductionBar';
import Station from './subcomponents/Station';
import Tank from './subcomponents/Tank';
import Transporter2D from './subcomponents/Transporter2D';
import Transporter3D from './subcomponents/Transporter3D';

/**
 * StationLayout - Main component for visualizing treatment line layout
 * 
 * @param {Object} props
 * @param {Object} props.config - Layout configuration (from layout_config.json)
 * @param {Array} props.stations - Station array (from stations.json)
 * @param {Array} props.tanks - Tank array (from tanks.json)
 * @param {Array} props.transporters - Transporter array (from transporters.json)
 * @param {Array} props.transporterStates - Current transporter states (from API)
 * @param {Array} props.batches - Current batch array (from API)
 * @param {Array} props.units - Current unit array (from API)
 * @param {number} props.currentSimMs - Current simulation time in milliseconds
 * @param {Object} [props.avoidStatuses={}] - Station avoid statuses
 * @param {Function} [props.onAvoidStatusChange] - Avoid status change handler
 * @param {Function} [props.setDebugTransporterId] - Debug transporter click handler
 * @param {number} [props.avgCycleSec=0] - Average cycle time in seconds
 * @param {Object} [props.productionStats={}] - Production statistics
 */
function StationLayout({
  config,
  stations,
  tanks = [],
  transporters,
  transporterStates,
  batches,
  units = [],
  currentSimMs,
  avoidStatuses = {},
  onAvoidStatusChange,
  setDebugTransporterId = () => {},
  avgCycleSec = 0,
  productionStats = {}
}) {
  // Use layout scales hook
  const {
    dimensions,
    containerRef,
    xScale,
    yScale,
    stationWidthMM,
    stationHeightMM,
    showAvoidCheckboxes,
    showUtilizationPie,
    showDriveLimits
  } = useLayoutScales({ config, stations, transporterStates });

  // Early return if no data or scales
  if (!config || !stations.length || !transporters.length || !xScale || !yScale) {
    return <div ref={containerRef} style={{ width: '100%', height: '100%' }} />;
  }

  const { width, height } = dimensions;

  // Group stations for cross-transporter connections
  const stationsByGroup = {};
  stations.forEach(station => {
    if (station.operation === 10) {
      if (!stationsByGroup[station.group]) {
        stationsByGroup[station.group] = [];
      }
      stationsByGroup[station.group].push(station);
    }
  });

  // View mode toggle for tank visualization
  const [viewMode, setViewMode] = useState('production');

  return (
    <div ref={containerRef} style={{ width: '100%', height: '100%', perspective: '1000px' }}>
      <svg width={width} height={height} style={{ background: '#ffffff', transformStyle: 'preserve-3d' }}>
        {/* SVG Filters */}
        <defs>
          <filter id="station-shadow" x="-20%" y="-20%" width="140%" height="140%">
            <feDropShadow dx="0" dy="0" stdDeviation="4" floodColor="rgba(0,0,0,0.18)" />
          </filter>
          <filter id="transporter-shadow" x="-20%" y="-20%" width="140%" height="140%">
            <feDropShadow dx="0" dy="0" stdDeviation="6" floodColor="rgba(0,0,0,0.22)" />
          </filter>
          <filter id="tank-shadow" x="-20%" y="-20%" width="140%" height="140%">
            <feDropShadow dx="0" dy="0" stdDeviation="3" floodColor="rgba(0,102,204,0.15)" />
          </filter>
          
          {/* Liquid surface gradient - corner to corner shine effect */}
          <linearGradient id="liquid-shine" x1="0%" y1="0%" x2="100%" y2="100%">
            <stop offset="0%" stopColor="rgba(255,255,255,0.3)" />
            <stop offset="50%" stopColor="rgba(255,255,255,0)" />
            <stop offset="100%" stopColor="rgba(0,0,0,0.15)" />
          </linearGradient>
        </defs>

        {/* Production progress bar */}
        <ProductionBar
          width={width}
          avgCycleSec={avgCycleSec}
          productionStats={productionStats}
        />

        {/* Cross-transporter connection lines */}
        {config['cross-transporters']?.showConnections && Object.values(stationsByGroup).map((groupStations, idx) => {
          if (groupStations.length === 2) {
            const [s1, s2] = groupStations;
            return (
              <line
                key={`cross-${idx}`}
                x1={xScale(s1.x_position)}
                y1={yScale(s1.y_position)}
                x2={xScale(s2.x_position)}
                y2={yScale(s2.y_position)}
                stroke={config['cross-transporters'].lineColor}
                strokeWidth={config['cross-transporters'].lineWidth}
                strokeDasharray={config['cross-transporters'].lineStyle === "dashed" ? "10,5" : "none"}
              />
            );
          }
          return null;
        })}

        {/* Toggle button for view mode */}
        <foreignObject x={width - 180} y={10} width="170" height="40">
          <button
            onClick={() => setViewMode(m => m === 'production' ? 'process' : 'production')}
            style={{
              padding: '8px 16px',
              fontSize: '12px',
              cursor: 'pointer',
              background: '#0066cc',
              color: 'white',
              border: 'none',
              borderRadius: '4px'
            }}
          >
            View: {viewMode}
          </button>
        </foreignObject>

        {/* Tanks from tanks.json */}
        {tanks.map(tank => (
          <Tank
            key={`tank-${tank.tank_id}`}
            tank={tank}
            config={config}
            xScale={xScale}
            yScale={yScale}
            viewMode={viewMode}
            showDimensions={false}
            showName={true}
            onClick={(t) => console.log('Tank clicked:', t)}
          />
        ))}

        {/* Stations - only visible in production mode */}
        {viewMode === 'production' && stations.map(station => {
          const batch = Array.isArray(batches)
            ? batches.find(b => b.location === station.number)
            : null;
          const unit = batch && Array.isArray(units)
            ? units.find(u => u.batch_id === batch.batch_id)
            : (Array.isArray(units) ? units.find(u => u.location === station.number) : null);

          return (
            <Station
              key={`station-${station.number}`}
              station={station}
              batch={batch}
              unit={unit || null}
              currentSimMs={currentSimMs}
              config={config}
              xScale={xScale}
              yScale={yScale}
              stationWidthMM={stationWidthMM}
              stationHeightMM={stationHeightMM}
              avoidStatus={avoidStatuses[station.number] || 0}
              onAvoidStatusChange={onAvoidStatusChange}
              showAvoidCheckboxes={showAvoidCheckboxes}
            />
          );
        })}

        {/* 2D Transporters */}
        {transporters
          .filter(t => t.model === "2D")
          .map(transporter => {
            const transporterState = transporterStates.find(ts => ts.id === transporter.id);
            if (!transporterState) return null;

            const batch = Array.isArray(batches)
              ? batches.find(b => b.location === transporter.id)
              : null;

            const unit = batch && Array.isArray(units)
              ? units.find(u => u.batch_id === batch.batch_id)
              : (Array.isArray(units) ? units.find(u => u.location === transporter.id) : null);

            return (
              <Transporter2D
                key={`transporter-2d-${transporter.id}`}
                transporter={transporter}
                transporterState={transporterState}
                batch={batch}
                unit={unit || null}
                currentSimMs={currentSimMs}
                config={config}
                xScale={xScale}
                yScale={yScale}
                stations={stations}
                stationWidthMM={stationWidthMM}
                stationHeightMM={stationHeightMM}
                showUtilizationPie={showUtilizationPie}
                showDriveLimits={showDriveLimits}
                onTransporterClick={setDebugTransporterId}
                viewMode={viewMode}
              />
            );
          })}

        {/* 3D Transporters */}
        {transporters
          .filter(t => t.model === "3D")
          .map(transporter => {
            const transporterState = transporterStates.find(ts => ts.id === transporter.id);
            if (!transporterState) return null;

            const batch = Array.isArray(batches)
              ? batches.find(b => b.location === transporter.id)
              : null;

            const unit = batch && Array.isArray(units)
              ? units.find(u => u.batch_id === batch.batch_id)
              : (Array.isArray(units) ? units.find(u => u.location === transporter.id) : null);

            return (
              <Transporter3D
                key={`transporter-3d-${transporter.id}`}
                transporter={transporter}
                transporterState={transporterState}
                batch={batch}
                unit={unit || null}
                currentSimMs={currentSimMs}
                config={config}
                xScale={xScale}
                yScale={yScale}
                stations={stations}
                stationWidthMM={stationWidthMM}
                stationHeightMM={stationHeightMM}
                showUtilizationPie={showUtilizationPie}
                showDriveLimits={showDriveLimits}
                onTransporterClick={setDebugTransporterId}
              />
            );
          })}
      </svg>
    </div>
  );
}

export default StationLayout;
