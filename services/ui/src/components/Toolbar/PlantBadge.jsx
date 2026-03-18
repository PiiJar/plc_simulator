import React from 'react';

export default function PlantBadge({ customer, plant, status }) {
  if (!customer || !plant) {
    return (
      <div style={{ marginLeft: 16, padding: '4px 12px', background: '#ffebee', borderRadius: 16, color: '#c62828', fontSize: 13, fontWeight: 600 }}>
        No Plant Selected
      </div>
    );
  }

  return (
    <div style={{ marginLeft: 16, display: 'flex', flexDirection: 'column' }}>
      <div style={{ fontSize: 14, fontWeight: 600, color: '#333' }}>
        {customer} / {plant}
      </div>
      <div style={{ fontSize: 11, color: '#666', display: 'flex', gap: 12 }}>
        {status?.plant_id && <span>Plant ID: {status.plant_id.substring(0, 8)}</span>}
        {status?.revision && <span>Rev: {status.revision}</span>}
      </div>
    </div>
  );
}
