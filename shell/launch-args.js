'use strict'

const path = require('node:path')

/** Build the Web-profile invocation with the CedarDSH-only launcher layer. */
function dshServerArgs(dshBin, patchPath) {
  if (typeof dshBin !== 'string' || dshBin.length === 0) throw new TypeError('dshBin must be a non-empty string')
  if (typeof patchPath !== 'string' || patchPath.length === 0) throw new TypeError('patchPath must be a non-empty string')
  return [dshBin, 'web', '--patch', patchPath, '--no-open', '--port', '0']
}

/** Build the child environment while keeping plugin package-manager data in DSH_HOME. */
function portableDshEnv(baseEnv, dshHome, runtimeRoot) {
  if (!baseEnv || typeof baseEnv !== 'object') throw new TypeError('baseEnv must be an object')
  if (typeof dshHome !== 'string' || dshHome.length === 0) throw new TypeError('dshHome must be a non-empty string')
  if (typeof runtimeRoot !== 'string' || runtimeRoot.length === 0) throw new TypeError('runtimeRoot must be a non-empty string')
  const reserved = new Set([
    'dsh_home',
    'node_compile_cache',
    'node_compile_cache_portable',
    'path',
    'pnpm_config_cache_dir',
    'pnpm_config_state_dir',
    'pnpm_config_store_dir',
  ])
  const inheritedPath = Object.entries(baseEnv).find(([key]) => key.toLowerCase() === 'path')?.[1] || ''
  const env = Object.fromEntries(Object.entries(baseEnv).filter(([key]) => !reserved.has(key.toLowerCase())))
  env.DSH_HOME = dshHome
  env.PATH = [runtimeRoot, inheritedPath].filter(Boolean).join(path.delimiter)
  env.pnpm_config_cache_dir = path.join(dshHome, 'pnpm-cache')
  env.pnpm_config_state_dir = path.join(dshHome, 'pnpm-state')
  env.pnpm_config_store_dir = path.join(dshHome, 'pnpm-store')
  env.NODE_COMPILE_CACHE = path.join(dshHome, 'node-compile-cache')
  env.NODE_COMPILE_CACHE_PORTABLE = '1'
  return env
}

module.exports = {
  dshServerArgs,
  portableDshEnv,
}
