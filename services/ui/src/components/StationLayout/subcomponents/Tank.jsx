import React, { useState, useEffect, useRef } from 'react';
import { getTankColors, getTankType, getProcessColors } from '../../../colorPalette';

/**
 * Single tank component - physical tank/basin visualization
 * 
 * Tank represents the physical container/basin. Different types have
 * different visual appearances (plastic, steel, empty, filled, etc.)
 * 
 * Two view modes:
 *   - 'production': Top-down view (X-Y), see tank opening from above
 *   - 'process': Side view (X-Z), see tank end wall from outside
 * 
 * Animated 3D flip transition when viewMode changes.
 * 
 * Colors are loaded from /public/colorPalette.json at runtime.
 * Edit that file to change colors without rebuild.
 * 
 * Tank Types:
 *   0  = Loading/Unloading position
 *   1  = Storage position
 *   10 = Plastic tank (empty)
 *   11 = Plastic tank (water)
 *   12 = Plastic tank (acid)
 *   20 = Stainless Steel tank (empty)
 *   21 = Stainless Steel tank (water)
 *   22 = Steel tank (empty) - neutral gray
 *   23 = Steel tank (full/water) - neutral gray
 *   30 = Dryer
 *   31 = Spray booth
 * 
 * @param {Object} props
 * @param {Object} props.tank - Tank data from tanks.json
 * @param {Object} props.config - Layout configuration
 * @param {Function} props.xScale - X coordinate scale
 * @param {Function} props.yScale - Y coordinate scale (used for Y in production, Z in process)
 * @param {number} props.tankWidthMM - Tank width in mm (default from dimensions)
 * @param {number} props.tankHeightMM - Tank height in mm (default from dimensions)
 * @param {boolean} props.showDimensions - Whether to show dimension labels
 * @param {boolean} props.showName - Whether to show tank name
 * @param {string} props.viewMode - 'production' (X-Y top-down) or 'process' (X-Z side view)
 * @param {Function} props.onClick - Click handler (optional)
 */
function Tank({
  tank,
  config,
  xScale,
  yScale,
  tankWidthMM,
  tankHeightMM,
  showDimensions = false,
  showName = true,
  viewMode = 'production',
  onClick
}) {
  // Animation state
  const [displayMode, setDisplayMode] = useState(viewMode);
  const [flipAngle, setFlipAngle] = useState(0);
  const [isFlipping, setIsFlipping] = useState(false);
  const prevViewMode = useRef(viewMode);
  
  // Handle viewMode change with flip animation
  useEffect(() => {
    if (viewMode !== prevViewMode.current) {
      setIsFlipping(true);
      
      // Phase 1: Flip to 90 degrees (halfway)
      setFlipAngle(90);
      
      // Phase 2: At halfway point, switch the display content
      const switchTimer = setTimeout(() => {
        setDisplayMode(viewMode);
      }, 150); // Half of transition time
      
      // Phase 3: Complete flip to 0 degrees
      const completeTimer = setTimeout(() => {
        setFlipAngle(0);
        setIsFlipping(false);
      }, 160);
      
      prevViewMode.current = viewMode;
      
      return () => {
        clearTimeout(switchTimer);
        clearTimeout(completeTimer);
      };
    }
  }, [viewMode]);

  // Get tank operation code (default to 10 = plastic PP)
  const tankTypeNum = tank.operation ?? 10;
  const typeInfo = getTankType(tankTypeNum);
  
  // Get colors from palette
  // - colors = tank structure/material (from type)
  // - processInfo = liquid/process colors (from process field)
  const colors = getTankColors(tankTypeNum);
  const processInfo = getProcessColors(tank.process);
  
  // Determine dimensions based on view mode
  // Production (X-Y): width = length, height = width
  // Process (X-Z): width = length, height = depth
  const lengthMM = tank.dimensions?.length_mm || 1200;
  const widthMMDim = tank.dimensions?.width_mm || 800;
  const depthMM = tank.dimensions?.depth_mm || 1500;
  
  const displayWidthMM = tankWidthMM || lengthMM;
  const displayHeightMM = viewMode === 'process' 
    ? depthMM   // Process view: show depth as height
    : (tankHeightMM || widthMMDim);  // Production view: show width as height
  
  const w = Math.abs(xScale(displayWidthMM) - xScale(0));
  const h = Math.abs(yScale(0) - yScale(displayHeightMM));

  // Center the tank on its x/y coordinates
  // In process mode, y_position represents z_position (or use tank.z_position if available)
  const xPos = tank.x_position;
  const yPos = viewMode === 'process' 
    ? (tank.z_position ?? tank.y_position ?? 0)
    : tank.y_position;
    
  const x = xScale(xPos) - w / 2;
  const y = yScale(yPos) - h / 2;

  // Wall thickness for 3D effect
  const wallThickness = tank.dimensions?.wall_thickness_mm || 6;
  const wallPx = Math.max(3, Math.abs(xScale(wallThickness * 8) - xScale(0))); // Exaggerate for visibility
  
  // Render production view (top-down, X-Y)
  const renderProductionView = () => {
    const style = typeInfo.style || 'tank';
    
    if (style === 'platform' || style === 'storage') {
      return (
        <g>
          <rect
            x={x}
            y={y}
            width={w}
            height={h}
            fill={colors.base}
            stroke={colors.border}
            strokeWidth={2}
            strokeDasharray={style === 'storage' ? '8,4' : 'none'}
            rx={4}
          />
          <circle
            cx={x + w / 2}
            cy={y + h / 2}
            r={Math.min(w, h) * 0.15}
            fill="none"
            stroke={colors.dark}
            strokeWidth={1}
            strokeDasharray="4,4"
          />
        </g>
      );
    }
    
    if (style === 'equipment') {
      return (
        <g>
          <rect x={x} y={y} width={w} height={h}
            fill={colors.base} stroke={colors.border} strokeWidth={2} rx={3}
          />
          <path d={`M ${x + 3} ${y + h - 3} L ${x + 3} ${y + 3} L ${x + w - 3} ${y + 3}`}
            fill="none" stroke={colors.light} strokeWidth={2} strokeLinecap="round"
          />
          <path d={`M ${x + w - 3} ${y + 3} L ${x + w - 3} ${y + h - 3} L ${x + 3} ${y + h - 3}`}
            fill="none" stroke={colors.dark} strokeWidth={2} strokeLinecap="round"
          />
        </g>
      );
    }
    
    // Default: Tank top-down view (see opening from above)
    return (
      <g>
        {/* Outer rim */}
        <rect x={x} y={y} width={w} height={h}
          fill={colors.base} stroke={colors.border} strokeWidth={1}
          filter="url(#tank-shadow)" rx={2}
        />
        {/* Top/left highlight */}
        <path d={`M ${x + 2} ${y + h - 2} L ${x + 2} ${y + 2} L ${x + w - 2} ${y + 2}`}
          fill="none" stroke={colors.light} strokeWidth={wallPx * 0.6}
          strokeLinecap="round" opacity={0.8}
        />
        {/* Bottom/right shadow */}
        <path d={`M ${x + w - 2} ${y + 2} L ${x + w - 2} ${y + h - 2} L ${x + 2} ${y + h - 2}`}
          fill="none" stroke={colors.dark} strokeWidth={wallPx * 0.6}
          strokeLinecap="round" opacity={0.6}
        />
        {/* Inner basin (dark = depth) */}
        <rect x={x + wallPx} y={y + wallPx} width={w - wallPx * 2} height={h - wallPx * 2}
          fill={colors.dark} stroke="none" rx={1} opacity={0.4}
        />
        {/* Liquid (if any) - based on process */}
        {processInfo.opacity > 0 && (
          <g>
            {/* Base liquid color */}
            <rect x={x + wallPx + 1} y={y + wallPx + 1}
              width={w - wallPx * 2 - 2} height={h - wallPx * 2 - 2}
              fill={processInfo.fill} stroke="none" rx={1} opacity={processInfo.opacity}
            />
            {/* Corner to corner gradient shine */}
            <rect x={x + wallPx + 1} y={y + wallPx + 1}
              width={w - wallPx * 2 - 2} height={h - wallPx * 2 - 2}
              fill="url(#liquid-shine)" stroke="none" rx={1}
            />
          </g>
        )}
        {/* Corner shadows */}
        <path d={`M ${x + wallPx} ${y + wallPx} L ${x + wallPx + 4} ${y + wallPx + 4}
            M ${x + w - wallPx} ${y + wallPx} L ${x + w - wallPx - 4} ${y + wallPx + 4}
            M ${x + wallPx} ${y + h - wallPx} L ${x + wallPx + 4} ${y + h - wallPx - 4}
            M ${x + w - wallPx} ${y + h - wallPx} L ${x + w - wallPx - 4} ${y + h - wallPx - 4}`}
          fill="none" stroke={colors.dark} strokeWidth={1} opacity={0.3}
        />
      </g>
    );
  };
  
  // Render process view (side view, X-Z)
  const renderProcessView = () => {
    const style = typeInfo.style || 'tank';
    
    if (style === 'platform' || style === 'storage') {
      // Simple platform in side view
      return (
        <g>
          <rect x={x} y={y} width={w} height={h}
            fill={colors.base} stroke={colors.border} strokeWidth={2}
            strokeDasharray={style === 'storage' ? '8,4' : 'none'} rx={2}
          />
        </g>
      );
    }
    
    if (style === 'equipment') {
      return (
        <g>
          <rect x={x} y={y} width={w} height={h}
            fill={colors.base} stroke={colors.border} strokeWidth={2} rx={3}
          />
          <path d={`M ${x + 3} ${y + h - 3} L ${x + 3} ${y + 3} L ${x + w - 3} ${y + 3}`}
            fill="none" stroke={colors.light} strokeWidth={2} strokeLinecap="round"
          />
          <path d={`M ${x + w - 3} ${y + 3} L ${x + w - 3} ${y + h - 3} L ${x + 3} ${y + h - 3}`}
            fill="none" stroke={colors.dark} strokeWidth={2} strokeLinecap="round"
          />
        </g>
      );
    }
    
    // Default: Tank end view (looking at the end wall from outside)
    // Simple rectangle representing the end wall of the tank
    return (
      <g>
        {/* Tank end wall (solid rectangle) */}
        <rect
          x={x}
          y={y}
          width={w}
          height={h}
          fill={colors.base}
          stroke={colors.border}
          strokeWidth={1.5}
          filter="url(#tank-shadow)"
          rx={2}
        />
        
        {/* Top edge highlight (3D effect) */}
        <path
          d={`M ${x + 2} ${y + h - 2} L ${x + 2} ${y + 2} L ${x + w - 2} ${y + 2}`}
          fill="none"
          stroke={colors.light}
          strokeWidth={3}
          strokeLinecap="round"
          opacity={0.7}
        />
        
        {/* Bottom/right edge shadow (3D effect) */}
        <path
          d={`M ${x + w - 2} ${y + 2} L ${x + w - 2} ${y + h - 2} L ${x + 2} ${y + h - 2}`}
          fill="none"
          stroke={colors.dark}
          strokeWidth={3}
          strokeLinecap="round"
          opacity={0.5}
        />
        
        {/* Rim indicator at top (shows tank opening goes away from viewer) */}
        <rect
          x={x + 4}
          y={y + 4}
          width={w - 8}
          height={6}
          fill={colors.dark}
          stroke="none"
          rx={1}
          opacity={0.3}
        />
      </g>
    );
  };

  // Calculate transform origin (center of tank)
  const centerX = x + w / 2;
  const centerY = y + h / 2;

  return (
    <g 
      key={`tank-${tank.tank_id}`} 
      style={{ 
        cursor: onClick ? 'pointer' : 'default',
        transformOrigin: `${centerX}px ${centerY}px`,
        transform: `rotateX(${flipAngle}deg)`,
        transition: isFlipping ? 'transform 0.15s ease-in-out' : 'none',
        transformStyle: 'preserve-3d'
      }}
      onClick={onClick ? () => onClick(tank) : undefined}
    >
      {/* Tooltip */}
      <title>{`${tank.tank_id} - ${tank.name}\nType: ${typeInfo.name}${tank.process ? `\nProcess: ${processInfo.name}` : ''}\nView: ${displayMode}${tank.dimensions ? `\n${lengthMM}×${widthMMDim}×${depthMM}mm` : ''}`}</title>
      
      {/* Render based on current display mode (animated) */}
      {displayMode === 'process' ? renderProcessView() : renderProductionView()}
      
      {/* Tank name (horizontal, below tank, bold) */}
      {showName && (
        <text
          x={x + w / 2}
          y={y + h + 16}
          textAnchor="middle"
          fontSize={11}
          fontWeight="700"
          fill={colors.border}
        >
          {tank.name}
        </text>
      )}
      
      {/* Depth/dimension indicator */}
      {showDimensions && tank.dimensions && (
        <text
          x={x + 6}
          y={y + h - 6}
          textAnchor="start"
          fontSize={8}
          fill={colors.border}
          opacity={0.7}
        >
          {displayMode === 'process' 
            ? `${depthMM}mm` 
            : `↓${depthMM}mm`}
        </text>
      )}
    </g>
  );
}

export default Tank;
