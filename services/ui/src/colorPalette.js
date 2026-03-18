/**
 * KOKKO Color Palette
 * 
 * Centralized color definitions for the entire project.
 * Change colors here to update all components using them.
 * 
 * Usage:
 *   import { COLORS, TANK_COLORS, getMaterialColor } from './colorPalette';
 */

// ============================================
// MATERIAL COLORS
// Base colors for different physical materials
// ============================================
export const MATERIALS = {
  // Plastics
  PLASTIC_PP: {
    base: '#d4b896',      // Polypropylene - light brown/tan
    dark: '#b89870',      // Darker shade for shadows
    light: '#e8d4b8',     // Lighter shade for highlights
    border: '#8b7355'     // Border/edge color
  },
  PLASTIC_PVC: {
    base: '#d4d4d4',      // PVC - light gray
    dark: '#b0b0b0',
    light: '#ececec',
    border: '#888888'
  },
  PLASTIC_HDPE: {
    base: '#2d5a8a',      // HDPE - blue
    dark: '#1e3d5c',
    light: '#4a7ab0',
    border: '#1a3050'
  },

  // Metals
  STEEL_STAINLESS: {
    base: '#c0c8d0',      // Stainless steel - blue-gray
    dark: '#8a9298',
    light: '#e8ecf0',
    border: '#707880'
  },
  STEEL_CARBON: {
    base: '#606060',      // Carbon steel - dark gray
    dark: '#404040',
    light: '#808080',
    border: '#303030'
  },
  STEEL_GALVANIZED: {
    base: '#b8c0c8',      // Galvanized - silvery
    dark: '#909aa0',
    light: '#d8e0e8',
    border: '#707880'
  },

  // Special surfaces
  RUBBER: {
    base: '#2a2a2a',      // Black rubber
    dark: '#1a1a1a',
    light: '#404040',
    border: '#101010'
  },
  CONCRETE: {
    base: '#a0a090',      // Concrete gray
    dark: '#808070',
    light: '#c0c0b0',
    border: '#606050'
  }
};

// ============================================
// PROCESS TYPES
// What the tank is used for - determines liquid color and effects
// ============================================
export const PROCESS_TYPES = {
  // Empty / No process
  EMPTY: {
    name: 'Empty',
    fill: 'transparent',
    surface: 'transparent',
    opacity: 0,
    effect: 'none'
  },
  
  // Loading/Unloading station
  LOADING: {
    name: 'Loading/Unloading',
    fill: 'transparent',
    surface: 'transparent',
    opacity: 0,
    effect: 'none'
  },
  
  // Water rinse
  RINSE: {
    name: 'Rinse',
    fill: '#b3d9ff',
    surface: '#80c0ff',
    opacity: 0.55,
    effect: 'ripple'
  },
  
  // Hot water rinse
  RINSE_HOT: {
    name: 'Hot Rinse',
    fill: '#99ccff',
    surface: '#70b0ff',
    opacity: 0.6,
    effect: 'steam'
  },
  
  // DI water rinse
  RINSE_DI: {
    name: 'DI Rinse',
    fill: '#c8e8ff',
    surface: '#a0d8ff',
    opacity: 0.45,
    effect: 'ripple'
  },
  
  // Degreasing / cleaning
  DEGREASE: {
    name: 'Degrease',
    fill: '#a8d4a8',
    surface: '#80c080',
    opacity: 0.65,
    effect: 'bubbles'
  },
  
  // Alkaline cleaning
  ALKALINE: {
    name: 'Alkaline Clean',
    fill: '#d0e8d0',
    surface: '#b0d8b0',
    opacity: 0.6,
    effect: 'bubbles'
  },
  
  // Acid pickling/cleaning
  ACID: {
    name: 'Acid',
    fill: '#ffe0b0',
    surface: '#ffd080',
    opacity: 0.7,
    effect: 'fumes'
  },
  
  // Activation
  ACTIVATION: {
    name: 'Activation',
    fill: '#ffe8c0',
    surface: '#ffd890',
    opacity: 0.55,
    effect: 'none'
  },
  
  // Generic plating
  PLATING: {
    name: 'Plating',
    fill: '#90b0d0',
    surface: '#7090b0',
    opacity: 0.75,
    effect: 'electrodes'
  },
  
  // Zinc plating
  ZINC: {
    name: 'Zinc Plating',
    fill: '#a0b8d0',
    surface: '#8098b0',
    opacity: 0.7,
    effect: 'electrodes'
  },
  
  // Nickel plating
  NICKEL: {
    name: 'Nickel Plating',
    fill: '#c0d0c0',
    surface: '#a0b0a0',
    opacity: 0.7,
    effect: 'electrodes'
  },
  
  // Copper plating
  COPPER: {
    name: 'Copper Plating',
    fill: '#e8c8b0',
    surface: '#d0a890',
    opacity: 0.7,
    effect: 'electrodes'
  },
  
  // Chrome plating
  CHROME: {
    name: 'Chrome Plating',
    fill: '#d0d8e8',
    surface: '#b0b8c8',
    opacity: 0.7,
    effect: 'electrodes'
  },
  
  // Tin plating
  TIN: {
    name: 'Tin Plating',
    fill: '#d8d8d8',
    surface: '#b8b8b8',
    opacity: 0.65,
    effect: 'electrodes'
  },
  
  // Gold plating
  GOLD: {
    name: 'Gold Plating',
    fill: '#f0d870',
    surface: '#e0c850',
    opacity: 0.7,
    effect: 'electrodes'
  },
  
  // Silver plating
  SILVER: {
    name: 'Silver Plating',
    fill: '#e0e0e8',
    surface: '#c8c8d0',
    opacity: 0.65,
    effect: 'electrodes'
  },
  
  // Passivation
  PASSIVATION: {
    name: 'Passivation',
    fill: '#d8e8f0',
    surface: '#b8d0e0',
    opacity: 0.55,
    effect: 'none'
  },
  
  // Chromate conversion
  CHROMATE: {
    name: 'Chromate',
    fill: '#f0e8a0',
    surface: '#e0d880',
    opacity: 0.6,
    effect: 'none'
  },
  
  // Phosphating
  PHOSPHATE: {
    name: 'Phosphating',
    fill: '#c8c8b8',
    surface: '#a8a898',
    opacity: 0.6,
    effect: 'none'
  },
  
  // Anodizing
  ANODIZE: {
    name: 'Anodizing',
    fill: '#b0c8e0',
    surface: '#90a8c0',
    opacity: 0.7,
    effect: 'electrodes'
  },
  
  // Etching
  ETCH: {
    name: 'Etching',
    fill: '#e8d0b0',
    surface: '#d0b090',
    opacity: 0.65,
    effect: 'fumes'
  },
  
  // Stripping
  STRIP: {
    name: 'Stripping',
    fill: '#e0c0a0',
    surface: '#c8a080',
    opacity: 0.7,
    effect: 'fumes'
  },
  
  // Sealing
  SEAL: {
    name: 'Sealing',
    fill: '#c8d8e8',
    surface: '#a8b8c8',
    opacity: 0.5,
    effect: 'steam'
  },
  
  // Drying
  DRYER: {
    name: 'Dryer',
    fill: 'transparent',
    surface: 'transparent',
    opacity: 0,
    effect: 'heat'
  },
  
  // Oven / baking
  OVEN: {
    name: 'Oven',
    fill: 'transparent',
    surface: 'transparent',
    opacity: 0,
    effect: 'heat'
  },
  
  // Spray booth
  SPRAY: {
    name: 'Spray',
    fill: 'transparent',
    surface: 'transparent',
    opacity: 0,
    effect: 'spray'
  },
  
  // Storage/buffer
  STORAGE: {
    name: 'Storage',
    fill: 'transparent',
    surface: 'transparent',
    opacity: 0,
    effect: 'none'
  }
};

// ============================================
// LIQUID COLORS (LEGACY - use PROCESS_TYPES instead)
// Colors for tank contents
// ============================================
export const LIQUIDS = {
  NONE: {
    fill: 'transparent',
    surface: 'transparent',
    opacity: 0
  },
  WATER: {
    fill: '#b3d9ff',      // Clear water - light blue
    surface: '#80c0ff',   // Surface reflection
    opacity: 0.6
  },
  WATER_DI: {
    fill: '#c8e8ff',      // DI Water - very light blue
    surface: '#a0d8ff',
    opacity: 0.5
  },
  ACID: {
    fill: '#ffe0b0',      // Acid - yellow/orange tint
    surface: '#ffd080',
    opacity: 0.7
  },
  ALKALINE: {
    fill: '#d0e8d0',      // Alkaline - greenish
    surface: '#b0d8b0',
    opacity: 0.6
  },
  OIL: {
    fill: '#e8d8a0',      // Oil - brownish yellow
    surface: '#d0c080',
    opacity: 0.8
  },
  SOLVENT: {
    fill: '#e0d0f0',      // Solvent - slight purple
    surface: '#d0c0e0',
    opacity: 0.5
  }
};

// ============================================
// TANK TYPES (Structure/Material)
// Physical tank structure - determines wall appearance
// Use 'process' field in tanks.json to set liquid/process color
// ============================================
export const TANK_TYPES = {
  // Type 0: Loading/Unloading position (not a physical tank)
  0: {
    name: 'Loading/Unloading',
    material: null,
    style: 'platform',
    colors: {
      base: '#f0f0f0',
      dark: '#d0d0d0',
      light: '#ffffff',
      border: '#a0a0a0'
    }
  },
  
  // Type 1: Storage position (not a physical tank)
  1: {
    name: 'Storage',
    material: null,
    style: 'storage',
    colors: {
      base: '#e8e8e8',
      dark: '#c8c8c8',
      light: '#f8f8f8',
      border: '#909090'
    }
  },

  // Type 10: Plastic PP tank
  10: {
    name: 'Plastic Tank (PP)',
    material: 'PLASTIC_PP',
    style: 'tank'
  },

  // Type 11: Plastic PVC tank
  11: {
    name: 'Plastic Tank (PVC)',
    material: 'PLASTIC_PVC',
    style: 'tank'
  },

  // Type 12: Plastic HDPE tank
  12: {
    name: 'Plastic Tank (HDPE)',
    material: 'PLASTIC_HDPE',
    style: 'tank'
  },

  // Type 20: Stainless steel tank
  20: {
    name: 'Stainless Steel Tank',
    material: 'STEEL_STAINLESS',
    style: 'tank'
  },

  // Type 21: Carbon steel tank
  21: {
    name: 'Carbon Steel Tank',
    material: 'STEEL_CARBON',
    style: 'tank'
  },

  // Type 22: Galvanized steel tank
  22: {
    name: 'Galvanized Steel Tank',
    material: 'STEEL_GALVANIZED',
    style: 'tank'
  },

  // Type 23: Rubber-lined tank
  23: {
    name: 'Rubber-Lined Tank',
    material: 'RUBBER',
    style: 'tank'
  },

  // Type 30: Dryer (special equipment)
  30: {
    name: 'Dryer',
    material: 'STEEL_STAINLESS',
    style: 'equipment',
    colors: {
      base: '#d0d8e0',
      dark: '#a0a8b0',
      light: '#e8f0f8',
      border: '#707880'
    }
  },

  // Type 31: Spray booth
  31: {
    name: 'Spray Booth',
    material: 'STEEL_STAINLESS',
    style: 'equipment',
    colors: {
      base: '#c8d0d8',
      dark: '#98a0a8',
      light: '#e0e8f0',
      border: '#606870'
    }
  },

  // Type 32: Oven
  32: {
    name: 'Oven',
    material: 'STEEL_CARBON',
    style: 'equipment',
    colors: {
      base: '#a0a0a0',
      dark: '#707070',
      light: '#c8c8c8',
      border: '#505050'
    }
  },

  // Type 40: Concrete tank
  40: {
    name: 'Concrete Tank',
    material: 'CONCRETE',
    style: 'tank'
  }
};

// ============================================
// HELPER FUNCTIONS
// ============================================

/**
 * Get colors for a tank type (structure/material)
 * @param {number} type - Tank type number
 * @returns {Object} Color object with base, dark, light, border
 */
export function getTankColors(type) {
  const tankType = TANK_TYPES[type] || TANK_TYPES[10];
  
  // If type has custom colors, use them
  if (tankType.colors) {
    return tankType.colors;
  }
  
  // Otherwise derive from material
  if (tankType.material && MATERIALS[tankType.material]) {
    return MATERIALS[tankType.material];
  }
  
  // Fallback
  return MATERIALS.PLASTIC_PP;
}

/**
 * Get process colors for a tank (what it's used for)
 * @param {string} process - Process type (e.g., 'RINSE', 'PLATING', 'DEGREASE')
 * @returns {Object} Process color object with fill, surface, opacity, effect
 */
export function getProcessColors(process) {
  if (!process || process === '') {
    return PROCESS_TYPES.EMPTY;
  }
  return PROCESS_TYPES[process] || PROCESS_TYPES.EMPTY;
}

/**
 * Get tank type info
 * @param {number} type - Tank type number
 * @returns {Object} Tank type info object
 */
export function getTankType(type) {
  return TANK_TYPES[type] || TANK_TYPES[10];
}

/**
 * Get liquid colors for a tank type (LEGACY - use getProcessColors instead)
 * @param {number} type - Tank type number
 * @returns {Object} Liquid color object
 * @deprecated Use getProcessColors with tank.process instead
 */
export function getTankLiquid(type) {
  const tankType = TANK_TYPES[type] || TANK_TYPES[10];
  return LIQUIDS[tankType.liquid] || LIQUIDS.NONE;
}

/**
 * Get material colors by name
 * @param {string} materialName - Material name (e.g., 'PLASTIC_PP')
 * @returns {Object} Material color object
 */
export function getMaterialColors(materialName) {
  return MATERIALS[materialName] || MATERIALS.PLASTIC_PP;
}

// ============================================
// UI COLORS (for general UI elements)
// ============================================
export const UI_COLORS = {
  // Status colors
  SUCCESS: '#4caf50',
  WARNING: '#ff9800',
  ERROR: '#e53935',
  INFO: '#2196f3',
  
  // Batch progress bars
  BATCH_PROCESSING: '#2196f3',
  BATCH_READY: '#4caf50',
  BATCH_OVERDUE: '#e53935',
  BATCH_WAITING: '#90caf9',
  
  // Transporter states
  TRANSPORTER_IDLE: '#78909c',
  TRANSPORTER_MOVING: '#42a5f5',
  TRANSPORTER_BUSY: '#66bb6a',
  
  // Text
  TEXT_PRIMARY: '#212121',
  TEXT_SECONDARY: '#757575',
  TEXT_LIGHT: '#ffffff',
  TEXT_ON_DARK: '#f5f5f5'
};

export default {
  MATERIALS,
  LIQUIDS,
  PROCESS_TYPES,
  TANK_TYPES,
  UI_COLORS,
  getTankColors,
  getTankType,
  getProcessColors,
  getTankLiquid,
  getMaterialColors
};
