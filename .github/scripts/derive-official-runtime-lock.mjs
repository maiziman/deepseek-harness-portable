#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';

function fail(message) {
  throw new Error(message);
}

function readArgument(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || index + 1 >= process.argv.length) fail(`missing ${name}`);
  return process.argv[index + 1];
}

function object(value, description) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${description} is not an object`);
  return value;
}

function dependencyVersion(entry, description) {
  if (typeof entry === 'string' && entry.length > 0) return entry;
  if (entry && typeof entry === 'object' && typeof entry.version === 'string' && entry.version.length > 0) {
    return entry.version;
  }
  fail(`${description} has no exact lock version`);
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalize(value[key])]));
  }
  return value;
}

const LOCK_ROOT_FIELDS = new Set([
  'importers',
  'lockfileVersion',
  'overrides',
  'packages',
  'patchedDependencies',
  'settings',
  'snapshots',
]);

const LOCK_SETTING_FIELDS = new Set([
  'autoInstallPeers',
  'excludeLinksFromLockfile',
]);

function assertExactFields(value, expected, description) {
  const actual = Object.keys(object(value, description)).sort();
  const required = [...expected].sort();
  if (JSON.stringify(actual) !== JSON.stringify(required)) {
    fail(`${description} has unsupported, missing, or duplicate fields: ${actual.join(', ') || 'none'}`);
  }
}

function canonicalLockSettings(value, description) {
  const settings = object(value, description);
  for (const field of Object.keys(settings)) {
    if (!LOCK_SETTING_FIELDS.has(field)) fail(`${description} has unsupported field ${field}`);
  }
  if (Object.keys(settings).length !== LOCK_SETTING_FIELDS.size) {
    fail(`${description} does not contain the complete supported setting set`);
  }
  const result = {};
  for (const field of [...LOCK_SETTING_FIELDS].sort()) {
    if (typeof settings[field] !== 'boolean') fail(`${description}.${field} is not boolean`);
    result[field] = settings[field];
  }
  return result;
}

function validateLockRoot(lockValue, description) {
  const lockRoot = object(lockValue, description);
  assertExactFields(lockRoot, LOCK_ROOT_FIELDS, description);
  if (String(lockRoot.lockfileVersion) !== '9.0') fail(`${description}.lockfileVersion is not 9.0`);
  canonicalLockSettings(lockRoot.settings, `${description}.settings`);
  stringMap(lockRoot.overrides, `${description}.overrides`);
  stringMap(lockRoot.patchedDependencies, `${description}.patchedDependencies`);
}

function canonicalImporterDependencies(value, description) {
  const dependencies = object(value, description);
  const result = {};
  for (const name of Object.keys(dependencies).sort()) {
    if (!name || name.includes('\n') || name.includes('\r')) fail(`${description} has an invalid package name`);
    const entry = object(dependencies[name], `${description}.${name}`);
    assertExactFields(entry, new Set(['specifier', 'version']), `${description}.${name}`);
    for (const field of ['specifier', 'version']) {
      if (typeof entry[field] !== 'string' || !entry[field] || entry[field].includes('\n') || entry[field].includes('\r')) {
        fail(`${description}.${name}.${field} is not a non-empty scalar`);
      }
    }
    result[name] = { specifier: entry.specifier, version: entry.version };
  }
  return result;
}

const SNAPSHOT_FIELDS = new Set([
  'dependencies',
  'id',
  'optional',
  'optionalDependencies',
  'transitivePeerDependencies',
]);

const PACKAGE_FIELDS = new Set([
  'bundledDependencies',
  'cpu',
  'deprecated',
  'engines',
  'hasBin',
  'libc',
  'name',
  'os',
  'peerDependencies',
  'peerDependenciesMeta',
  'resolution',
  'version',
]);

function stringMap(value, description) {
  const source = object(value, description);
  const result = {};
  for (const name of Object.keys(source).sort()) {
    const entry = source[name];
    if (!name || name.includes('\n') || name.includes('\r') ||
      typeof entry !== 'string' || !entry || entry.includes('\n') || entry.includes('\r')) {
      fail(`${description} has an invalid entry`);
    }
    result[name] = entry;
  }
  return result;
}

function stringList(value, description) {
  if (!Array.isArray(value)) fail(`${description} is not an array`);
  const result = [...value];
  if (result.some((entry) => typeof entry !== 'string' || !entry || entry.includes('\n') || entry.includes('\r')) ||
    new Set(result).size !== result.length) {
    fail(`${description} has an invalid or duplicate entry`);
  }
  result.sort();
  return result;
}

function canonicalPackageBody(value, description) {
  const pkg = object(value, description);
  for (const field of Object.keys(pkg)) {
    if (!PACKAGE_FIELDS.has(field)) fail(`${description} has unsupported field ${field}`);
  }
  const result = {};
  for (const field of ['engines', 'peerDependencies']) {
    if (pkg[field] !== undefined) {
      const normalized = stringMap(pkg[field], `${description}.${field}`);
      if (Object.keys(normalized).length > 0) result[field] = normalized;
    }
  }
  for (const field of ['cpu', 'libc', 'os']) {
    if (pkg[field] !== undefined) {
      const normalized = stringList(pkg[field], `${description}.${field}`);
      if (normalized.length > 0) result[field] = normalized;
    }
  }
  for (const field of ['deprecated', 'name', 'version']) {
    if (pkg[field] !== undefined) {
      if (typeof pkg[field] !== 'string' || !pkg[field] || pkg[field].includes('\n') || pkg[field].includes('\r')) {
        fail(`${description}.${field} is not a non-empty scalar`);
      }
      result[field] = pkg[field];
    }
  }
  if (pkg.hasBin !== undefined) {
    if (typeof pkg.hasBin !== 'boolean') fail(`${description}.hasBin is not boolean`);
    result.hasBin = pkg.hasBin;
  }
  if (pkg.bundledDependencies !== undefined) {
    if (pkg.bundledDependencies === true) {
      result.bundledDependencies = true;
    } else {
      const normalized = stringList(pkg.bundledDependencies, `${description}.bundledDependencies`);
      if (normalized.length > 0) result.bundledDependencies = normalized;
    }
  }
  if (pkg.peerDependenciesMeta !== undefined) {
    const meta = object(pkg.peerDependenciesMeta, `${description}.peerDependenciesMeta`);
    const normalized = {};
    for (const name of Object.keys(meta).sort()) {
      const entry = object(meta[name], `${description}.peerDependenciesMeta.${name}`);
      const keys = Object.keys(entry);
      if (keys.length !== 1 || keys[0] !== 'optional' || typeof entry.optional !== 'boolean') {
        fail(`${description}.peerDependenciesMeta.${name} is unsupported`);
      }
      normalized[name] = { optional: entry.optional };
    }
    if (Object.keys(normalized).length > 0) result.peerDependenciesMeta = normalized;
  }
  return canonicalize(result);
}

function expectedInternalPackageBody(manifest, description) {
  const body = { version: manifest.version };
  for (const field of ['cpu', 'libc', 'os']) {
    if (manifest[field] !== undefined) body[field] = manifest[field];
  }
  if (manifest.engines !== undefined) {
    const engines = Object.fromEntries(Object.entries(manifest.engines).filter(([, version]) => version !== '*'));
    if (Object.keys(engines).length > 0) body.engines = engines;
  }
  if (manifest.deprecated) body.deprecated = manifest.deprecated;
  if ((typeof manifest.bin === 'string' && manifest.bin) ||
    (manifest.bin && typeof manifest.bin === 'object' && Object.keys(manifest.bin).length > 0)) {
    body.hasBin = true;
  }
  if (manifest.bundledDependencies === true || Array.isArray(manifest.bundledDependencies)) {
    body.bundledDependencies = manifest.bundledDependencies;
  } else if (manifest.bundleDependencies === true || Array.isArray(manifest.bundleDependencies)) {
    body.bundledDependencies = manifest.bundleDependencies;
  }
  if (manifest.peerDependencies && Object.keys(manifest.peerDependencies).length > 0) {
    body.peerDependencies = manifest.peerDependencies;
  }
  const peerMeta = {};
  for (const [name, meta] of Object.entries(manifest.peerDependenciesMeta ?? {})) {
    if (meta?.optional === true) peerMeta[name] = { optional: true };
  }
  if (Object.keys(peerMeta).length > 0) body.peerDependenciesMeta = peerMeta;
  return canonicalPackageBody(body, description);
}

function verifiedInternalPackageBody(packageRecord, manifest, importer, description) {
  const actual = canonicalPackageBody(packageRecord, description);
  const expected = expectedInternalPackageBody(manifest, `verified archive ${manifest.name}`);
  const declaredPeers = expected.peerDependencies ?? {};
  const actualPeers = actual.peerDependencies ?? {};
  if (Object.keys(declaredPeers).length !== Object.keys(actualPeers).length) {
    fail(`${description}.peerDependencies differs from the verified archive`);
  }
  for (const [name, range] of Object.entries(declaredPeers)) {
    if (actualPeers[name] === range) continue;
    if (manifest.peerDependenciesMeta?.[name]?.optional !== true || internalNames.has(name)) {
      fail(`${description}.peerDependencies.${name} differs from the verified archive`);
    }
    const version = importerVersion(importer, name, `${manifest.repository.directory} optional peer`);
    const peer = resolutionIdentity(name, version);
    if (actualPeers[name] !== peer.version) {
      fail(`${description}.peerDependencies.${name} is not the official resolved optional peer`);
    }
  }
  const comparableExpected = { ...expected };
  if (Object.keys(actualPeers).length > 0) comparableExpected.peerDependencies = actualPeers;
  if (JSON.stringify(actual) !== JSON.stringify(canonicalize(comparableExpected))) {
    fail(`${description} differs from the verified archive metadata`);
  }
  return actual;
}

function verifiedExternalPackageBody(packageRecord, expectedRecord, recordsByPackageKey, description) {
  const actual = canonicalPackageBody(packageRecord, description);
  const expected = expectedRecord.package;
  const declaredPeers = expected.peerDependencies ?? {};
  const actualPeers = actual.peerDependencies ?? {};
  if (Object.keys(declaredPeers).length !== Object.keys(actualPeers).length) {
    fail(`${description}.peerDependencies differs from the official lock`);
  }
  for (const [name, range] of Object.entries(declaredPeers)) {
    if (actualPeers[name] === range) continue;
    const resolved = new Set();
    for (const record of recordsByPackageKey.get(expectedRecord.packageKey) ?? []) {
      const locator = record.snapshot.dependencies?.[name] ?? record.snapshot.optionalDependencies?.[name];
      if (locator !== undefined) resolved.add(resolutionIdentity(name, locator).version);
    }
    if (resolved.size !== 1 || !resolved.has(actualPeers[name])) {
      fail(`${description}.peerDependencies.${name} is not its official resolved peer`);
    }
  }
  const comparableExpected = { ...expected };
  if (Object.keys(actualPeers).length > 0) comparableExpected.peerDependencies = actualPeers;
  if (JSON.stringify(actual) !== JSON.stringify(canonicalize(comparableExpected))) {
    fail(`${description} differs from the official package metadata`);
  }
  return actual;
}

function canonicalSnapshot(value, description) {
  const snapshot = object(value ?? {}, description);
  for (const field of Object.keys(snapshot)) {
    if (!SNAPSHOT_FIELDS.has(field)) fail(`${description} has unsupported field ${field}`);
  }
  const result = {};
  for (const field of ['dependencies', 'optionalDependencies']) {
    if (snapshot[field] === undefined) continue;
    const dependencies = object(snapshot[field], `${description}.${field}`);
    const normalized = {};
    for (const name of Object.keys(dependencies).sort()) {
      if (!name || name.includes('\n') || name.includes('\r')) fail(`${description}.${field} has an invalid package name`);
      const version = dependencies[name];
      if (typeof version !== 'string' || !version || version.includes('\n') || version.includes('\r')) {
        fail(`${description}.${field}.${name} has an invalid locator`);
      }
      normalized[name] = version;
    }
    if (Object.keys(normalized).length > 0) result[field] = normalized;
  }
  if (snapshot.transitivePeerDependencies !== undefined) {
    if (!Array.isArray(snapshot.transitivePeerDependencies)) {
      fail(`${description}.transitivePeerDependencies is not an array`);
    }
    const peers = [...snapshot.transitivePeerDependencies];
    if (peers.some((name) => typeof name !== 'string' || !name || name.includes('\n') || name.includes('\r')) ||
      new Set(peers).size !== peers.length) {
      fail(`${description}.transitivePeerDependencies has an invalid or duplicate package name`);
    }
    peers.sort();
    if (peers.length > 0) result.transitivePeerDependencies = peers;
  }
  if (snapshot.optional !== undefined) {
    if (typeof snapshot.optional !== 'boolean') fail(`${description}.optional is not boolean`);
    result.optional = snapshot.optional;
  }
  if (snapshot.id !== undefined) {
    if (typeof snapshot.id !== 'string' || !snapshot.id || snapshot.id.includes('\n') || snapshot.id.includes('\r')) {
      fail(`${description}.id is not a non-empty scalar`);
    }
    result.id = snapshot.id;
  }
  return canonicalize(result);
}

function platformListAllows(value, target) {
  if (!Array.isArray(value) || value.length === 0) return true;
  if (value.includes(`!${target}`)) return false;
  const positive = value.filter((entry) => typeof entry === 'string' && !entry.startsWith('!'));
  return positive.length === 0 || positive.includes(target);
}

function packageIdentity(packageKey) {
  const separator = packageKey.lastIndexOf('@');
  if (separator <= 0 || separator === packageKey.length - 1) fail(`unsupported registry package key: ${packageKey}`);
  return { name: packageKey.slice(0, separator), version: packageKey.slice(separator + 1) };
}

const sourceRoot = resolve(readArgument('--source-root'));
const manifestsArgument = readArgument('--runtime-manifests');
const outputPath = resolve(readArgument('--output'));
const requireFromSource = createRequire(join(sourceRoot, 'package.json'));
let dumpYaml;
let loadYaml;
try {
  ({ dump: dumpYaml, load: loadYaml } = requireFromSource('js-yaml'));
} catch (error) {
  fail(`official source installation has no js-yaml parser: ${error.message}`);
}

const lock = object(loadYaml(readFileSync(join(sourceRoot, 'pnpm-lock.yaml'), 'utf8')), 'official pnpm lock');
validateLockRoot(lock, 'official pnpm lock');
const importers = object(lock.importers, 'official pnpm importers');
const packages = object(lock.packages, 'official pnpm packages');
const snapshots = object(lock.snapshots, 'official pnpm snapshots');
const manifests = JSON.parse(readFileSync(manifestsArgument === '-' ? 0 : resolve(manifestsArgument), 'utf8'));
if (!Array.isArray(manifests) || manifests.length === 0) fail('runtime manifest list is empty');

const internalNames = new Set();
const importerOwners = new Map();
const sourceManifests = new Map();
const manifestRecords = new Map();
for (const manifest of manifests) {
  const name = manifest?.name;
  const directory = manifest?.repository?.directory?.replaceAll('\\', '/');
  if (typeof name !== 'string' || !name.startsWith('@deepseek-ai/')) fail('runtime manifest has an invalid package name');
  if (typeof directory !== 'string' || !directory || directory.startsWith('/') || directory.includes('..')) {
    fail(`runtime package ${name} has no safe repository.directory`);
  }
  if (internalNames.has(name)) fail(`runtime manifest list duplicates ${name}`);
  if (importerOwners.has(directory)) fail(`runtime importer ${directory} belongs to multiple packages`);
  if (!importers[directory]) fail(`official lock has no importer ${directory} for ${name}`);
  const sourceManifestPath = resolve(sourceRoot, directory, 'package.json');
  if (!sourceManifestPath.startsWith(`${sourceRoot}\\`) && !sourceManifestPath.startsWith(`${sourceRoot}/`)) {
    fail(`runtime package directory leaves the official source root: ${directory}`);
  }
  const sourceManifest = JSON.parse(readFileSync(sourceManifestPath, 'utf8'));
  if (sourceManifest.name !== name || sourceManifest.version !== manifest.version) {
    fail(`packed runtime package identity differs from official source importer ${directory}`);
  }
  internalNames.add(name);
  importerOwners.set(directory, manifest);
  sourceManifests.set(name, sourceManifest);
  manifestRecords.set(name, manifest);
}
if (!internalNames.has('@deepseek-ai/dsh')) fail('runtime manifest list has no @deepseek-ai/dsh entry');

const seen = new Set();
const records = new Map();
const edgePins = new Map();
const excludedWindowsOptionalPackages = new Map();
const peerPins = new Map();
const internalEdgeExpectations = new Map();

function snapshotKey(name, version) {
  if (version.startsWith('npm:')) return version.slice(4);
  const qualified = `${name}@${version}`;
  if (snapshots[qualified]) return qualified;
  if (snapshots[version]) return version;
  fail(`official runtime dependency has no snapshot: ${qualified}`);
}

function setPin(map, key, value, description) {
  const previous = map.get(key);
  if (previous && previous !== value) fail(`${description} has conflicting exact pins: ${previous} and ${value}`);
  map.set(key, value);
}

function resolutionIdentity(name, version) {
  const key = snapshotKey(name, version);
  const packageKey = packages[key] ? key : key.replace(/\(.*/, '');
  return { key, ...packageIdentity(packageKey) };
}

function recordEdge(parentName, parentVersion, childName, childVersion) {
  const child = resolutionIdentity(childName, childVersion);
  const value = childVersion.startsWith('npm:') ? `npm:${child.name}@${child.version}` : child.version;
  setPin(edgePins, `${parentName}@${parentVersion}>${childName}`, value, `runtime edge ${parentName}>${childName}`);
}

function visit(key) {
  if (seen.has(key)) return;
  const snapshot = snapshots[key];
  if (!snapshot) fail(`official runtime snapshot is missing: ${key}`);
  seen.add(key);
  const packageKey = packages[key] ? key : key.replace(/\(.*/, '');
  const packageRecord = packages[packageKey];
  if (!packageRecord || !packageRecord.resolution) fail(`official runtime package has no resolution: ${packageKey}`);
  const identity = packageIdentity(packageKey);
  const normalizedSnapshot = canonicalSnapshot(snapshot, `official runtime snapshot ${key}`);
  const normalizedPackage = canonicalPackageBody(packageRecord, `official runtime package ${packageKey}`);
  records.set(key, {
    snapshotKey: key,
    packageKey,
    packageName: identity.name,
    packageVersion: identity.version,
    package: normalizedPackage,
    resolution: canonicalize(packageRecord.resolution),
    snapshot: normalizedSnapshot,
  });
  for (const field of ['dependencies', 'optionalDependencies']) {
    for (const [name, value] of Object.entries(normalizedSnapshot[field] ?? {})) {
      if (internalNames.has(name)) fail(`registry snapshot unexpectedly points at internal package ${name}`);
      const version = dependencyVersion(value, `${key} ${field}.${name}`);
      recordEdge(identity.name, identity.version, name, version);
      visit(snapshotKey(name, version));
    }
  }
  if (key !== packageKey) {
    for (const name of Object.keys(packageRecord.peerDependencies ?? {})) {
      const value = snapshot.dependencies?.[name] ?? snapshot.optionalDependencies?.[name];
      if (value === undefined) continue;
      const peer = resolutionIdentity(name, dependencyVersion(value, `${key} peer ${name}`));
      setPin(peerPins, name, peer.version, `runtime peer ${name}`);
    }
  }
}

function importerVersion(importer, name, description) {
  const values = [];
  for (const field of ['dependencies', 'optionalDependencies', 'devDependencies']) {
    const entry = importer[field]?.[name];
    if (entry !== undefined) values.push(dependencyVersion(entry, `${description} ${field}.${name}`));
  }
  if (values.length === 0) fail(`${description} has no exact lock entry for ${name}`);
  if (new Set(values).size !== 1) fail(`${description} has conflicting lock entries for ${name}`);
  return values[0];
}

function addInternalExpectation(expectation, field, name, target, description) {
  const alternate = field === 'dependencies' ? 'optionalDependencies' : 'dependencies';
  if (expectation[alternate].has(name)) fail(`${description} appears in both production dependency fields`);
  const previous = expectation[field].get(name);
  if (previous && JSON.stringify(previous) !== JSON.stringify(target)) {
    fail(`${description} has conflicting exact targets`);
  }
  expectation[field].set(name, target);
}

function buildInternalExpectation(directory, manifest, importer) {
  const sourceManifest = sourceManifests.get(manifest.name);
  const expectation = {
    dependencies: new Map(),
    optionalDependencies: new Map(),
  };
  for (const [field, dependencies] of [
    ['dependencies', sourceManifest.dependencies ?? {}],
    ['optionalDependencies', sourceManifest.optionalDependencies ?? {}],
  ]) {
    for (const name of Object.keys(dependencies)) {
      if (excludedWindowsOptionalPackages.has(name)) continue;
      const version = importerVersion(importer, name, `${directory} ${field}`);
      if (internalNames.has(name)) {
        if (!version.startsWith('link:')) fail(`${directory} ${field}.${name} is not an official workspace link`);
        addInternalExpectation(expectation, field, name, { kind: 'internal' }, `${directory} ${field}.${name}`);
      } else if (name.startsWith('@deepseek-ai/')) {
        if (field !== 'optionalDependencies') fail(`required internal runtime package is absent from the staged package set: ${name}`);
      } else {
        addInternalExpectation(expectation, field, name, { kind: 'external', version }, `${directory} ${field}.${name}`);
      }
    }
  }
  for (const name of Object.keys(sourceManifest.peerDependencies ?? {})) {
    const optional = sourceManifest.peerDependenciesMeta?.[name]?.optional === true;
    const field = optional ? 'optionalDependencies' : 'dependencies';
    if (excludedWindowsOptionalPackages.has(name)) continue;
    const version = importerVersion(importer, name, `${directory} ${optional ? 'optional' : 'required'} peer`);
    if (internalNames.has(name)) {
      addInternalExpectation(expectation, field, name, { kind: 'internal' }, `${directory} peerDependencies.${name}`);
    } else if (!name.startsWith('@deepseek-ai/')) {
      addInternalExpectation(expectation, field, name, { kind: 'external', version }, `${directory} peerDependencies.${name}`);
    } else if (!optional) {
      fail(`required internal runtime peer is absent from the staged package set: ${name}`);
    }
  }
  internalEdgeExpectations.set(manifest.name, expectation);
}

for (const [directory, manifest] of importerOwners) {
  const importer = importers[directory];
  for (const field of ['dependencies', 'optionalDependencies']) {
    for (const [name, value] of Object.entries(importer[field] ?? {})) {
      if (internalNames.has(name)) continue;
      if (name.startsWith('@deepseek-ai/')) {
        if (field === 'optionalDependencies') {
          const version = dependencyVersion(value, `${directory} ${field}.${name}`);
          if (!version.startsWith('link:')) fail(`unstaged optional internal package is not a source workspace link: ${name}`);
          const linkedDirectory = resolve(sourceRoot, directory, version.slice('link:'.length));
          if (!linkedDirectory.startsWith(`${sourceRoot}\\`) && !linkedDirectory.startsWith(`${sourceRoot}/`)) {
            fail(`optional internal package link leaves the official source root: ${name}`);
          }
          const linkedManifest = JSON.parse(readFileSync(join(linkedDirectory, 'package.json'), 'utf8'));
          if (linkedManifest.name !== name || typeof linkedManifest.version !== 'string') {
            fail(`optional internal package link has the wrong identity: ${name}`);
          }
          const supportsWindowsX64 = platformListAllows(linkedManifest.os, 'win32') &&
            platformListAllows(linkedManifest.cpu, 'x64');
          if (supportsWindowsX64) fail(`unstaged optional internal package supports Windows x64: ${name}`);
          const previous = excludedWindowsOptionalPackages.get(name);
          if (previous && previous !== linkedManifest.version) fail(`optional internal package has conflicting versions: ${name}`);
          excludedWindowsOptionalPackages.set(name, linkedManifest.version);
          continue;
        }
        fail(`required internal runtime package is absent from the staged package set: ${name}`);
      }
      const version = dependencyVersion(value, `${directory} ${field}.${name}`);
      recordEdge(manifest.name, manifest.version, name, version);
      visit(snapshotKey(name, version));
    }
  }
  for (const name of Object.keys(manifest.peerDependencies ?? {})) {
    if (internalNames.has(name) || manifest.peerDependenciesMeta?.[name]?.optional === true) continue;
    const value = importer.devDependencies?.[name] ?? importer.dependencies?.[name];
    const version = dependencyVersion(value, `${directory} required peer ${name}`);
    const peer = resolutionIdentity(name, version);
    setPin(peerPins, name, peer.version, `runtime required peer ${name}`);
    visit(snapshotKey(name, version));
  }
  buildInternalExpectation(directory, manifest, importer);
}

const runtimeResolutions = [...records.values()].sort((left, right) =>
  left.snapshotKey.localeCompare(right.snapshotKey) || left.packageKey.localeCompare(right.packageKey));
if (runtimeResolutions.length < 50) fail(`official runtime closure is implausibly small: ${runtimeResolutions.length}`);
let outputRuntimeResolutions = runtimeResolutions;
const versionsByName = new Map();
for (const record of runtimeResolutions) {
  const versions = versionsByName.get(record.packageName) ?? new Set();
  versions.add(record.packageVersion);
  versionsByName.set(record.packageName, versions);
}
const consumerOverrides = {};
for (const [name, versions] of [...versionsByName].sort(([left], [right]) => left.localeCompare(right))) {
  if (versions.size === 1) consumerOverrides[name] = [...versions][0];
}
for (const [selector, version] of [...edgePins].sort(([left], [right]) => left.localeCompare(right))) {
  consumerOverrides[selector] = version;
}
const consumerPeerPins = Object.fromEntries([...peerPins].sort(([left], [right]) => left.localeCompare(right)));

function canonicalConsumerLockControl(candidate, localByName) {
  validateLockRoot(candidate, 'candidate pnpm lock');
  if (String(candidate.lockfileVersion) !== String(lock.lockfileVersion)) {
    fail('candidate pnpm lock version differs from the official lock');
  }
  const settings = canonicalLockSettings(candidate.settings, 'candidate pnpm lock.settings');
  const officialSettings = canonicalLockSettings(lock.settings, 'official pnpm lock.settings');
  if (JSON.stringify(settings) !== JSON.stringify(officialSettings)) {
    fail('candidate pnpm lock settings differ from the official lock');
  }
  const overrides = stringMap(candidate.overrides, 'candidate pnpm lock.overrides');
  for (const [selector, version] of Object.entries(consumerOverrides)) {
    if (overrides[selector] !== version) {
      fail(`candidate pnpm lock override differs from the official runtime closure: ${selector}`);
    }
  }
  const patchedDependencies = stringMap(candidate.patchedDependencies, 'candidate pnpm lock.patchedDependencies');
  const officialPatchedDependencies = stringMap(lock.patchedDependencies, 'official pnpm lock.patchedDependencies');
  if (JSON.stringify(patchedDependencies) !== JSON.stringify(officialPatchedDependencies)) {
    fail('candidate pnpm lock patchedDependencies differ from the official lock');
  }

  const candidateImporters = object(candidate.importers, 'candidate pnpm lock.importers');
  assertExactFields(candidateImporters, new Set(['.']), 'candidate pnpm lock.importers');
  const rootImporter = object(candidateImporters['.'], 'candidate pnpm lock.importers.');
  assertExactFields(rootImporter, new Set(['dependencies']), 'candidate pnpm lock.importers.');
  const dependencies = canonicalImporterDependencies(
    rootImporter.dependencies,
    'candidate pnpm lock.importers...dependencies',
  );
  const expectedNames = new Set([...internalNames, ...Object.keys(consumerPeerPins)]);
  if (Object.keys(dependencies).length !== expectedNames.size) {
    fail(`candidate pnpm root importer has ${Object.keys(dependencies).length} dependencies, expected ${expectedNames.size}`);
  }
  for (const name of [...expectedNames].sort()) {
    const dependency = dependencies[name];
    if (!dependency) fail(`candidate pnpm root importer is missing ${name}`);
    const local = localByName.get(name);
    if (local) {
      const prefix = `${name}@`;
      if (!local.packageKey.startsWith(prefix) || !local.snapshotKey.startsWith(prefix)) {
        fail(`candidate local package has an inconsistent importer identity: ${name}`);
      }
      const specifier = local.packageKey.slice(prefix.length);
      const version = local.snapshotKey.slice(prefix.length);
      if (dependency.specifier !== specifier || dependency.version !== version) {
        fail(`candidate pnpm root importer redirects verified local package ${name}`);
      }
      if (overrides[name] !== specifier) {
        fail(`candidate pnpm lock override redirects verified local package ${name}`);
      }
      continue;
    }
    const pin = consumerPeerPins[name];
    if (dependency.specifier !== pin || resolutionIdentity(name, dependency.version).version !== pin) {
      fail(`candidate pnpm root importer redirects official peer pin ${name}`);
    }
  }
  for (const name of Object.keys(dependencies)) {
    if (!expectedNames.has(name)) fail(`candidate pnpm root importer has unexpected dependency ${name}`);
  }

  return canonicalize({
    importers: { '.': { dependencies } },
    lockfileVersion: String(candidate.lockfileVersion),
    overrides,
    patchedDependencies,
    settings,
  });
}

const candidateIndex = process.argv.indexOf('--candidate-lock');
let internalRuntimeSnapshots = [];
let consumerLockControl = null;
if (candidateIndex >= 0) {
  if (candidateIndex + 1 >= process.argv.length) fail('missing --candidate-lock value');
  const candidate = object(loadYaml(readFileSync(resolve(process.argv[candidateIndex + 1]), 'utf8')), 'candidate pnpm lock');
  const candidatePackages = object(candidate.packages, 'candidate pnpm packages');
  const candidateSnapshots = object(candidate.snapshots, 'candidate pnpm snapshots');
  if (process.argv.includes('--normalize-candidate-lock')) {
    for (const [name, version] of excludedWindowsOptionalPackages) {
      const packageKey = `${name}@${version}`;
      if (!candidatePackages[packageKey] || !candidateSnapshots[packageKey]) {
        fail(`candidate lock has no excluded Windows-incompatible optional package ${packageKey}`);
      }
      delete candidatePackages[packageKey];
      delete candidateSnapshots[packageKey];
      for (const [snapshotName, snapshot] of Object.entries(candidateSnapshots)) {
        if (snapshot.dependencies?.[name] !== undefined) {
          fail(`candidate lock requires Windows-incompatible optional package ${name} from ${snapshotName}`);
        }
        if (snapshot.optionalDependencies?.[name] !== undefined) delete snapshot.optionalDependencies[name];
      }
    }
    writeFileSync(resolve(process.argv[candidateIndex + 1]), dumpYaml(candidate, {
      lineWidth: -1,
      noRefs: true,
      noCompatMode: true,
      sortKeys: false,
    }));
  }
  const localNames = new Set();
  const localByName = new Map();
  const candidateRecords = new Map();
  const recordsByPackageKey = new Map();
  for (const record of records.values()) {
    const packageRecords = recordsByPackageKey.get(record.packageKey) ?? [];
    packageRecords.push(record);
    recordsByPackageKey.set(record.packageKey, packageRecords);
  }
  for (const key of Object.keys(candidateSnapshots)) {
    const baseKey = candidatePackages[key] ? key : key.replace(/\(.*/, '');
    const local = baseKey.match(/^(@[^/]+\/[^@]+|[^@]+)@file:(.+)$/);
    if (local) {
      if (!internalNames.has(local[1])) fail(`candidate lock contains unknown local package ${local[1]}`);
      if (localByName.has(local[1])) fail(`candidate lock contains multiple snapshots for local package ${local[1]}`);
      const packageRecord = candidatePackages[baseKey];
      const manifest = manifestRecords.get(local[1]);
      if (!packageRecord?.resolution || packageRecord.version !== manifest.version ||
        packageRecord.resolution.tarball !== `file:${local[2]}` ||
        typeof packageRecord.resolution.integrity !== 'string' || !packageRecord.resolution.integrity) {
        fail(`candidate lock has an invalid local package record: ${baseKey}`);
      }
      const packageBody = verifiedInternalPackageBody(
        packageRecord,
        manifest,
        importers[manifest.repository.directory.replaceAll('\\', '/')],
        `candidate local package ${baseKey}`,
      );
      localNames.add(local[1]);
      localByName.set(local[1], {
        packageKey: baseKey,
        packageName: local[1],
        packageVersion: manifest.version,
        package: packageBody,
        snapshotKey: key,
        snapshot: canonicalSnapshot(candidateSnapshots[key], `candidate local snapshot ${key}`),
      });
      continue;
    }
    const packageRecord = candidatePackages[baseKey];
    if (!packageRecord?.resolution) fail(`candidate external snapshot has no package resolution: ${key}`);
    if (packageRecord.resolution.directory || packageRecord.resolution.type === 'directory') {
      fail(`candidate lock contains an unexpected directory package: ${baseKey}`);
    }
    const identity = packageIdentity(baseKey);
    const expectedRecord = records.get(key);
    if (!expectedRecord) fail(`candidate lock has an external snapshot absent from the official runtime closure: ${key}`);
    candidateRecords.set(key, {
      snapshotKey: key,
      packageKey: baseKey,
      packageName: identity.name,
      packageVersion: identity.version,
      package: verifiedExternalPackageBody(
        packageRecord,
        expectedRecord,
        recordsByPackageKey,
        `candidate external package ${baseKey}`,
      ),
      resolution: canonicalize(packageRecord.resolution),
      snapshot: canonicalSnapshot(candidateSnapshots[key], `candidate external snapshot ${key}`),
    });
  }
  const missingLocal = [...internalNames].filter((name) => !localNames.has(name));
  if (missingLocal.length > 0 || localNames.size !== internalNames.size) {
    fail(`candidate lock does not contain the exact internal runtime set; missing ${missingLocal.join(', ') || 'none'}`);
  }
  if (candidateRecords.size !== records.size) {
    const extras = [...candidateRecords.keys()].filter((key) => !records.has(key));
    const missing = [...records.keys()].filter((key) => !candidateRecords.has(key));
    fail(`candidate lock has ${candidateRecords.size} external snapshots, expected ${records.size}; extra ${extras.join(', ') || 'none'}; missing ${missing.join(', ') || 'none'}`);
  }
  for (const [key, expected] of records) {
    const actual = candidateRecords.get(key);
    if (!actual || JSON.stringify(canonicalize({ ...actual, package: expected.package })) !==
      JSON.stringify(canonicalize(expected))) {
      fail(`candidate lock differs from the official runtime resolution: ${key}`);
    }
  }
  for (const [name, local] of localByName) {
    const expected = internalEdgeExpectations.get(name);
    if (!expected) fail(`candidate local snapshot has no official importer expectation: ${name}`);
    for (const field of ['dependencies', 'optionalDependencies']) {
      const actualDependencies = local.snapshot[field] ?? {};
      const expectedDependencies = expected[field];
      const actualNames = Object.keys(actualDependencies);
      if (actualNames.length !== expectedDependencies.size) {
        fail(`candidate local snapshot ${name} has the wrong ${field} set`);
      }
      for (const [dependencyName, target] of expectedDependencies) {
        const actual = actualDependencies[dependencyName];
        if (actual === undefined) fail(`candidate local snapshot ${name} is missing ${field}.${dependencyName}`);
        if (target.kind === 'external') {
          if (actual !== target.version) {
            fail(`candidate local snapshot ${name} redirects ${field}.${dependencyName} from the official target`);
          }
          continue;
        }
        const dependency = localByName.get(dependencyName);
        if (!dependency) fail(`candidate local snapshot ${name} points at unstaged internal package ${dependencyName}`);
        const actualBaseKey = `${dependencyName}@${actual.replace(/\(.*/, '')}`;
        if (actualBaseKey !== dependency.packageKey) {
          fail(`candidate local snapshot ${name} redirects ${field}.${dependencyName} from its verified archive`);
        }
      }
    }
  }
  internalRuntimeSnapshots = [...localByName.values()].sort((left, right) =>
    left.packageName.localeCompare(right.packageName) || left.snapshotKey.localeCompare(right.snapshotKey));
  outputRuntimeResolutions = [...candidateRecords.values()].sort((left, right) =>
    left.snapshotKey.localeCompare(right.snapshotKey) || left.packageKey.localeCompare(right.packageKey));
  consumerLockControl = canonicalConsumerLockControl(candidate, localByName);
  console.log(`verified candidate lock with ${localNames.size} internal packages and ${candidateRecords.size} external resolutions`);
}
const internalRuntimeSnapshotsSha256 = createHash('sha256')
  .update(JSON.stringify(canonicalize(internalRuntimeSnapshots)))
  .digest('hex');
const runtimeResolutionsSha256 = createHash('sha256')
  .update(JSON.stringify(canonicalize(outputRuntimeResolutions)))
  .digest('hex');
const consumerLockControlSha256 = createHash('sha256')
  .update(JSON.stringify(canonicalize(consumerLockControl)))
  .digest('hex');
writeFileSync(outputPath, `${JSON.stringify({
  schemaVersion: 1,
  internalPackageCount: manifests.length,
  internalSnapshotCount: internalRuntimeSnapshots.length,
  internalRuntimeSnapshotsSha256,
  externalResolutionCount: outputRuntimeResolutions.length,
  runtimeResolutionsSha256,
  consumerLockControl,
  consumerLockControlSha256,
  consumerOverrides,
  consumerPeerPins,
  excludedWindowsOptionalPackages: Object.fromEntries([...excludedWindowsOptionalPackages].sort(([left], [right]) => left.localeCompare(right))),
  internalRuntimeSnapshots,
  runtimeResolutions: outputRuntimeResolutions,
}, null, 2)}\n`);
console.log(`derived ${outputRuntimeResolutions.length} external runtime resolutions for ${manifests.length} internal packages`);
