import { useState, useEffect, useRef } from 'react';
import * as d3 from 'd3';

/**
 * Hook for calculating layout scales and dimensions
 * 
 * @param {Object} params
 * @param {Object} params.config - Layout configuration
 * @param {Array} params.stations - Station array
 * @param {Array} params.transporterStates - Transporter state array
 * @returns {Object} { dimensions, containerRef, xScale, yScale, margin, stationWidthMM, stationHeightMM, showAvoidCheckboxes, showUtilizationPie, showDriveLimits }
 */
function useLayoutScales({ config, stations, transporterStates }) {
  const [dimensions, setDimensions] = useState({ width: 1400, height: 800 });
  const containerRef = useRef(null);

  useEffect(() => {
    const updateDimensions = () => {
      if (containerRef.current) {
        const { clientWidth, clientHeight } = containerRef.current;
        setDimensions({ width: clientWidth, height: clientHeight });
      }
    };

    updateDimensions();
    window.addEventListener('resize', updateDimensions);
    return () => window.removeEventListener('resize', updateDimensions);
  }, []);

  // Early return if no data
  if (!config || !stations.length) {
    return {
      dimensions,
      containerRef,
      xScale: null,
      yScale: null,
      margin: { top: 40, right: 40, bottom: 40, left: 40 },
      stationWidthMM: 400,
      stationHeightMM: 1000,
      showAvoidCheckboxes: true,
      showUtilizationPie: true,
      showDriveLimits: true,
      isSingleLine: true
    };
  }

  const { width, height } = dimensions;

  // Determine if single or multi line based on unique y_position values
  const uniqueYPositions = [...new Set(stations.map(s => s.y_position))];
  const isSingleLine = uniqueYPositions.length === 1;

  // Select appropriate margins based on line configuration
  let margin;
  if (config.margins) {
    margin = isSingleLine ? config.margins.singleLine : config.margins.multiLine;
  } else {
    margin = config.margin || { top: 40, right: 40, bottom: 40, left: 40 };
  }

  // Station physical sizes (mm) from config
  const stationWidthMM = config.stations?.widthMM || 400;
  const stationHeightMM = config.stations?.heightMM || 1000;
  const showAvoidCheckboxes = config.stations?.showAvoidCheckboxes !== false;
  const showUtilizationPie = config.transporters?.showUtilizationPie !== false;
  const showDriveLimits = config.transporters?.showDriveLimits !== false;

  // Calculate coordinate ranges
  const xExtentRaw = d3.extent(stations, d => d.x_position);
  const yExtentRaw = d3.extent(stations, d => d.y_position);
  const padX = stationWidthMM / 2;
  const padY = stationHeightMM / 2;
  const xExtent = [xExtentRaw[0] - padX, xExtentRaw[1] + padX];

  // For 3D transporters, extend y range to include guide rails
  const transporterHeightMM = config.transporters?.heightMM || 1200;
  let yExtentMin = yExtentRaw[0] - padY;
  let yExtentMax = yExtentRaw[1] + padY;

  // Check if any 3D transporters exist and extend range for their guides
  if (transporterStates) {
    transporterStates.forEach(ts => {
      if (ts.model === "3D" && ts.state) {
        const yMin = ts.state.y_min_drive_limit || 0;
        const yMax = ts.state.y_max_drive_limit || 0;
        yExtentMin = Math.min(yExtentMin, yMin - transporterHeightMM / 2);
        yExtentMax = Math.max(yExtentMax, yMax + transporterHeightMM / 2);
      }
    });
  }

  const yExtent = [yExtentMin, yExtentMax];

  // Create scales
  const xScale = d3.scaleLinear()
    .domain(config.xDirection === "left-to-right" ? xExtent : [xExtent[1], xExtent[0]])
    .range([margin.left, width - margin.right]);

  const yScale = d3.scaleLinear()
    .domain(config.yDirection === "top-to-bottom" ? yExtent : [yExtent[1], yExtent[0]])
    .range([margin.top, height - margin.bottom]);

  return {
    dimensions,
    containerRef,
    xScale,
    yScale,
    margin,
    stationWidthMM,
    stationHeightMM,
    showAvoidCheckboxes,
    showUtilizationPie,
    showDriveLimits,
    isSingleLine
  };
}

export default useLayoutScales;
