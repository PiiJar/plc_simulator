// StationLayout - Modular treatment line visualization component
// Can be used standalone in other applications

export { default } from './StationLayout/index.jsx';
export { default as StationLayout } from './StationLayout/index.jsx';

// Subcomponents (can be used individually)
export { default as Station } from './StationLayout/subcomponents/Station.jsx';
export { default as Tank } from './StationLayout/subcomponents/Tank.jsx';
export { default as Transporter2D } from './StationLayout/subcomponents/Transporter2D.jsx';
export { default as Transporter3D } from './StationLayout/subcomponents/Transporter3D.jsx';
export { default as ProductionBar } from './StationLayout/subcomponents/ProductionBar.jsx';

// Helpers
export { default as MiniPieChart } from './StationLayout/helpers/MiniPieChart.jsx';
export { default as DraggablePanel } from './StationLayout/helpers/DraggablePanel.jsx';

// Hooks
export { default as useLayoutScales } from './StationLayout/hooks/useLayoutScales.js';
