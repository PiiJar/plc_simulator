import React from 'react';
import Transporter2D from './Transporter2D';

/**
 * 3D Transporter component - uses Transporter2D as base with Y guide rails
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
 */
function Transporter3D({
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
  onTransporterClick
}) {
  if (!transporterState) return null;

  // 3D transporter uses x_position and y_position from state
  const currentX = transporterState.state.x_position;
  const currentY = transporterState.state.y_position;

  // Y drive limits for guide positioning
  const yMin = transporterState.state.y_min_drive_limit || 0;
  const yMax = transporterState.state.y_max_drive_limit || 0;

  // Transporter dimensions
  const avoidDistance = transporter.physics_3D?.avoid_distance_mm || transporter.physics_2D?.avoid_distance_mm || 800;
  const widthScaleFactor = config.transporters?.widthScaleFactor || 0.8;
  const transporterWidthMM = avoidDistance * widthScaleFactor;
  const transporterHeightMM = config.transporters?.heightMM || 1200;

  // Calculate transporter box dimensions
  const transporterX = xScale(currentX) - Math.abs(xScale(transporterWidthMM) - xScale(0)) / 2;
  const transporterWidth = Math.abs(xScale(transporterWidthMM) - xScale(0));
  const transporterHeight = Math.abs(yScale(0) - yScale(transporterHeightMM));

  // Guide dimensions - 15mm wide, fixed height from yMin to yMax
  const guideWidthMM = 15;
  const guideWidth = Math.abs(xScale(guideWidthMM) - xScale(0));

  // Guides are fixed: top at yMax, bottom at yMin
  const guideYTop = yScale(yMin - transporterHeightMM / 2);
  const guideYBottom = yScale(yMax + transporterHeightMM / 2);
  const guideHeight = Math.abs(guideYBottom - guideYTop);
  const guideY = Math.min(guideYTop, guideYBottom);

  // Guides are at fixed X position (centered on transporter's X path)
  const centerX = xScale(currentX);
  const leftGuideX = centerX - transporterWidth / 2 - guideWidth;
  const rightGuideX = centerX + transporterWidth / 2;

  // X drive limits
  const xMin = transporterState.state.x_min_drive_limit || 0;
  const xMax = transporterState.state.x_max_drive_limit || 0;
  const hasXDriveLimits = xMin !== 0 && xMax !== 0;
  const yDriveLine = guideY; // Top of guides

  return (
    <g
      onClick={(e) => {
        e.stopPropagation();
        if (onTransporterClick) onTransporterClick(transporter.id);
      }}
      style={{ cursor: 'pointer' }}
    >
      {/* X direction drive limits line */}
      {showDriveLimits && hasXDriveLimits && (
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

      {/* Left guide rail */}
      <rect
        x={leftGuideX}
        y={guideY}
        width={guideWidth}
        height={guideHeight}
        fill="rgba(255, 152, 0, 0.85)"
        stroke="#ff9800"
        strokeWidth={2}
        rx={1}
      />

      {/* Right guide rail */}
      <rect
        x={rightGuideX}
        y={guideY}
        width={guideWidth}
        height={guideHeight}
        fill="rgba(255, 152, 0, 0.85)"
        stroke="#ff9800"
        strokeWidth={2}
        rx={1}
      />

      {/* Top horizontal guide bar */}
      <rect
        x={leftGuideX}
        y={guideY}
        width={rightGuideX - leftGuideX + guideWidth}
        height={guideWidth}
        fill="rgba(255, 152, 0, 0.85)"
        stroke="#ff9800"
        strokeWidth={2}
        rx={1}
      />

      {/* Bottom horizontal guide bar */}
      <rect
        x={leftGuideX}
        y={guideY + guideHeight - guideWidth}
        width={rightGuideX - leftGuideX + guideWidth}
        height={guideWidth}
        fill="rgba(255, 152, 0, 0.85)"
        stroke="#ff9800"
        strokeWidth={2}
        rx={1}
      />

      {/* Use Transporter2D as the main transporter body */}
      <Transporter2D
        transporter={transporter}
        transporterState={transporterState}
        batch={batch}
        unit={unit}
        currentSimMs={currentSimMs}
        config={config}
        xScale={xScale}
        yScale={yScale}
        stations={stations}
        stationWidthMM={stationWidthMM}
        stationHeightMM={stationHeightMM}
        showUtilizationPie={showUtilizationPie}
        showDriveLimits={false} // Drive limits already rendered above
        onTransporterClick={null} // Click already handled by 3D wrapper
        yPositionOverride={currentY} // Use dynamic Y position
      />
    </g>
  );
}

export default Transporter3D;
