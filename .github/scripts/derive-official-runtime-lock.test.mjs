#!/usr/bin/env node

import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

const moduleRoot = resolve(argument('--module-root') ?? process.env.DSH_OFFICIAL_SOURCE_ROOT ?? '.');
const requireFromRoot = createRequire(join(moduleRoot, 'package.json'));
const yamlEntry = requireFromRoot.resolve('js-yaml');
const yamlRoot = dirname(yamlEntry);
const { dump: dumpYaml } = requireFromRoot('js-yaml');
const script = resolve(import.meta.dirname, 'derive-official-runtime-lock.mjs');
const testRoot = mkdtempSync(join(tmpdir(), 'dsh-derive-runtime-lock-'));

function packageRecord(name, version) {
  return {
    [`${name}@${version}`]: {
      resolution: { integrity: `sha512-${name.replaceAll('/', '-')}-${version}` },
    },
  };
}

function manifest(name, version, directory, extra = {}) {
  return {
    name,
    version,
    repository: { directory },
    ...extra,
  };
}

function importerEntry(specifier, version) {
  return { specifier, version };
}

function runDerive(source, manifestsPath, candidatePath, outputPath, normalize = false) {
  const args = [script, '--source-root', source, '--runtime-manifests', manifestsPath];
  if (candidatePath) {
    args.push('--candidate-lock', candidatePath);
    if (normalize) args.push('--normalize-candidate-lock');
  }
  args.push('--output', outputPath);
  return spawnSync(process.execPath, args, { encoding: 'utf8' });
}

function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

try {
  const source = join(testRoot, 'source');
  mkdirSync(join(source, 'node_modules'), { recursive: true });
  cpSync(yamlRoot, join(source, 'node_modules', 'js-yaml'), { recursive: true });
  writeJson(join(source, 'package.json'), { name: 'fixture', private: true });

  const dsh = manifest('@deepseek-ai/dsh', '1.0.0', 'apps/cli', {
    dependencies: {
      '@deepseek-ai/dsh-helper': '1.0.0',
      'alias-edge': 'npm:real-alias@1.0.0',
      'optional-peer': '2.0.0',
      'patched': '1.0.0',
      'peerful': '1.0.0',
      'pkg-00': '1.0.0',
    },
    optionalDependencies: {
      '@deepseek-ai/node-addon-landlock-run-linux-x64': '1.0.0',
    },
  });
  const helper = manifest('@deepseek-ai/dsh-helper', '1.0.0', 'packages/helper', {
    peerDependencies: { 'optional-peer': '^1.0.0' },
    peerDependenciesMeta: { 'optional-peer': { optional: true } },
  });
  const landlock = manifest('@deepseek-ai/node-addon-landlock-run-linux-x64', '1.0.0', 'native/linux-x64', {
    os: ['linux'],
    cpu: ['x64'],
  });
  for (const item of [dsh, helper, landlock]) {
    const path = join(source, item.repository.directory);
    mkdirSync(path, { recursive: true });
    writeJson(join(path, 'package.json'), item);
  }

  const packages = {};
  const snapshots = {};
  for (let index = 0; index < 55; index++) {
    const name = `pkg-${String(index).padStart(2, '0')}`;
    Object.assign(packages, packageRecord(name, '1.0.0'));
    snapshots[`${name}@1.0.0`] = index === 54 ? {} : {
      dependencies: { [`pkg-${String(index + 1).padStart(2, '0')}`]: '1.0.0' },
    };
  }
  Object.assign(packages['pkg-00@1.0.0'], {
    cpu: ['x64'],
    engines: { node: '>=22' },
    hasBin: true,
    libc: ['glibc'],
    os: ['win32'],
    peerDependencies: { 'peer-base': '^1.0.0' },
    peerDependenciesMeta: { 'peer-base': { optional: true } },
  });
  snapshots['pkg-00@1.0.0'].dependencies['peer-base'] = '1.0.0';
  snapshots['pkg-00@1.0.0'].dependencies['optional-peer'] = '1.0.0';
  Object.assign(packages, packageRecord('real-alias', '1.0.0'));
  snapshots['real-alias@1.0.0'] = {};
  Object.assign(packages, packageRecord('optional-peer', '1.0.0'));
  Object.assign(packages, packageRecord('optional-peer', '2.0.0'));
  snapshots['optional-peer@1.0.0'] = {};
  snapshots['optional-peer@2.0.0'] = {};
  Object.assign(packages, packageRecord('peer-base', '1.0.0'));
  snapshots['peer-base@1.0.0'] = {};
  Object.assign(packages, packageRecord('peerful', '1.0.0'));
  packages['peerful@1.0.0'].peerDependencies = { 'peer-base': '^1.0.0' };
  snapshots['peerful@1.0.0(peer-base@1.0.0)'] = {
    dependencies: { 'peer-base': '1.0.0' },
    transitivePeerDependencies: ['zod'],
  };
  Object.assign(packages, packageRecord('patched', '1.0.0'));
  snapshots['patched@1.0.0(patch_hash=fixture)'] = { optional: true };

  const importers = {
    'apps/cli': {
      dependencies: {
        '@deepseek-ai/dsh-helper': importerEntry('1.0.0', 'link:../../packages/helper'),
        'alias-edge': importerEntry('npm:real-alias@1.0.0', 'npm:real-alias@1.0.0'),
        'optional-peer': importerEntry('2.0.0', '2.0.0'),
        'patched': importerEntry('1.0.0', '1.0.0(patch_hash=fixture)'),
        'peerful': importerEntry('1.0.0', '1.0.0(peer-base@1.0.0)'),
        'pkg-00': importerEntry('1.0.0', '1.0.0'),
      },
      optionalDependencies: {
        '@deepseek-ai/node-addon-landlock-run-linux-x64': importerEntry('1.0.0', 'link:../../native/linux-x64'),
      },
    },
    'packages/helper': {
      dependencies: {
        'optional-peer': importerEntry('^1.0.0', '1.0.0'),
      },
    },
    'native/linux-x64': {},
  };
  const lockSettings = { autoInstallPeers: true, excludeLinksFromLockfile: false };
  const patchedDependencies = { 'patched@1.0.0': 'fixture-patch-hash' };
  const sourceLock = {
    lockfileVersion: '9.0',
    settings: lockSettings,
    overrides: { fixture: '1.0.0' },
    patchedDependencies,
    importers,
    packages,
    snapshots,
  };
  writeFileSync(join(source, 'pnpm-lock.yaml'), dumpYaml(sourceLock, { lineWidth: -1, noRefs: true }));

  const manifests = [dsh, helper];
  const manifestsPath = join(testRoot, 'manifests.json');
  writeJson(manifestsPath, manifests);
  const sourceOnlyOutput = join(testRoot, 'source-derived.json');
  const sourceOnlyResult = runDerive(source, manifestsPath, undefined, sourceOnlyOutput);
  assert(sourceOnlyResult.status === 0, `source fixture failed:\n${sourceOnlyResult.stdout}\n${sourceOnlyResult.stderr}`);
  const sourceDerived = JSON.parse(readFileSync(sourceOnlyOutput, 'utf8'));
  const dshFile = '../packages/dsh.tgz';
  const helperFile = '../packages/helper.tgz';
  const candidatePackages = structuredClone(packages);
  const candidateSnapshots = structuredClone(snapshots);
  candidatePackages[`@deepseek-ai/dsh@file:${dshFile}`] = {
    resolution: { integrity: 'sha512-dsh', tarball: `file:${dshFile}` },
    version: '1.0.0',
  };
  candidatePackages[`@deepseek-ai/dsh-helper@file:${helperFile}`] = {
    resolution: { integrity: 'sha512-helper', tarball: `file:${helperFile}` },
    version: '1.0.0',
    peerDependencies: { 'optional-peer': '^1.0.0' },
    peerDependenciesMeta: { 'optional-peer': { optional: true } },
  };
  candidatePackages['@deepseek-ai/node-addon-landlock-run-linux-x64@1.0.0'] = {
    resolution: { integrity: 'sha512-landlock' },
  };
  const dshSnapshotKey = `@deepseek-ai/dsh@file:${dshFile}(peer-base@1.0.0)`;
  const helperSnapshotKey = `@deepseek-ai/dsh-helper@file:${helperFile}`;
  const landlockSnapshotKey = '@deepseek-ai/node-addon-landlock-run-linux-x64@1.0.0';
  candidateSnapshots[dshSnapshotKey] = {
    dependencies: {
      '@deepseek-ai/dsh-helper': `file:${helperFile}`,
      'alias-edge': 'npm:real-alias@1.0.0',
      'optional-peer': '2.0.0',
      'patched': '1.0.0(patch_hash=fixture)',
      'peerful': '1.0.0(peer-base@1.0.0)',
      'pkg-00': '1.0.0',
    },
    optionalDependencies: {
      '@deepseek-ai/node-addon-landlock-run-linux-x64': '1.0.0',
    },
  };
  candidateSnapshots[helperSnapshotKey] = {
    optionalDependencies: { 'optional-peer': '1.0.0' },
  };
  candidateSnapshots[landlockSnapshotKey] = { optional: true };
  const rootDependencies = {
    '@deepseek-ai/dsh': importerEntry(`file:${dshFile}`, dshSnapshotKey.slice('@deepseek-ai/dsh@'.length)),
    '@deepseek-ai/dsh-helper': importerEntry(`file:${helperFile}`, helperSnapshotKey.slice('@deepseek-ai/dsh-helper@'.length)),
  };
  for (const [name, version] of Object.entries(sourceDerived.consumerPeerPins)) {
    rootDependencies[name] = importerEntry(version, version);
  }
  const candidate = {
    lockfileVersion: '9.0',
    settings: lockSettings,
    overrides: {
      ...sourceDerived.consumerOverrides,
      '@deepseek-ai/dsh': `file:${dshFile}`,
      '@deepseek-ai/dsh-helper': `file:${helperFile}`,
    },
    patchedDependencies,
    importers: { '.': { dependencies: rootDependencies } },
    packages: candidatePackages,
    snapshots: candidateSnapshots,
  };
  const candidatePath = join(testRoot, 'candidate.yaml');
  writeFileSync(candidatePath, dumpYaml(candidate, { lineWidth: -1, noRefs: true }));
  const outputPath = join(testRoot, 'derived.json');
  const result = runDerive(source, manifestsPath, candidatePath, outputPath, true);
  assert(result.status === 0, `valid fixture failed:\n${result.stdout}\n${result.stderr}`);
  const derived = JSON.parse(readFileSync(outputPath, 'utf8'));
  assert(derived.externalResolutionCount === 61, 'fixture external closure count changed');
  assert(derived.internalSnapshotCount === 2, 'fixture internal snapshot count changed');
  assert(derived.consumerLockControl?.importers?.['.']?.dependencies?.['@deepseek-ai/dsh']?.version ===
    dshSnapshotKey.slice('@deepseek-ai/dsh@'.length), 'root importer was not captured exactly');
  assert(/^[0-9a-f]{64}$/.test(derived.consumerLockControlSha256), 'consumer lock control hash is missing');
  assert(derived.consumerLockControlSha256 === createHash('sha256')
    .update(JSON.stringify(derived.consumerLockControl))
    .digest('hex'), 'consumer lock control hash does not cover its canonical body');
  assert(derived.consumerOverrides['@deepseek-ai/dsh@1.0.0>alias-edge'] === 'npm:real-alias@1.0.0', 'alias override lost its target identity');
  assert(derived.consumerOverrides['@deepseek-ai/dsh@1.0.0>peerful'] === '1.0.0', 'peer suffix leaked into an override');
  assert(derived.consumerOverrides['@deepseek-ai/dsh@1.0.0>patched'] === '1.0.0', 'patch suffix leaked into an override');
  assert(derived.excludedWindowsOptionalPackages['@deepseek-ai/node-addon-landlock-run-linux-x64'] === '1.0.0', 'platform exclusion was not derived');
  const normalized = requireFromRoot('js-yaml').load(readFileSync(candidatePath, 'utf8'));
  assert(!normalized.packages['@deepseek-ai/node-addon-landlock-run-linux-x64@1.0.0'], 'excluded platform package remained in packages');
  assert(!normalized.snapshots[landlockSnapshotKey], 'excluded platform package remained in snapshots');

  for (const mutation of [
    {
      name: 'external same-set redirect',
      apply(lock) { lock.snapshots['pkg-00@1.0.0'].dependencies['optional-peer'] = '2.0.0'; },
      pattern: /differs from the official runtime resolution: pkg-00@1\.0\.0/,
    },
    {
      name: 'internal same-set redirect',
      apply(lock) { lock.snapshots[helperSnapshotKey].optionalDependencies['optional-peer'] = '2.0.0'; },
      pattern: /redirects optionalDependencies\.optional-peer from the official target/,
    },
    {
      name: 'internal archive redirect',
      apply(lock) { lock.snapshots[dshSnapshotKey].dependencies['@deepseek-ai/dsh-helper'] = `file:${dshFile}`; },
      pattern: /redirects dependencies\.@deepseek-ai\/dsh-helper from its verified archive/,
    },
    {
      name: 'unknown snapshot field',
      apply(lock) { lock.snapshots['pkg-00@1.0.0'].dev = true; },
      pattern: /unsupported field dev/,
    },
    {
      name: 'external hasBin false',
      apply(lock) { lock.packages['pkg-00@1.0.0'].hasBin = false; },
      pattern: /differs from the official package metadata/,
    },
    {
      name: 'external platform changed',
      apply(lock) { lock.packages['pkg-00@1.0.0'].os = ['linux']; },
      pattern: /differs from the official package metadata/,
    },
    {
      name: 'external peer meta changed',
      apply(lock) { lock.packages['pkg-00@1.0.0'].peerDependenciesMeta['peer-base'].optional = false; },
      pattern: /differs from the official package metadata/,
    },
    {
      name: 'unknown package field',
      apply(lock) { lock.packages['pkg-00@1.0.0'].requiresBuild = true; },
      pattern: /unsupported field requiresBuild/,
    },
    {
      name: 'internal package metadata changed',
      apply(lock) { lock.packages[`@deepseek-ai/dsh-helper@file:${helperFile}`].hasBin = false; },
      pattern: /candidate local package .* differs from the verified archive metadata/,
    },
    {
      name: 'root dependency deleted',
      apply(lock) { delete lock.importers['.'].dependencies['@deepseek-ai/dsh-helper']; },
      pattern: /root importer has .* dependencies, expected/,
    },
    {
      name: 'root setting changed',
      apply(lock) { lock.settings.autoInstallPeers = false; },
      pattern: /settings differ from the official lock/,
    },
    {
      name: 'root override changed',
      apply(lock) { lock.overrides['pkg-00'] = '9.9.9'; },
      pattern: /override differs from the official runtime closure: pkg-00/,
    },
    {
      name: 'root patch changed',
      apply(lock) { lock.patchedDependencies['patched@1.0.0'] = 'different-hash'; },
      pattern: /patchedDependencies differ from the official lock/,
    },
    {
      name: 'unknown root field',
      apply(lock) { lock.catalogs = {}; },
      pattern: /candidate pnpm lock has unsupported, missing, or duplicate fields/,
    },
    {
      name: 'unknown root setting',
      apply(lock) { lock.settings.injectWorkspacePackages = true; },
      pattern: /candidate pnpm lock.settings has unsupported field injectWorkspacePackages/,
    },
  ]) {
    const mutated = structuredClone(normalized);
    mutation.apply(mutated);
    const path = join(testRoot, `${mutation.name.replaceAll(' ', '-')}.yaml`);
    writeFileSync(path, dumpYaml(mutated, { lineWidth: -1, noRefs: true }));
    const failed = runDerive(source, manifestsPath, path, join(testRoot, 'failed.json'));
    assert(failed.status !== 0 && mutation.pattern.test(failed.stderr), `${mutation.name} was not rejected:\n${failed.stdout}\n${failed.stderr}`);
  }
  console.log('PASS derive official runtime lock fixtures');
} finally {
  rmSync(testRoot, { recursive: true, force: true });
}
