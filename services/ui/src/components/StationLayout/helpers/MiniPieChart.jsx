import React from 'react';

/**
 * Mini pie chart for transporter utilization (idle vs active)
 * Uses same gray as type0 stations (#d0d0d0) for idle, green for active
 * 
 * @param {Object} props
 * @param {Object} props.phaseStats - Phase statistics from transporter state
 * @param {number} [props.cx=0] - Center X coordinate
 * @param {number} [props.cy=0] - Center Y coordinate
 * @param {number} [props.radius=18] - Pie chart radius
 */
function MiniPieChart({ phaseStats, cx = 0, cy = 0, radius = 18 }) {
  const idleMs = phaseStats?.phase_stats_idle_ms || 0;
  const activeMs = (phaseStats?.phase_stats_move_to_lift_ms || 0) +
                   (phaseStats?.phase_stats_lifting_ms || 0) +
                   (phaseStats?.phase_stats_move_to_sink_ms || 0) +
                   (phaseStats?.phase_stats_sinking_ms || 0);
  
  const total = idleMs + activeMs;
  if (total <= 0) {
    // No data yet - show empty gray circle
    return (
      <circle cx={cx} cy={cy} r={radius} fill="#d0d0d0" stroke="#bbb" strokeWidth={1} />
    );
  }
  
  const idleColor = '#d0d0d0';  // Same as type0 stations
  const activeColor = '#4caf50'; // Green for active/working
  
  // Build two-segment pie: idle starts at top, active follows
  const segments = [];
  let currentAngle = -Math.PI / 2; // Start at top
  
  // Idle segment
  if (idleMs > 0) {
    const angle = (idleMs / total) * 2 * Math.PI;
    const endAngle = currentAngle + angle;
    const x1 = cx + radius * Math.cos(currentAngle);
    const y1 = cy + radius * Math.sin(currentAngle);
    const x2 = cx + radius * Math.cos(endAngle);
    const y2 = cy + radius * Math.sin(endAngle);
    const largeArc = angle > Math.PI ? 1 : 0;
    const d = `M ${cx} ${cy} L ${x1} ${y1} A ${radius} ${radius} 0 ${largeArc} 1 ${x2} ${y2} Z`;
    segments.push(<path key="idle" d={d} fill={idleColor} stroke="#fff" strokeWidth={0.5} />);
    currentAngle = endAngle;
  }
  
  // Active segment
  if (activeMs > 0) {
    const angle = (activeMs / total) * 2 * Math.PI;
    const endAngle = currentAngle + angle;
    const x1 = cx + radius * Math.cos(currentAngle);
    const y1 = cy + radius * Math.sin(currentAngle);
    const x2 = cx + radius * Math.cos(endAngle);
    const y2 = cy + radius * Math.sin(endAngle);
    const largeArc = angle > Math.PI ? 1 : 0;
    const d = `M ${cx} ${cy} L ${x1} ${y1} A ${radius} ${radius} 0 ${largeArc} 1 ${x2} ${y2} Z`;
    segments.push(<path key="active" d={d} fill={activeColor} stroke="#fff" strokeWidth={0.5} />);
  }
  
  return <g>{segments}</g>;
}

export default MiniPieChart;
