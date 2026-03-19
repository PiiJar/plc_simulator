/**
 * api/client.js — Thin fetch wrapper
 * Returns native Response object, no logic changes.
 * Centralizes JSON serialization for POST/PUT bodies.
 */

async function request(url, { method = 'GET', body, headers, ...opts } = {}) {
  const config = { method, ...opts };
  if (body !== undefined) {
    config.headers = { 'Content-Type': 'application/json', ...headers };
    config.body = typeof body === 'string' ? body : JSON.stringify(body);
  } else if (headers) {
    config.headers = headers;
  }
  return fetch(url, config);
}

export const api = {
  get:     (url, opts) => request(url, { method: 'GET', ...opts }),
  post:    (url, body, opts) => request(url, { method: 'POST', body, ...opts }),
  put:     (url, body, opts) => request(url, { method: 'PUT', body, ...opts }),
  delete:  (url, opts) => request(url, { method: 'DELETE', ...opts }),
  request, // for dynamic method cases
};
