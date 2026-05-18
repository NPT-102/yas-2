#!/usr/bin/env node
'use strict';

const { execFileSync } = require('node:child_process');

const config = {
  kubectl: process.env.KUBECTL_BIN || 'kubectl',
  namespace: process.env.YAS_NAMESPACE || 'yas',
  meshNamespace: process.env.YAS_MESH_NAMESPACE || 'istio-system',
  observabilityNamespaces: (process.env.YAS_OBSERVABILITY_NAMESPACES || 'istio-system,observability')
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean),
  requireMesh: process.env.YAS_REQUIRE_MESH !== 'false',
  requireObservability: process.env.YAS_REQUIRE_OBSERVABILITY !== 'false',
};

const coreDeployments = [
  'product',
  'cart',
  'order',
  'customer',
  'inventory',
  'tax',
  'media',
  'search',
  'storefront-bff',
  'storefront-ui',
  'backoffice-bff',
  'backoffice-ui',
  'swagger-ui',
];

function runKubectl(args) {
  try {
    return execFileSync(config.kubectl, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch (error) {
    const stderr = error && error.stderr ? error.stderr.toString('utf8').trim() : '';
    throw new Error(`kubectl ${args.join(' ')} failed${stderr ? `: ${stderr}` : ''}`);
  }
}

function runJson(args, context) {
  try {
    return JSON.parse(runKubectl(args));
  } catch (error) {
    throw new Error(`Failed to read ${context}: ${error.message}`);
  }
}

function selectorFrom(matchLabels) {
  return Object.entries(matchLabels || {})
    .map(([key, value]) => `${key}=${value}`)
    .join(',');
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function checkNamespace(namespace) {
  runKubectl(['get', 'namespace', namespace, '-o', 'json']);
  console.log(`OK namespace ${namespace}`);
}

function checkDeployment(name) {
  const deployment = runJson(['-n', config.namespace, 'get', 'deployment', name, '-o', 'json'], `deployment ${name}`);
  const availableReplicas = deployment.status?.availableReplicas || 0;
  assert(availableReplicas > 0, `Deployment ${name} has no available replicas`);

  const selector = selectorFrom(deployment.spec?.selector?.matchLabels);
  assert(selector, `Deployment ${name} has no selector labels`);

  const pods = runJson(['-n', config.namespace, 'get', 'pods', '-l', selector, '-o', 'json'], `pods for ${name}`).items || [];
  assert(pods.length > 0, `Deployment ${name} has no pods for selector ${selector}`);

  const readyPods = pods.filter((pod) => {
    const statuses = pod.status?.containerStatuses || [];
    return pod.status?.phase === 'Running' && statuses.length > 0 && statuses.every((status) => status.ready);
  });
  assert(readyPods.length > 0, `Deployment ${name} has no ready pods`);

  if (config.requireMesh) {
    const missingSidecar = pods.filter((pod) => !(pod.spec?.containers || []).some((container) => container.name === 'istio-proxy'));
    assert(missingSidecar.length === 0, `Deployment ${name} has pods without istio-proxy: ${missingSidecar.map((pod) => pod.metadata?.name).join(', ')}`);
  }

  console.log(`OK deployment ${name}`);
}

function checkAliasService(name, targetService) {
  const service = runJson(['-n', config.namespace, 'get', 'service', name, '-o', 'json'], `service ${name}`);
  const expectedExternalName = `${targetService}.${config.namespace}.svc.cluster.local`;
  assert(service.spec?.type === 'ExternalName', `Service ${name} is not ExternalName`);
  assert(service.spec?.externalName === expectedExternalName, `Service ${name} points to ${service.spec?.externalName || '<none>'}, expected ${expectedExternalName}`);
  console.log(`OK service ${name}`);
}

function checkIstio() {
  checkNamespace(config.meshNamespace);

  const istiod = runJson(['-n', config.meshNamespace, 'get', 'deployment', 'istiod', '-o', 'json'], 'istiod deployment');
  assert((istiod.status?.availableReplicas || 0) > 0, 'Istiod has no available replicas');

  const ingressGateway = runJson(['-n', config.meshNamespace, 'get', 'service', 'istio-ingressgateway', '-o', 'json'], 'istio-ingressgateway service');
  assert(ingressGateway.metadata?.name === 'istio-ingressgateway', 'Istio ingress gateway service is missing');

  const kialiService = runJson(['-n', config.meshNamespace, 'get', 'service', 'kiali', '-o', 'json'], 'kiali service');
  assert(kialiService.metadata?.name === 'kiali', 'Kiali service is missing');

  console.log(`OK mesh namespace ${config.meshNamespace}`);
}

function podsInNamespace(namespace) {
  return runJson(['-n', namespace, 'get', 'pods', '-o', 'json'], `${namespace} pods`).items || [];
}

function checkObservability() {
  const requiredPatterns = ['grafana', 'prometheus', 'kiali', 'loki', 'tempo', 'otel'];
  const podIndex = [];

  for (const namespace of config.observabilityNamespaces) {
    try {
      checkNamespace(namespace);
      const pods = podsInNamespace(namespace);
      for (const pod of pods) {
        podIndex.push({
          namespace,
          name: pod.metadata?.name || '',
        });
      }
    } catch (error) {
      // Ignore a missing namespace if the stack is split across multiple namespaces.
    }
  }

  assert(podIndex.length > 0, `No observability pods found in namespaces: ${config.observabilityNamespaces.join(', ')}`);

  for (const pattern of requiredPatterns) {
    assert(
      podIndex.some((pod) => pod.name.includes(pattern)),
      `Missing observability pod matching "${pattern}" in namespaces: ${config.observabilityNamespaces.join(', ')}`,
    );
  }

  console.log(`OK observability namespaces ${config.observabilityNamespaces.join(', ')}`);
}

function main() {
  console.log(`Using kubectl context: ${runKubectl(['config', 'current-context'])}`);
  checkNamespace(config.namespace);

  for (const deployment of coreDeployments) {
    checkDeployment(deployment);
  }

  checkAliasService('storefront-nextjs', 'storefront-ui');

  if (config.requireMesh) {
    checkIstio();
  }

  if (config.requireObservability) {
    checkObservability();
  }

  console.log('All stack checks passed.');
}

try {
  main();
} catch (error) {
  console.error(`Validation failed: ${error.message}`);
  process.exitCode = 1;
}