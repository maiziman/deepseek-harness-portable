'use strict'

const CAPABILITY_PACKAGE = '@maiziman/dsh-model-capabilities'
const CAPABILITY_LINK_SPEC = '@maiziman/dsh-model-capabilities@link:./.portable-plugins/dsh-model-capabilities'

/** Build the official plugin-manager invocation for the bundled package. */
function capabilityInstallArgs(dshBin) {
  if (typeof dshBin !== 'string' || dshBin.length === 0) throw new TypeError('dshBin must be a non-empty string')
  return [dshBin, 'plugin', '--profile', 'web', 'add', '--offline', CAPABILITY_LINK_SPEC]
}

/** Build an official reinstall that repairs profile links after a directory move. */
function capabilityRepairArgs(dshBin) {
  if (typeof dshBin !== 'string' || dshBin.length === 0) throw new TypeError('dshBin must be a non-empty string')
  return [dshBin, 'plugin', '--profile', 'web', 'install', '--offline', '--force']
}

/** Whether the Web profile declares this Bundle through its portable relative link. */
function capabilityProfileRegistered(profileManifest) {
  if (profileManifest === null || typeof profileManifest !== 'object') return false
  const dependencies = profileManifest.dependencies
  const bundles = profileManifest.dsh?.profile?.bundles
  const dependency = dependencies !== null
    && typeof dependencies === 'object'
    && Object.hasOwn(dependencies, CAPABILITY_PACKAGE)
    ? dependencies[CAPABILITY_PACKAGE]
    : undefined
  const normalizedDependency = typeof dependency === 'string'
    ? dependency.replaceAll('\\', '/').replace(/^link:\.\//u, 'link:')
    : undefined
  return normalizedDependency === 'link:.portable-plugins/dsh-model-capabilities'
    && Array.isArray(bundles)
    && bundles.includes(CAPABILITY_PACKAGE)
}

/** Whether the Web profile names the expected installed Bundle version. */
function capabilityBundleRegistered(profileManifest, installedManifest, expectedVersion) {
  if (installedManifest === null || typeof installedManifest !== 'object') return false
  return capabilityProfileRegistered(profileManifest)
    && installedManifest.name === CAPABILITY_PACKAGE
    && installedManifest.version === expectedVersion
}

/** Build the normal Web-profile server invocation after plugin registration. */
function dshServerArgs(dshBin) {
  if (typeof dshBin !== 'string' || dshBin.length === 0) throw new TypeError('dshBin must be a non-empty string')
  return [dshBin, 'web', '--no-open', '--port', '0']
}

module.exports = {
  CAPABILITY_PACKAGE,
  CAPABILITY_LINK_SPEC,
  capabilityBundleRegistered,
  capabilityInstallArgs,
  capabilityProfileRegistered,
  capabilityRepairArgs,
  dshServerArgs,
}
