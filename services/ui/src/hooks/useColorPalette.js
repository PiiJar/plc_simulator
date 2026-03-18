import { useState, useEffect } from 'react';

/**
 * Hook for loading color palette from JSON file
 * 
 * Colors are loaded at runtime, so changes to colorPalette.json
 * take effect on browser refresh without rebuild.
 * 
 * Usage:
 *   const { palette, getTankColors, getTankLiquid, isLoaded } = useColorPalette();
 */

// Default fallback palette (used before JSON loads)
const DEFAULT_PALETTE = {
  materials: {
    PLASTIC_PP: {
      base: '#d4b896',
      dark: '#b89870',
      light: '#e8d4b8',
      border: '#8b7355'
    }
  },
  liquids: {
    NONE: { fill: 'transparent', surface: 'transparent', opacity: 0 }
  },
  tankTypes: {
    10: {
      name: 'Plastic Tank (Empty)',
      material: 'PLASTIC_PP',
      liquid: 'NONE',
      style: 'tank'
    }
  },
  ui: {}
};

// Global cache for palette data
let cachedPalette = null;
let loadPromise = null;

/**
 * Load palette from JSON file (with caching)
 */
async function loadPalette() {
  if (cachedPalette) return cachedPalette;
  
  if (!loadPromise) {
    loadPromise = fetch('/colorPalette.json')
      .then(res => res.json())
      .then(data => {
        cachedPalette = data;
        return data;
      })
      .catch(err => {
        console.warn('Failed to load colorPalette.json, using defaults:', err);
        cachedPalette = DEFAULT_PALETTE;
        return DEFAULT_PALETTE;
      });
  }
  
  return loadPromise;
}

/**
 * Get colors for a tank type from palette
 */
function getTankColorsFromPalette(palette, type) {
  const tankType = palette.tankTypes?.[String(type)] || palette.tankTypes?.['10'];
  
  if (!tankType) {
    return palette.materials?.PLASTIC_PP || DEFAULT_PALETTE.materials.PLASTIC_PP;
  }
  
  // If type has custom colors, use them
  if (tankType.colors) {
    return tankType.colors;
  }
  
  // Otherwise derive from material
  if (tankType.material && palette.materials?.[tankType.material]) {
    return palette.materials[tankType.material];
  }
  
  // Fallback
  return palette.materials?.PLASTIC_PP || DEFAULT_PALETTE.materials.PLASTIC_PP;
}

/**
 * Get liquid colors for a tank type from palette
 */
function getTankLiquidFromPalette(palette, type) {
  const tankType = palette.tankTypes?.[String(type)] || palette.tankTypes?.['10'];
  const liquidName = tankType?.liquid || 'NONE';
  return palette.liquids?.[liquidName] || DEFAULT_PALETTE.liquids.NONE;
}

/**
 * Get tank type info from palette
 */
function getTankTypeFromPalette(palette, type) {
  return palette.tankTypes?.[String(type)] || palette.tankTypes?.['10'] || {
    name: 'Unknown',
    material: 'PLASTIC_PP',
    liquid: 'NONE',
    style: 'tank'
  };
}

/**
 * Hook to use color palette in components
 */
function useColorPalette() {
  const [palette, setPalette] = useState(cachedPalette || DEFAULT_PALETTE);
  const [isLoaded, setIsLoaded] = useState(!!cachedPalette);

  useEffect(() => {
    if (!cachedPalette) {
      loadPalette().then(data => {
        setPalette(data);
        setIsLoaded(true);
      });
    }
  }, []);

  return {
    palette,
    isLoaded,
    getTankColors: (type) => getTankColorsFromPalette(palette, type),
    getTankLiquid: (type) => getTankLiquidFromPalette(palette, type),
    getTankType: (type) => getTankTypeFromPalette(palette, type),
    materials: palette.materials,
    liquids: palette.liquids,
    tankTypes: palette.tankTypes,
    ui: palette.ui
  };
}

// Synchronous getters for components that already have palette loaded
// These use the cached palette directly
export function getTankColors(type) {
  const palette = cachedPalette || DEFAULT_PALETTE;
  return getTankColorsFromPalette(palette, type);
}

export function getTankLiquid(type) {
  const palette = cachedPalette || DEFAULT_PALETTE;
  return getTankLiquidFromPalette(palette, type);
}

export function getTankType(type) {
  const palette = cachedPalette || DEFAULT_PALETTE;
  return getTankTypeFromPalette(palette, type);
}

// Re-export for backwards compatibility
export const TANK_TYPES = new Proxy({}, {
  get: (target, prop) => {
    const palette = cachedPalette || DEFAULT_PALETTE;
    return palette.tankTypes?.[prop];
  }
});

export { loadPalette };
export default useColorPalette;
