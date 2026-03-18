import React from 'react';

/**
 * Single station component with batch display and avoid checkboxes
 * 
 * Station represents the logical position within a tank. Since the station
 * is contained within a tank, it only shows an outline (dashed) to indicate
 * the required space. Tank has the name, station shows only the number.
 * 
 * @param {Object} props
 * @param {Object} props.station - Station data
 * @param {Object} props.batch - Batch at this station (or null)
 * @param {Object} props.unit - Unit at this station (or null)
 * @param {number} props.currentSimMs - Current simulation time in ms
 * @param {Object} props.config - Layout configuration
 * @param {Function} props.xScale - X coordinate scale
 * @param {Function} props.yScale - Y coordinate scale
 * @param {number} props.stationWidthMM - Station width in mm
 * @param {number} props.stationHeightMM - Station height in mm
 * @param {number} props.avoidStatus - Current avoid status (0, 1, or 2)
 * @param {Function} props.onAvoidStatusChange - Avoid status change handler
 * @param {boolean} props.showAvoidCheckboxes - Whether to show avoid checkboxes
 */
function Station({
  station,
  batch,
  unit,
  currentSimMs,
  config,
  xScale,
  yScale,
  stationWidthMM,
  stationHeightMM,
  avoidStatus = 0,
  onAvoidStatusChange,
  showAvoidCheckboxes = true
}) {
  const w = Math.abs(xScale(stationWidthMM) - xScale(0));
  const h = Math.abs(yScale(0) - yScale(stationHeightMM));

  // Center the station on its x/y coordinates
  const x = xScale(station.x_position) - w / 2;
  const y = yScale(station.y_position) - h / 2;

  const hasBatch = Boolean(batch);
  const hasUnit = Boolean(unit);
  const unitColor = (hasUnit && unit.status === 'not_used') ? '#616161' : '#1565c0';

  // Unit box is wider than batch bar — batch fits visually inside
  const unitBoxWidth = Math.min(82, w * 0.52);
  const batchBarWidth = Math.min(68, unitBoxWidth - 8);
  const unitBoxX = x + (w - unitBoxWidth) / 2;
  const batchBarX = x + (w - batchBarWidth) / 2;

  // Unit box starts just below station number, leaves room for unit_id label at top
  const unitBoxY = y + 24;
  const unitBoxBottom = y + h - 10;
  const unitBoxHeight = Math.max(20, unitBoxBottom - unitBoxY);

  // Batch bar is inset inside the unit box: below unit_id label, above unit box bottom
  const unitLabelHeight = 14;  // space for unit_id text at top of unit box
  const batchBarY = unitBoxY + unitLabelHeight + 2;
  const batchBarBottom = unitBoxBottom - 3;
  const batchBarHeight = Math.max(12, batchBarBottom - batchBarY);

  // Render batch bar based on stage
  const renderBatchBar = () => {
    if (!hasBatch) return null;

    // Käsitelty erä: Unit target = 'to_unloading' tai state = 'processed' → kokonaan vihreä
    const isProcessed = hasUnit && (unit.target === 'to_unloading' || unit.state === 'processed');
    if (isProcessed) {
      return (
        <g>
          <rect
            x={batchBarX}
            y={batchBarY}
            width={batchBarWidth}
            height={batchBarHeight}
            fill="#4caf50"
            stroke="#2e7d32"
            strokeWidth={0.6}
            rx={1}
          />
          <text
            x={0}
            y={0}
            textAnchor="middle"
            dominantBaseline="middle"
            fontSize={11}
            fontWeight="700"
            fill="#000000"
            stroke="none"
            transform={`translate(${batchBarX + batchBarWidth / 2}, ${batchBarY + 10}) rotate(-90)`}
          >
            {batch.batch_id}
          </text>
        </g>
      );
    }

    if (batch.stage === 90) {
      // Stage 90 (waiting) - outline-only style
      return (
        <g>
          <rect
            x={batchBarX}
            y={batchBarY}
            width={batchBarWidth}
            height={batchBarHeight}
            fill="transparent"
            stroke="#2196f3"
            strokeWidth={2}
            strokeDasharray="4,2"
            rx={1}
          />
          <text
            x={0}
            y={0}
            textAnchor="middle"
            dominantBaseline="middle"
            fontSize={11}
            fontWeight="700"
            fill="#2196f3"
            stroke="none"
            transform={`translate(${batchBarX + batchBarWidth / 2}, ${batchBarY + 10}) rotate(-90)`}
          >
            {batch.batch_id}
          </text>
        </g>
      );
    }

    if (batch.stage === 0) {
      // Stage 0 - same time progress bar as other stages (blue→green→red)
      // Falls through to stage 1-89 rendering below
    }

    // Stage 0-89 - time progress bar
    const minTime = Math.max(0, Number(batch.min_time_s) || 0);
    const calcTime = Math.max(minTime, Number(batch.calc_time_s) || minTime);
    const maxTime = Math.max(calcTime, Number(batch.max_time_s) || 0);
    const overWindow = maxTime > 0 ? maxTime * 0.2 : 0;
    const startSec = Number(batch.start_time) || 0;
    const elapsedSec = Math.max(0, currentSimMs - startSec);

    // Blue phase: 0 -> calcTime
    // Jos calcTime = 0, minimiaika on jo saavutettu → sininen täysi
    const blueRatio = calcTime > 0 ? Math.min(1, elapsedSec / calcTime) : 1;

    // Green phase: calcTime -> maxTime
    let greenRatio = 0;
    if (elapsedSec > calcTime && maxTime > calcTime) {
      greenRatio = Math.min(1, (elapsedSec - calcTime) / (maxTime - calcTime));
    } else if (elapsedSec >= maxTime && maxTime > calcTime) {
      greenRatio = 1;
    }

    // Red phase: after maxTime over 20% window
    let redRatio = 0;
    if (elapsedSec > maxTime && overWindow > 0) {
      redRatio = Math.min(1, (elapsedSec - maxTime) / overWindow);
    } else if (elapsedSec > maxTime && overWindow === 0) {
      redRatio = 1;
    }

    const blueH = batchBarHeight * blueRatio;
    const greenH = batchBarHeight * greenRatio;
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
        {blueH > 0 && (
          <rect
            x={batchBarX}
            y={batchBarY + (batchBarHeight - blueH)}
            width={batchBarWidth}
            height={blueH}
            fill="#2196f3"
            stroke="#1976d2"
            strokeWidth={0.6}
            rx={1}
          />
        )}
        {greenH > 0 && (
          <rect
            x={batchBarX}
            y={batchBarY + (batchBarHeight - greenH)}
            width={batchBarWidth}
            height={greenH}
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
          fontWeight="700"
          fill="#ffffff"
          stroke="#333333"
          strokeWidth={0.5}
          transform={`translate(${batchBarX + batchBarWidth / 2}, ${batchBarY + 10}) rotate(-90)`}
        >
          {batch.batch_id}
        </text>
      </g>
    );
  };

  // Render avoid checkboxes
  const renderAvoidCheckboxes = () => {
    if (!showAvoidCheckboxes) return null;

    const checkboxSize = Math.min(40, w * 0.24);
    const rightEdge = hasUnit ? (unitBoxX + unitBoxWidth) : (batchBarX + batchBarWidth);
    const stationRightEdge = x + w;
    const availableSpace = stationRightEdge - rightEdge;
    const checkboxX = rightEdge + (availableSpace - checkboxSize) / 2;
    const checkboxY1 = y + 32;
    const checkboxY2 = checkboxY1 + checkboxSize + 4;

    const isUpperDisabled = false;
    const isLowerDisabled = avoidStatus === 2;

    return (
      <g>
        {/* Upper checkbox (avoid_status = 2) */}
        <rect
          x={checkboxX}
          y={checkboxY1}
          width={checkboxSize}
          height={checkboxSize}
          fill={avoidStatus === 2 ? "#e53935" : "#ffffff"}
          stroke="#666"
          strokeWidth={1}
          rx={1}
          style={{ cursor: isUpperDisabled ? 'not-allowed' : 'pointer', opacity: isUpperDisabled ? 0.5 : 1 }}
          onClick={(e) => {
            e.stopPropagation();
            if (!isUpperDisabled && onAvoidStatusChange) {
              onAvoidStatusChange(station.number, avoidStatus === 2 ? 0 : 2);
            }
          }}
        />
        {/* Lower checkbox (avoid_status = 1) */}
        <rect
          x={checkboxX}
          y={checkboxY2}
          width={checkboxSize}
          height={checkboxSize}
          fill={avoidStatus === 1 ? "#e53935" : (avoidStatus === 2 ? "#e53935" : "#ffffff")}
          stroke="#666"
          strokeWidth={1}
          rx={1}
          style={{ cursor: isLowerDisabled ? 'not-allowed' : 'pointer', opacity: isLowerDisabled ? 0.5 : 1 }}
          onClick={(e) => {
            e.stopPropagation();
            if (!isLowerDisabled && onAvoidStatusChange) {
              onAvoidStatusChange(station.number, avoidStatus === 1 ? 0 : 1);
            }
          }}
        />
      </g>
    );
  };

  return (
    <g key={`station-${station.number}`} style={{ cursor: 'default' }}>
      {/* Tooltip */}
      <title>{`${station.number} - ${station.name}`}</title>
      
      {/* Station outline (dashed, no fill - station is inside tank) */}
      <rect
        x={x}
        y={y}
        width={w}
        height={h}
        fill="none"
        stroke="#505050"
        strokeWidth={1}
        strokeDasharray="6,3"
        rx={2}
      />

      {/* Unit box — drawn before batch bar so batch renders on top */}
      {hasUnit && (
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
          {/* Unit ID label at top edge of unit box */}
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
      
      {/* Batch bar (inside unit box) */}
      {renderBatchBar()}

      {/* Unit target indicator — rendered AFTER batch so it appears on top */}
      {hasUnit && unit.target && unit.target !== 'none' && unit.target !== 'empty' && (
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
      
      {/* Station number at top */}
      <text
        x={x + w / 2}
        y={y + 14}
        textAnchor="middle"
        fontSize={14}
        fontWeight="700"
        fill={config.colors?.text || '#555555'}
      >
        {station.number}
      </text>
      
      {/* Avoid status checkboxes */}
      {renderAvoidCheckboxes()}
    </g>
  );
}

export default Station;
