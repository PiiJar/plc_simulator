import React from 'react';
import MiniPieChart from '../helpers/MiniPieChart';

/**
 * 2D Transporter component - base component used also by 3D Transporter
 * 
 * @param {Object} props
 * @param {Object} props.transporter - Transporter configuration
 * @param {Object} props.transporterState - Current transporter state
 * @param {Object} props.batch - Batch on transporter (or null)
 * @param {number} props.currentSimMs - Current simulation time in ms
 * @param {Object} props.config - Layout configuration
 * @param {Function} props.xScale - X coordinate scale
 * @param {Function} props.yScale - Y coordinate scale
 * @param {Array} props.stations - Station array (for reference)
 * @param {number} props.stationWidthMM - Station width in mm
 * @param {number} props.stationHeightMM - Station height in mm
 * @param {boolean} props.showUtilizationPie - Show utilization pie chart
 * @param {boolean} props.showDriveLimits - Show drive limits
 * @param {Function} props.onTransporterClick - Click handler
 * @param {number} [props.yPositionOverride] - Override Y position (for 3D use)
 * @param {string} [props.viewMode] - 'production' (X-Y top-down) or 'process' (X-Z side view)
 */
function Transporter2D({
  transporter,
  transporterState,
  batch,
  unit,
  currentSimMs,
  config,
  xScale,
  yScale,
  stations,
  stationWidthMM,
  stationHeightMM,
  showUtilizationPie = true,
  showDriveLimits = true,
  onTransporterClick,
  yPositionOverride,
  viewMode = 'production'
}) {
  if (!transporterState) return null;

  // Find the station to get y_position (line position)
  const currentStationNum = transporterState.state.current_station;
  const currentStation = stations.find(s => s.number === currentStationNum);

  // Use x_position from state and y_position from station (or override for 3D)
  const currentX = transporterState.state.x_position;
  const currentY = yPositionOverride !== undefined 
    ? yPositionOverride 
    : (currentStation ? currentStation.y_position : 0);

  // Transporter dimensions from config
  const avoidDistance = transporter.physics_2D?.avoid_distance_mm || 1000;
  const widthScaleFactor = config.transporters?.widthScaleFactor || 0.8;
  const transporterWidthMM = avoidDistance * widthScaleFactor;
  const transporterHeightMM = config.transporters?.heightMM || 1200;

  // Process view: fixed Z-depth 300mm
  const processViewDepthMM = 300;  // Hoist depth in Z direction (side view)

  // Calculate position and size based on viewMode
  const isProcessView = viewMode === 'process';
  
  // Width stays same in both modes (X direction)
  const transporterWidth = Math.abs(xScale(transporterWidthMM) - xScale(0));
  const transporterX = xScale(currentX) - transporterWidth / 2;
  
  // Height and Y position differ based on view mode
  const displayHeightMM = isProcessView ? processViewDepthMM : transporterHeightMM;
  const transporterHeight = Math.abs(yScale(0) - yScale(displayHeightMM));
  
  // In process view, position at fixed Y (above tanks in SVG coordinates)
  // In production view, use normal yScale positioning
  let transporterY;
  if (isProcessView) {
    // Fixed position at top of SVG area (e.g. 60px from top)
    transporterY = 60;
  } else {
    transporterY = yScale(currentY) - Math.abs(yScale(0) - yScale(transporterHeightMM)) / 2;
  }

  // Z bar on right edge — z=0 is bottom (sunk), z=z_total is top (lifted)
  const zTotal = transporter.physics_2D?.z_total_distance_mm || 1;
  const zPos = Math.max(0, Math.min(zTotal, transporterState.state.z_position || 0));
  const zFrac = Math.max(0, Math.min(1, zPos / zTotal));
  const barWidth = Math.max(6, Math.min(14, transporterWidth * 0.12));
  const barHeight = transporterHeight * zFrac;
  const barX = transporterX + transporterWidth - barWidth - 4;
  const barY = transporterY + transporterHeight - barHeight;

  // Drive limits
  const xMin = transporterState.state.x_min_drive_limit || 0;
  const xMax = transporterState.state.x_max_drive_limit || 0;
  const hasDriveLimits = xMin !== 0 && xMax !== 0;
  // Odd ID = top line, Even ID = bottom line
  const idStr = String(transporter.id);
  const idNum = parseInt(idStr.replace(/\D/g, ''), 10) || 0;
  const yDriveLine = (idNum % 2 === 1) ? transporterY : (transporterY + transporterHeight);

  // Unit/batch geometry for transporter (matches Station.jsx unit box style)
  const hasUnit = Boolean(unit);
  const unitColor = (hasUnit && unit.status === 'not_used') ? '#616161' : '#1565c0';
  const wStation = Math.abs(xScale(stationWidthMM) - xScale(0));
  const hStation = Math.abs(yScale(0) - yScale(stationHeightMM));
  const stationXAligned = xScale(currentX) - wStation / 2;
  const stationYAligned = yScale(currentY) - hStation / 2;

  // Unit box dimensions — same proportions as Station.jsx
  const unitBoxWidth = Math.min(82, wStation * 0.52);
  const unitBatchBarWidth = Math.min(68, unitBoxWidth - 8);
  const unitBoxX = stationXAligned + (wStation - unitBoxWidth) / 2;
  const unitBatchBarX = stationXAligned + (wStation - unitBatchBarWidth) / 2;
  const unitBoxY = stationYAligned + 24;
  const unitBoxBottom = stationYAligned + hStation - 10;
  const unitBoxHeight = Math.max(20, unitBoxBottom - unitBoxY);
  const unitLabelHeight = 14;
  const unitBatchBarY = unitBoxY + unitLabelHeight + 2;
  const unitBatchBarBottom = unitBoxBottom - 3;
  const unitBatchBarHeight = Math.max(12, unitBatchBarBottom - unitBatchBarY);

  // DEBUG: render batch debug info on transporter
  const renderBatchDebug = () => {
    const cal = batch ? Number(batch.calc_time_s) : -1;
    const st = batch ? Number(batch.start_time) : -1;
    const el = batch ? Math.max(0, currentSimMs - st) : -1;
    const gr = cal > 0 ? Math.min(1, el / cal) : 0;
    return (
      <g>
        <text x={transporterX + 2} y={transporterY + transporterHeight + 14} fontSize={9} fill="#c00" fontWeight="700">
          {`csm=${currentSimMs} cal=${cal} st=${st}`}
        </text>
        <text x={transporterX + 2} y={transporterY + transporterHeight + 24} fontSize={9} fill="#c00" fontWeight="700">
          {`el=${el} gr=${gr.toFixed(3)} b=${batch ? 'Y' : 'N'} u=${hasUnit ? 'Y' : 'N'}`}
        </text>
      </g>
    );
  };

  // Render batch on transporter
  const renderBatchOnTransporter = () => {
    if (!batch) return null;

    // If unit is present, batch bar is inset inside unit box; otherwise use old dimensions
    const batchBarWidth = hasUnit ? unitBatchBarWidth : Math.min(60, wStation * 0.35);
    const batchBarX = hasUnit ? unitBatchBarX : (stationXAligned + (wStation - batchBarWidth) / 2);
    const batchBarY = hasUnit ? unitBatchBarY : (stationYAligned + 28);
    const batchBarBottom2 = hasUnit ? unitBatchBarBottom : (stationYAligned + hStation - 10);
    const batchBarHeight = Math.max(12, batchBarBottom2 - batchBarY);

    if (batch.stage === 90) {
      return (
        <g>
          <rect
            x={batchBarX}
            y={batchBarY}
            width={batchBarWidth}
            height={batchBarHeight}
            fill="#2196f3"
            stroke="#1976d2"
            strokeWidth={0.6}
            rx={1}
          />
          <text
            x={0}
            y={0}
            textAnchor="middle"
            dominantBaseline="middle"
            fontSize={11}
            fill="#444"
            transform={`translate(${batchBarX + batchBarWidth / 2}, ${batchBarY + 10}) rotate(-90)`}
          >
            {batch.batch_id}
          </text>
        </g>
      );
    }

    const minTime = Number(batch.min_time_s) || 0;
    const calcTime = Number(batch.calc_time_s) || minTime;
    const maxTime = Number(batch.max_time_s) || 0;
    const overWindow = maxTime > 0 ? maxTime * 0.2 : 0;
    const startSec = Number(batch.start_time) || 0;
    const elapsedSec = Math.max(0, currentSimMs - startSec);

    const greenRatio = calcTime > 0 ? Math.min(1, elapsedSec / calcTime) : 0;
    let yellowRatio = 0;
    if (elapsedSec > calcTime && maxTime > calcTime) {
      yellowRatio = Math.min(1, (elapsedSec - calcTime) / (maxTime - calcTime));
    } else if (elapsedSec >= maxTime && maxTime > calcTime) {
      yellowRatio = 1;
    }
    let redRatio = 0;
    if (elapsedSec > maxTime && overWindow > 0) {
      redRatio = Math.min(1, (elapsedSec - maxTime) / overWindow);
    } else if (elapsedSec > maxTime && overWindow === 0) {
      redRatio = 1;
    }

    const greenH = batchBarHeight * greenRatio;
    const yellowH = batchBarHeight * yellowRatio;
    const redH = batchBarHeight * redRatio;

    return (
      <g>
        <rect
          x={batchBarX}
          y={batchBarY}
          width={batchBarWidth}
          height={batchBarHeight}
          fill="#f2f2f2"
          stroke="#888"
          strokeWidth={0.6}
          rx={1}
        />
        {greenH > 0 && (
          <rect
            x={batchBarX}
            y={batchBarY + (batchBarHeight - greenH)}
            width={batchBarWidth}
            height={greenH}
            fill="#444444"
            stroke="#222222"
            strokeWidth={0.6}
            rx={1}
          />
        )}
        {yellowH > 0 && (
          <rect
            x={batchBarX}
            y={batchBarY + (batchBarHeight - yellowH)}
            width={batchBarWidth}
            height={yellowH}
            fill="#4caf50"
            stroke="#2e7d32"
            strokeWidth={0.6}
            rx={1}
          />
        )}
        {redH > 0 && (
          <rect
            x={batchBarX}
            y={batchBarY + (batchBarHeight - redH)}
            width={batchBarWidth}
            height={redH}
            fill="#e53935"
            stroke="#b71c1c"
            strokeWidth={0.6}
            rx={1}
          />
        )}
        <text
          x={0}
          y={0}
          textAnchor="middle"
          dominantBaseline="middle"
          fontSize={11}
          fill="#444"
          transform={`translate(${batchBarX + batchBarWidth / 2}, ${batchBarY + 10}) rotate(-90)`}
        >
          {batch.batch_id}
        </text>
      </g>
    );
  };

  // Dripping timer visualization
  const renderDripTimer = () => {
    if (transporterState.state.z_stage !== 'drip' || barHeight <= 0) return null;

    const remainingTime = transporterState.state.z_timer || 0;
    const station = stations.find(s => s.number === transporterState.state.current_station);
    const dripTime = station && Number.isFinite(station.dropping_time) ? station.dropping_time : 5;
    const progress = dripTime > 0 ? Math.max(0, Math.min(1, 1 - (remainingTime / dripTime))) : 1;
    const blueBarHeight = Math.max(4, barWidth * 0.8);
    const blueBarY = barY + (barHeight - blueBarHeight) * progress;

    return (
      <rect
        x={barX}
        y={blueBarY}
        width={barWidth}
        height={blueBarHeight}
        fill="rgba(33, 150, 243, 0.9)"
        stroke="#1976d2"
        strokeWidth={1}
        rx={1}
      />
    );
  };

  return (
    <g
      onClick={(e) => {
        e.stopPropagation();
        if (onTransporterClick) onTransporterClick(transporter.id);
      }}
      style={{ cursor: 'pointer' }}
    >
      {/* Drive limits line - only in production view */}
      {!isProcessView && showDriveLimits && hasDriveLimits && (
        <line
          x1={xScale(xMin)}
          y1={yDriveLine}
          x2={xScale(xMax)}
          y2={yDriveLine}
          stroke="#ff9800"
          strokeWidth={3}
          strokeOpacity={0.6}
          strokeDasharray="8,4"
        />
      )}

      {/* Transporter shadow - only in production view */}
      {!isProcessView && (
        <rect
          x={transporterX + 8}
          y={transporterY + 8}
          width={transporterWidth}
          height={transporterHeight}
          fill="rgba(0,0,0,0.15)"
          rx={2}
        />
      )}

      {/* Transporter body */}
      <rect
        x={transporterX}
        y={transporterY}
        width={transporterWidth}
        height={transporterHeight}
        fill="rgba(255, 152, 0, 0.85)"
        stroke={transporterState.state.status === 4 ? "#4caf50" : "#ff9800"}
        strokeWidth={2}
        rx={2}
      />

      {/* Z position bar - only in production view */}
      {!isProcessView && (
        <rect
          x={barX}
          y={barY}
          width={barWidth}
          height={barHeight}
          fill="rgba(230, 120, 0, 1)"
          stroke="#d84315"
          strokeWidth={2}
          rx={2}
        />
      )}

      {/* Drip timer - only in production view */}
      {!isProcessView && renderDripTimer()}

      {/* Task info (lift > sink) */}
      {transporterState.state.phase !== 0 && 
       transporterState.state.lift_station_target != null && 
       transporterState.state.sink_station_target != null && (
        <text
          x={transporterX + (transporterWidth - barWidth - 4) / 2}
          y={transporterY + transporterHeight - 4}
          textAnchor="middle"
          fontSize={12}
          fontWeight="600"
          fill="#6d4c41"
        >
          {transporterState.state.lift_station_target}{'>'}{transporterState.state.sink_station_target}
        </text>
      )}

      {/* Unit box on transporter — only in production view */}
      {!isProcessView && hasUnit && (
        <g>
          <rect
            x={unitBoxX}
            y={unitBoxY}
            width={unitBoxWidth}
            height={unitBoxHeight}
            fill="none"
            stroke={unitColor}
            strokeWidth={1.5}
            rx={3}
          />
          <text
            x={unitBoxX + unitBoxWidth / 2}
            y={unitBoxY + 11}
            textAnchor="middle"
            dominantBaseline="middle"
            fontSize={10}
            fontWeight="700"
            fill={unitColor}
          >
            {String(unit.unit_id).padStart(3, '0')}
          </text>
        </g>
      )}

      {/* Batch on transporter - only in production view */}
      {!isProcessView && renderBatchOnTransporter()}

      {/* DEBUG: batch timing info */}
      {!isProcessView && renderBatchDebug()}

      {/* Unit target indicator — rendered AFTER batch so it appears on top */}
      {!isProcessView && hasUnit && unit.target && unit.target !== 'none' && unit.target !== 'empty' && (
        <text
          x={unitBoxX + unitBoxWidth / 2}
          y={unitBoxY + unitBoxHeight / 2}
          textAnchor="middle"
          dominantBaseline="middle"
          fontSize={12}
          fontWeight="800"
          fill="#000000"
          transform={`rotate(-90, ${unitBoxX + unitBoxWidth / 2}, ${unitBoxY + unitBoxHeight / 2})`}
        >
          {unit.target.replace('to_', '').toUpperCase()}
        </text>
      )}

      {/* Utilization pie chart - only in production view */}
      {!isProcessView && showUtilizationPie && (
        <MiniPieChart
          phaseStats={transporterState.state}
          cx={transporterX + transporterWidth / 2}
          cy={transporterY - 22}
          radius={16}
        />
      )}

      {/* Transporter ID */}
      <text
        x={transporterX + transporterWidth / 2}
        y={transporterY + 20}
        textAnchor="middle"
        fontSize={14}
        fontWeight="700"
        fill={config.colors?.text || '#555555'}
      >
        {transporter.id}
      </text>
    </g>
  );
}

export default Transporter2D;
