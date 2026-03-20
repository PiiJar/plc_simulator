import React from 'react';
import { api } from '../../api/client';
import { DraggablePanel } from '../index';

/**
 * CustomerPanel — Customer/Plant selection, creation, template copy.
 * Extracted from App.jsx V3a.
 * All state is passed as props (prop drilling).
 */
export default function CustomerPanel({
  // Close handler
  onClose,
  // Error display
  customerError, setCustomerError,
  // Customer selection
  selectedCustomer, setSelectedCustomer, customers, setCustomers,
  // Plant selection
  selectedPlant, setSelectedPlant, customerPlants, setCustomerPlants,
  // Create customer
  creatingCustomer, setCreatingCustomer, newCustomerName, setNewCustomerName,
  // Create plant
  creatingPlant, setCreatingPlant, newPlantName, setNewPlantName,
  // Plant status & sim purpose
  plantStatus, setPlantStatus, simPurpose, setSimPurpose,
  simPurposeForm, setSimPurposeForm,
  // Template
  selectedTemplate, setSelectedTemplate, plantSetups,
  copyingTemplate, setCopyingTemplate,
}) {
  return (
    <DraggablePanel title="Customer" onClose={onClose}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12, minWidth: 350 }}>
        {customerError && (
          <div style={{ color: '#c62828', fontWeight: 600, fontSize: 13 }}>{customerError}</div>
        )}

        {/* Select existing customer */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <label style={{ fontWeight: 600, fontSize: 13 }}>Select Customer</label>
          {!creatingCustomer ? (
            <div style={{ display: 'flex', gap: 8 }}>
              <select
                value={selectedCustomer}
                onChange={async (e) => {
                  const newCustomer = e.target.value;
                  setSelectedCustomer(newCustomer);
                  setSelectedPlant('');
                  setPlantStatus(null);
                  setSimPurpose(null);
                  setSimPurposeForm({ country: '', city: '', purpose: '' });
                  setSelectedTemplate('');
                  await api.post('/api/current-selection', { customer: newCustomer || null, plant: null });
                }}
                style={{ flex: 1, padding: 8, borderRadius: 4, border: '1px solid #ccc', fontSize: 13 }}
              >
                <option value="">-- Select customer --</option>
                {customers.map(c => (
                  <option key={c} value={c}>{c}</option>
                ))}
              </select>
              <button
                onClick={() => {
                  setCreatingCustomer(true);
                  setSelectedCustomer('');
                  setSelectedPlant('');
                  setPlantStatus(null);
                  setSimPurpose(null);
                  setSimPurposeForm({ country: '', city: '', purpose: '' });
                  setSelectedTemplate('');
                  api.post('/api/current-selection', { customer: null, plant: null }).catch(err => console.error('Failed to clear selection:', err));
                }}
                style={{
                  padding: '8px 12px', borderRadius: 4, border: 'none',
                  background: '#4caf50', color: '#fff', fontWeight: 600,
                  cursor: 'pointer', fontSize: 13
                }}
              >
                Create
              </button>
            </div>
          ) : (
            <div style={{ display: 'flex', gap: 8 }}>
              <input
                type="text"
                value={newCustomerName}
                onChange={(e) => setNewCustomerName(e.target.value)}
                onKeyDown={async (e) => {
                  if (e.key === 'Enter' && newCustomerName.trim()) {
                    try {
                      const res = await api.post('/api/customers', { name: newCustomerName.trim()
                      });
                      const data = await res.json();
                      if (data.success) {
                        const newCustomer = newCustomerName.trim();
                        setCustomers(prev => [...prev, newCustomer].sort());
                        setSelectedCustomer(newCustomer);
                        setSelectedPlant('');
                        setNewCustomerName('');
                        setCreatingCustomer(false);
                        setCustomerError('');
                        setPlantStatus(null);
                        setSimPurpose(null);
                        setSimPurposeForm({ country: '', city: '', purpose: '' });
                        setSelectedTemplate('');
                        try {
                          await api.post('/api/current-selection', { customer: newCustomer, plant: null });
                        } catch (err) {
                          console.error('Failed to save current selection:', err);
                        }
                      } else {
                        setCustomerError(data.error || 'Failed to create customer');
                      }
                    } catch (error) {
                      setCustomerError('Failed to create customer');
                    }
                  } else if (e.key === 'Escape') {
                    setCreatingCustomer(false);
                    setNewCustomerName('');
                  }
                }}
                placeholder="Customer name (Enter to save, Esc to cancel)"
                autoFocus
                style={{ flex: 1, padding: 8, borderRadius: 4, border: '1px solid #4caf50', fontSize: 13 }}
              />
              <button
                onClick={() => {
                  setCreatingCustomer(false);
                  setNewCustomerName('');
                }}
                style={{
                  padding: '8px 12px', borderRadius: 4, border: 'none',
                  background: '#9e9e9e', color: '#fff', fontWeight: 600,
                  cursor: 'pointer', fontSize: 13
                }}
              >
                Cancel
              </button>
            </div>
          )}
        </div>

        {/* Select plant if customer selected */}
        {selectedCustomer && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <label style={{ fontWeight: 600, fontSize: 13 }}>Select Plant</label>
            {!creatingPlant ? (
              <div style={{ display: 'flex', gap: 8 }}>
                <select
                  value={selectedPlant}
                  onChange={(e) => setSelectedPlant(e.target.value)}
                  style={{ flex: 1, padding: 8, borderRadius: 4, border: '1px solid #ccc', fontSize: 13 }}
                >
                  <option value="">-- Select plant --</option>
                  {customerPlants.map(p => (
                    <option key={p} value={p}>{p}</option>
                  ))}
                </select>
                <button
                  onClick={() => setCreatingPlant(true)}
                  style={{
                    padding: '8px 12px', borderRadius: 4, border: 'none',
                    background: '#4caf50', color: '#fff', fontWeight: 600,
                    cursor: 'pointer', fontSize: 13
                  }}
                >
                  Create
                </button>
              </div>
            ) : (
              <div style={{ display: 'flex', gap: 8 }}>
                <input
                  type="text"
                  value={newPlantName}
                  onChange={(e) => setNewPlantName(e.target.value)}
                  onKeyDown={async (e) => {
                    if (e.key === 'Enter' && newPlantName.trim()) {
                      try {
                        const res = await api.post(`/api/customers/${encodeURIComponent(selectedCustomer)}/plants`, { name: newPlantName.trim()
                        });
                        const data = await res.json();
                        if (data.success) {
                          setCustomerPlants(prev => [...prev, newPlantName.trim()].sort());
                          setSelectedPlant(newPlantName.trim());
                          setNewPlantName('');
                          setCreatingPlant(false);
                          setCustomerError('');
                        } else {
                          setCustomerError(data.error || 'Failed to create plant');
                        }
                      } catch (error) {
                        setCustomerError('Failed to create plant');
                      }
                    } else if (e.key === 'Escape') {
                      setCreatingPlant(false);
                      setNewPlantName('');
                    }
                  }}
                  placeholder="Plant name (Enter to save, Esc to cancel)"
                  autoFocus
                  style={{ flex: 1, padding: 8, borderRadius: 4, border: '1px solid #4caf50', fontSize: 13 }}
                />
                <button
                  onClick={() => {
                    setCreatingPlant(false);
                    setNewPlantName('');
                  }}
                  style={{
                    padding: '8px 12px', borderRadius: 4, border: 'none',
                    background: '#9e9e9e', color: '#fff', fontWeight: 600,
                    cursor: 'pointer', fontSize: 13
                  }}
                >
                  Cancel
                </button>
              </div>
            )}
          </div>
        )}

        {/* Country and City fields */}
        {selectedCustomer && selectedPlant && (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <label style={{ fontWeight: 600, fontSize: 12 }}>Country</label>
              <input
                type="text"
                value={simPurposeForm.country}
                onChange={(e) => setSimPurposeForm(prev => ({ ...prev, country: e.target.value }))}
                placeholder="Country"
                style={{ padding: 8, borderRadius: 4, border: '1px solid #ccc', fontSize: 13 }}
              />
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <label style={{ fontWeight: 600, fontSize: 12 }}>City</label>
              <input
                type="text"
                value={simPurposeForm.city}
                onChange={(e) => setSimPurposeForm(prev => ({ ...prev, city: e.target.value }))}
                placeholder="City"
                style={{ padding: 8, borderRadius: 4, border: '1px solid #ccc', fontSize: 13 }}
              />
            </div>
          </div>
        )}

        {/* Setup template selection */}
        {selectedCustomer && selectedPlant && plantStatus && !plantStatus.isConfigured && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <label style={{ fontWeight: 600, fontSize: 13 }}>Setup Template</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <select
                value={selectedTemplate}
                onChange={(e) => setSelectedTemplate(e.target.value)}
                style={{ flex: 1, padding: 8, borderRadius: 4, border: '1px solid #ccc', fontSize: 13 }}
              >
                <option value="">-- Select template --</option>
                {plantSetups.map(t => (
                  <option key={t} value={t}>{t}</option>
                ))}
              </select>
              <button
                onClick={async () => {
                  if (!selectedTemplate) return;
                  setCopyingTemplate(true);
                  try {
                    const res = await api.get(
                      `/api/customers/${encodeURIComponent(selectedCustomer)}/plants/${encodeURIComponent(selectedPlant)}/copy-template`,
                      {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({
                          template: selectedTemplate,
                          customer: selectedCustomer,
                          plant: selectedPlant,
                          country: simPurposeForm.country,
                          city: simPurposeForm.city
                        })
                      }
                    );
                    const data = await res.json();
                    if (data.success) {
                      const statusRes = await api.get(`/api/customers/${encodeURIComponent(selectedCustomer)}/plants/${encodeURIComponent(selectedPlant)}/status`);
                      const statusData = await statusRes.json();
                      if (statusData.success) {
                        setPlantStatus(statusData);
                      }
                      const purposeRes = await api.get(`/api/customers/${encodeURIComponent(selectedCustomer)}/plants/${encodeURIComponent(selectedPlant)}/simulation-purpose`);
                      const purposeData = await purposeRes.json();
                      if (purposeData.success) {
                        setSimPurpose(purposeData.data);
                        setSimPurposeForm({
                          country: purposeData.data.plant?.country || '',
                          city: purposeData.data.plant?.town || '',
                          purpose: purposeData.data.purpose || ''
                        });
                      }
                      setSelectedTemplate('');
                      setCustomerError('');
                    } else {
                      setCustomerError(data.error || 'Failed to copy template');
                    }
                  } catch (error) {
                    setCustomerError('Failed to copy template');
                  }
                  setCopyingTemplate(false);
                }}
                disabled={!selectedTemplate || copyingTemplate}
                style={{
                  padding: '8px 12px', borderRadius: 4, border: 'none',
                  background: (!selectedTemplate || copyingTemplate) ? '#ccc' : '#4caf50',
                  color: '#fff', fontWeight: 600,
                  cursor: (!selectedTemplate || copyingTemplate) ? 'not-allowed' : 'pointer',
                  fontSize: 13
                }}
              >
                {copyingTemplate ? 'Copying...' : 'Copy'}
              </button>
            </div>
          </div>
        )}

        {/* Current selection summary */}
        {selectedCustomer && selectedPlant && plantStatus && (
          <div style={{
            padding: 12,
            background: plantStatus.isConfigured ? '#e8f5e9' : '#fff3e0',
            border: `1px solid ${plantStatus.isConfigured ? '#a5d6a7' : '#ffcc80'}`,
            borderRadius: 4, fontSize: 13, marginTop: 8
          }}>
            <div style={{ fontWeight: 700, marginBottom: 4 }}>
              {selectedCustomer} / {selectedPlant}
            </div>
            {plantStatus.isConfigured ? (
              <div style={{ color: '#2e7d32' }}>
                {plantStatus.analysis?.summary}
              </div>
            ) : (
              <div style={{ color: '#e65100' }}>
                Not configured
              </div>
            )}
          </div>
        )}
      </div>
    </DraggablePanel>
  );
}
