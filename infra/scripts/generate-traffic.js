#!/usr/bin/env node
'use strict';

/**
 * Traffic generator for Kiali visualization.
 * Sends continuous HTTP requests to all yas services so Kiali
 * can display the service mesh topology with mTLS lock icons.
 *
 * Usage:
 *   node infra/scripts/generate-traffic.js
 *
 * Env vars:
 *   YAS_DOMAIN           - base domain (default: yas.local.com)
 *   YAS_INTERVAL_MS      - ms between request rounds (default: 2000)
 *   YAS_HTTP_TIMEOUT_MS  - per-request timeout (default: 8000)
 */

const http = require('node:http');
const https = require('node:https');
const { URL } = require('node:url');

const domain = process.env.YAS_DOMAIN || 'yas.local.com';
const intervalMs = Number(process.env.YAS_INTERVAL_MS || 2000);
const timeoutMs = Number(process.env.YAS_HTTP_TIMEOUT_MS || 8000);
const keycloakTokenUrl = `http://identity.${domain}/realms/Yas/protocol/openid-connect/token`;
const clientId = 'storefront-bff';
const clientSecret = 'ZrU9I0q2uXBglBnmvyJdkl1lf0ncr8tn';
const username = 'admin';
const password = 'admin';

// Token state
let accessToken = null;
let tokenExpiresAt = 0;

function buildEndpoints() {
  return [
    // Public / no-auth endpoints
    { name: 'storefront',       url: `http://storefront.${domain}/`,                                                                                   auth: false },
    { name: 'backoffice',       url: `http://backoffice.${domain}/`,                                                                                   auth: false },
    { name: 'api-swagger',      url: `http://api.${domain}/swagger-ui/`,                                                                               auth: false },
    { name: 'identity-oidc',    url: `http://identity.${domain}/realms/Yas/.well-known/openid-configuration`,                                          auth: false },
    { name: 'grafana',          url: `http://grafana.${domain}/api/health`,                                                                            auth: false },
    { name: 'prometheus',       url: `http://prometheus.${domain}/-/healthy`,                                                                          auth: false },
    { name: 'kiali',            url: `http://kiali.${domain}/kiali/api/namespaces`,                                                                    auth: false },
    { name: 'api-search',       url: `http://api.${domain}/search/storefront/catalog-search?keyword=shirt`,                                            auth: false },
    { name: 'api-product',      url: `http://api.${domain}/product/storefront/products/featured?pageNo=0`,                                             auth: false },
    { name: 'api-category',     url: `http://api.${domain}/product/storefront/categories`,                                                             auth: false },
    // Authenticated endpoints (JWT required)
    { name: 'api-product-bo',   url: `http://api.${domain}/product/backoffice/products?pageNo=0&pageSize=5`,                                           auth: true  },
    { name: 'api-cart',         url: `http://api.${domain}/cart/storefront/cart/items`,                                                                auth: true  },
    { name: 'api-customer',     url: `http://api.${domain}/customer/backoffice/customers?pageNo=0&pageSize=5`,                                         auth: true  },
    { name: 'api-inventory',    url: `http://api.${domain}/inventory/backoffice/warehouses/paging?pageNo=0&pageSize=5`,                                  auth: true  },
    { name: 'api-tax',          url: `http://api.${domain}/tax/backoffice/tax-classes/paging?pageNo=0&pageSize=5`,                                     auth: true  },
    { name: 'api-order',        url: `http://api.${domain}/order/storefront/orders/my-orders?productName=`,                                            auth: true  },
    { name: 'api-media',        url: `http://api.${domain}/media/medias?ids=1`,                                                                        auth: true  },
  ];
}

async function getToken() {
  const now = Date.now();
  if (accessToken && now < tokenExpiresAt - 30000) return accessToken;

  return new Promise((resolve) => {
    const body = new URLSearchParams({
      grant_type: 'password',
      client_id: clientId,
      client_secret: clientSecret,
      username,
      password,
      scope: 'openid',
    }).toString();

    const url = new URL(keycloakTokenUrl);
    const req = http.request(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          if (json.access_token) {
            accessToken = json.access_token;
            tokenExpiresAt = Date.now() + (json.expires_in || 300) * 1000;
            resolve(accessToken);
          } else {
            console.error('  TOKEN FAIL:', json.error_description || JSON.stringify(json));
            resolve(null);
          }
        } catch (e) {
          console.error('  TOKEN PARSE ERROR:', e.message);
          resolve(null);
        }
      });
    });
    req.on('error', (e) => { console.error('  TOKEN REQ ERROR:', e.message); resolve(null); });
    req.write(body);
    req.end();
  });
}

function get(urlString, authHeader) {
  return new Promise((resolve) => {
    try {
      const url = new URL(urlString);
      const transport = url.protocol === 'https:' ? https : http;
      const headers = { 'User-Agent': 'yas-traffic-gen/1.0' };
      if (authHeader) headers['Authorization'] = authHeader;
      const req = transport.request(url, { method: 'GET', headers }, (res) => {
        res.resume();
        res.on('end', () => resolve({ status: res.statusCode, ok: true }));
      });
      req.on('error', (e) => resolve({ status: 0, ok: false, error: e.message }));
      req.setTimeout(timeoutMs, () => {
        req.destroy();
        resolve({ status: 0, ok: false, error: 'timeout' });
      });
      req.end();
    } catch (e) {
      resolve({ status: 0, ok: false, error: e.message });
    }
  });
}

let round = 0;

async function runRound() {
  round++;
  const token = await getToken();
  const bearerHeader = token ? `Bearer ${token}` : null;
  const endpoints = buildEndpoints();

  const results = await Promise.all(endpoints.map(async (ep) => {
    const r = await get(ep.url, ep.auth ? bearerHeader : null);
    return { name: ep.name, ...r };
  }));

  const ok = results.filter(r => r.status >= 200 && r.status < 400).length;
  const fail = results.filter(r => r.status === 0 || r.status >= 500).length;
  const redirect = results.filter(r => r.status >= 300 && r.status < 400).length;
  const auth = results.filter(r => r.status === 401 || r.status === 403).length;

  const ts = new Date().toLocaleTimeString();
  console.log(`[${ts}] Round ${round} — ${ok} OK, ${redirect} redirect/auth-redirect, ${auth} auth-blocked, ${fail} fail`);

  if (auth > 0) {
    results.filter(r => r.status === 401 || r.status === 403)
      .forEach(r => console.log(`  AUTH-BLOCKED ${r.name}: ${r.status}`));
  }
  if (fail > 0) {
    results.filter(r => r.status === 0 || r.status >= 500)
      .forEach(r => console.log(`  FAIL ${r.name}: ${r.error || r.status}`));
  }
}

const endpoints = buildEndpoints();
console.log(`Traffic generator started — domain: ${domain}, interval: ${intervalMs}ms`);
console.log(`Hitting ${endpoints.length} endpoints (${endpoints.filter(e => e.auth).length} with JWT). Press Ctrl+C to stop.\n`);
console.log('Fetching initial Keycloak token...');

runRound();
setInterval(runRound, intervalMs);
