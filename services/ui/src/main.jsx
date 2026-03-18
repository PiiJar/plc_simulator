import "./styles/index.css";
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App.jsx';
import { UiPanelsProvider } from './context/UiPanelsContext.jsx';
import { PlantProvider } from './context/PlantContext.jsx';

const rootEl = document.getElementById('root');

if (rootEl) {
  const root = ReactDOM.createRoot(rootEl);
  root.render(<PlantProvider>
    <UiPanelsProvider>
      <App />
    </UiPanelsProvider>
    </PlantProvider>);
}
