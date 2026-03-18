import React from 'react';

/**
 * Production progress bar showing cycle time, throughput and progress
 * 
 * @param {Object} props
 * @param {number} props.width - SVG width
 * @param {number} props.avgCycleSec - Average cycle time in seconds
 * @param {Object} props.productionStats - Production statistics
 * @param {number} props.productionStats.queueLength - Batches in queue
 * @param {number} props.productionStats.inProgressCount - Batches in progress
 * @param {number} props.productionStats.completedCount - Completed batches
 * @param {number} props.productionStats.totalBatches - Total batches
 */
function ProductionBar({ width, avgCycleSec = 0, productionStats = {} }) {
  const total = productionStats.totalBatches || 0;
  const queue = productionStats.queueLength || 0;
  const inProgress = productionStats.inProgressCount || 0;
  const completed = productionStats.completedCount || 0;

  // Don't render if no data
  if (total <= 0 && avgCycleSec <= 0) {
    return null;
  }

  const barWidth = Math.min(400, width - 40);
  const barHeight = 18;
  const barX = (width - barWidth) / 2;
  const barY = 8;

  // Calculate segment widths
  const completedW = total > 0 ? (completed / total) * barWidth : 0;
  const inProgressW = total > 0 ? (inProgress / total) * barWidth : 0;
  // const queueW = total > 0 ? (queue / total) * barWidth : 0;

  // Throughput: batches per hour
  const throughput = avgCycleSec > 0 ? (3600 / avgCycleSec) : 0;
  const cycleMin = Math.floor(avgCycleSec / 60);
  const cycleSec = Math.floor(avgCycleSec % 60);

  return (
    <g>
      {/* Background */}
      <rect 
        x={barX} 
        y={barY} 
        width={barWidth} 
        height={barHeight} 
        rx={3} 
        fill="#e0e0e0" 
        stroke="#bdbdbd" 
        strokeWidth={1} 
      />
      
      {/* Completed (green) */}
      {completedW > 0 && (
        <rect 
          x={barX} 
          y={barY} 
          width={completedW} 
          height={barHeight} 
          rx={completedW === barWidth ? 3 : 0} 
          fill="#4caf50" 
        />
      )}
      
      {/* In progress (blue) */}
      {inProgressW > 0 && (
        <rect 
          x={barX + completedW} 
          y={barY} 
          width={inProgressW} 
          height={barHeight} 
          fill="#2196f3" 
        />
      )}
      
      {/* Queue (gray) is already the background */}
      
      {/* Labels */}
      {total > 0 && (
        <text 
          x={barX + barWidth / 2} 
          y={barY + barHeight / 2 + 1} 
          textAnchor="middle" 
          dominantBaseline="middle" 
          fontSize={11} 
          fontWeight="600" 
          fill="#fff" 
          stroke="#333" 
          strokeWidth={0.3}
        >
          {completed} / {total} valmiit
        </text>
      )}
      
      {/* Cycle time and throughput on the right */}
      {avgCycleSec > 0 && (
        <text 
          x={barX + barWidth + 10} 
          y={barY + barHeight / 2 + 1} 
          textAnchor="start" 
          dominantBaseline="middle" 
          fontSize={11} 
          fontWeight="500" 
          fill="#1565c0"
        >
          {cycleMin}:{cycleSec.toString().padStart(2, '0')} ({throughput.toFixed(1)}/h)
        </text>
      )}
      
      {/* Legend on the left */}
      <text 
        x={barX - 10} 
        y={barY + barHeight / 2 + 1} 
        textAnchor="end" 
        dominantBaseline="middle" 
        fontSize={10} 
        fill="#666"
      >
        Tuotanto:
      </text>
    </g>
  );
}

export default ProductionBar;
