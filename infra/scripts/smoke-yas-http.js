#!/usr/bin/env node
'use strict';

const http = require('node:http');
const https = require('node:https');
const { URL } = require('node:url');

const domain = process.env.YAS_DOMAIN || 'yas.local.com';
const timeoutMs = Number(process.env.YAS_HTTP_TIMEOUT_MS || 10000);
const maxRedirects = Number(process.env.YAS_HTTP_MAX_REDIRECTS || 5);
const includeExtraApps = process.env.YAS_CHECK_EXTRA_APPS === 'true';

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function defaultEndpoints() {
  const endpoints = [
    {
      name: 'storefront',
      url: `http://storefront.${domain}`,
    },
    {
      name: 'backoffice',
      url: `http://backoffice.${domain}`,
    },
    {
      name: 'api',
      url: `http://api.${domain}`,
    },
    {
      name: 'identity-openid',
      url: `http://identity.${domain}/realms/Yas/.well-known/openid-configuration`,
      bodyIncludes: ['issuer'],
    },
    {
      name: 'grafana',
      url: `http://grafana.${domain}`,
    },
    {
      name: 'prometheus',
      url: `http://prometheus.${domain}`,
    },
    {
      name: 'kiali',
      url: `http://kiali.${domain}`,
    },
  ];

  if (includeExtraApps) {
    endpoints.push(
      {
        name: 'pgadmin',
        url: `http://pgadmin.${domain}`,
      },
      {
        name: 'akhq',
        url: `http://akhq.${domain}`,
      },
    );
  }

  return endpoints;
}

function loadEndpoints() {
  const raw = process.env.YAS_SMOKE_ENDPOINTS_JSON;
  if (!raw) {
    return defaultEndpoints();
  }

  const parsed = JSON.parse(raw);
  assert(Array.isArray(parsed), 'YAS_SMOKE_ENDPOINTS_JSON must be a JSON array');
  return parsed.map((entry, index) => {
    assert(entry && typeof entry === 'object', `Endpoint ${index} must be an object`);
    assert(typeof entry.name === 'string' && entry.name.length > 0, `Endpoint ${index} is missing a name`);
    assert(typeof entry.url === 'string' && entry.url.length > 0, `Endpoint ${entry.name} is missing a url`);
    return {
      name: entry.name,
      url: entry.url,
      bodyIncludes: Array.isArray(entry.bodyIncludes) ? entry.bodyIncludes : [],
    };
  });
}

function requestUrl(urlString, redirectsRemaining = maxRedirects) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlString);
    const transport = url.protocol === 'https:' ? https : http;

    const request = transport.request(
      url,
      {
        method: 'GET',
        headers: {
          'User-Agent': 'yas-smoke-test/1.0',
        },
      },
      (response) => {
        const chunks = [];

        response.on('data', (chunk) => {
          chunks.push(chunk);
        });

        response.on('end', async () => {
          const statusCode = response.statusCode || 0;
          const body = Buffer.concat(chunks).toString('utf8');
          const location = response.headers.location;

          if ([301, 302, 303, 307, 308].includes(statusCode) && location && redirectsRemaining > 0) {
            try {
              const nextUrl = new URL(location, url).toString();
              const redirected = await requestUrl(nextUrl, redirectsRemaining - 1);
              resolve({
                ...redirected,
                redirectCount: (redirected.redirectCount || 0) + 1,
              });
            } catch (error) {
              reject(error);
            }
            return;
          }

          resolve({
            statusCode,
            body,
            finalUrl: url.toString(),
            redirectCount: 0,
          });
        });
      },
    );

    request.on('error', reject);
    request.setTimeout(timeoutMs, () => {
      request.destroy(new Error(`Request timed out after ${timeoutMs}ms: ${urlString}`));
    });
    request.end();
  });
}

async function main() {
  const endpoints = loadEndpoints();
  console.log(`Running HTTP smoke checks against ${domain}`);

  for (const endpoint of endpoints) {
    const result = await requestUrl(endpoint.url);
    assert(result.statusCode >= 200 && result.statusCode < 400, `${endpoint.name} returned ${result.statusCode} for ${endpoint.url}`);

    for (const needle of endpoint.bodyIncludes) {
      assert(result.body.includes(needle), `${endpoint.name} response does not include "${needle}"`);
    }

    console.log(`OK ${endpoint.name}: ${result.statusCode} ${result.finalUrl}`);
  }

  console.log('All HTTP smoke checks passed.');
}

main().catch((error) => {
  console.error(`Smoke test failed: ${error.message}`);
  process.exitCode = 1;
});