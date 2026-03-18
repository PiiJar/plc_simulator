// src/api/client.js

export async function request(url, options = {}) {
  const headers = {
    'Content-Type': 'application/json',
    ...options.headers,
  };

  const response = await fetch(url, {
    ...options,
    headers,
  });

  if (!response.ok) {
    let errorMessage = `HTTP error! status: ${response.status}`;
    try {
      const errorData = await response.json();
      if (errorData && errorData.error) {
        errorMessage = errorData.error;
      }
    } catch (e) {
      // Ignorataan json-parsintavirhe, käytetään alkuperäistä statusta
    }
    throw new Error(errorMessage);
  }

  // Jos status on 204 (No Content), palautetaan null
  if (response.status === 204) {
    return null;
  }

  return response.json();
}

export const api = {
  get: (url, options = {}) => request(url, { ...options, method: 'GET' }),
  post: (url, data, options = {}) => request(url, { ...options, method: 'POST', body: JSON.stringify(data) }),
  put: (url, data, options = {}) => request(url, { ...options, method: 'PUT', body: JSON.stringify(data) }),
  delete: (url, options = {}) => request(url, { ...options, method: 'DELETE' }),
};
