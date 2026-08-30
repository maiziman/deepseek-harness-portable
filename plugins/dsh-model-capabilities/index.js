/**
 * Independent DeepSeek Harness plugin that augments custom `llm-pi-ai`
 * model profiles with positively discovered reasoning and image-input facts.
 * It does not replace or import the official adapter.
 *
 * @module @maiziman/dsh-model-capabilities
 */

import { createHash } from 'node:crypto'
import { isDeepStrictEqual } from 'node:util'

import {
  allowsActiveProbe,
  probeReasoningEfforts,
  probeVision,
  readProviderMetadata,
  resolveConfig,
} from './capability-detection.js'

const LLM_SETTINGS_NS = 'llm-pi-ai'

export const name = 'model-capabilities'
export const inject = ['settings', 'credentials']

/** Whether a value is a JSON-style object. */
function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

/** Return a plain provider dictionary from a settings layer. */
function providersOf(layer) {
  return isRecord(layer) && isRecord(layer.providers) ? layer.providers : {}
}

/** Read one own dictionary member without consulting an object prototype. */
function ownProvider(providers, provider) {
  return Object.hasOwn(providers, provider) ? providers[provider] : undefined
}

/** Merge the profile fields needed for discovery without materializing schema defaults. */
function providerSource(descriptor, provider) {
  const base = ownProvider(providersOf(descriptor.base), provider)
  const user = ownProvider(providersOf(descriptor.user), provider)
  const value = ownProvider(providersOf(descriptor.value), provider)
  const raw = {
    ...(isRecord(base) ? base : {}),
    ...(isRecord(user) ? user : {}),
  }
  if (isRecord(base?.compat) || isRecord(user?.compat)) {
    raw.compat = {
      ...(isRecord(base?.compat) ? base.compat : {}),
      ...(isRecord(user?.compat) ? user.compat : {}),
    }
  }
  return {
    effective: isRecord(value) ? value : {},
    raw,
  }
}

/** Find the official model settings descriptor. */
function llmDescriptor(settings) {
  return settings.describe().find(descriptor => String(descriptor.ns) === LLM_SETTINGS_NS)
}

/** Resolve a provider's secret through the official Credentials service. */
async function apiKeyFor(ctx, profile) {
  if (typeof profile.apiKeyEnv !== 'string' || profile.apiKeyEnv.length === 0) return undefined
  const credentials = ctx.get('credentials')
  return (await credentials?.resolve(profile.apiKeyEnv))?.value
}

/** Build a stable per-session active-probe key. */
function probeKey(kind, provider, profile, modelId) {
  const headers = isRecord(profile.headers)
    ? Object.entries(profile.headers)
      .filter(([, value]) => typeof value === 'string')
      .map(([key, value]) => [key.toLowerCase(), value])
      .sort(([left], [right]) => left.localeCompare(right))
    : []
  const headerFingerprint = createHash('sha256').update(JSON.stringify(headers)).digest('hex')
  return JSON.stringify([
    kind,
    provider,
    profile.baseURL,
    profile.api,
    profile.apiKeyEnv,
    modelId,
    headerFingerprint,
  ])
}

/** Allow routes using one changed credential reference to be probed again. */
function clearCredentialAttempts(attempted, ref) {
  for (const key of attempted) {
    const parts = JSON.parse(key)
    if (parts[4] === ref) attempted.delete(key)
  }
}

/** Build a stable key for one model entry owned by one provider route. */
function modelKey(provider, modelId) {
  return JSON.stringify([provider, modelId])
}

/** Add discovered facts without replacing any explicit model declaration. */
function augmentModel(model, provider, capability) {
  let next = model
  const changed = []
  if (!('input' in model) && !('defaultInput' in provider) && capability.image === true) {
    next = { ...next, input: ['text', 'image'] }
    changed.push('image input')
  }
  const routeReasoningDisabled = isRecord(provider.compat) && provider.compat.supportsReasoningEffort === false
  const modelReasoningDisabled = isRecord(model.compat) && model.compat.supportsReasoningEffort === false
  if (!('reasoningEfforts' in model)
    && !routeReasoningDisabled
    && !modelReasoningDisabled
    && capability.reasoningEfforts !== undefined) {
    const compat = isRecord(next.compat) ? { ...next.compat } : {}
    const providerCompat = isRecord(provider.compat) ? provider.compat : {}
    if (!('supportsReasoningEffort' in compat)) compat.supportsReasoningEffort = true
    if (!('thinkingFormat' in compat)
      && !('thinkingFormat' in providerCompat)
      && capability.thinkingFormat !== undefined) {
      compat.thinkingFormat = capability.thinkingFormat
    }
    next = { ...next, reasoningEfforts: capability.reasoningEfforts, compat }
    changed.push('reasoning levels')
  }
  return { model: next, changed }
}

/**
 * Reconcile one settings snapshot and persist all model-array changes in one
 * revision-checked mutation.
 */
async function reconcile(ctx, config, signal, attempted, tentative, active, isCurrent, ownMutation) {
  const descriptor = llmDescriptor(ctx.settings)
  if (descriptor === undefined) return
  const roundAttempts = new Set()
  const available = key => !attempted.has(key) && !roundAttempts.has(key)
  const attempt = key => roundAttempts.add(key)
  const effectiveProviders = providersOf(descriptor.value)
  const changes = []
  const summaries = []
  const refreshedTentatives = new Set()
  const tentativeWrites = []
  const seenModelKeys = new Set()
  for (const providerName of Object.keys(effectiveProviders)) {
    const { effective, raw } = providerSource(descriptor, providerName)
    const models = Array.isArray(raw.models) ? raw.models : []
    for (const model of models) {
      if (isRecord(model) && typeof model.id === 'string' && model.id.length > 0) {
        seenModelKeys.add(modelKey(providerName, model.id))
      }
    }
    if (models.length === 0 || typeof effective.baseURL !== 'string' || effective.baseURL.length === 0) continue
    if (effective.api !== undefined && effective.api !== 'openai-completions') continue
    const usableModels = models.filter(model => isRecord(model) && typeof model.id === 'string' && model.id.length > 0)
    if (usableModels.length === 0) continue
    const apiKey = await apiKeyFor(ctx, effective)
    if (!isCurrent() || signal.aborted) return
    const metadata = await readProviderMetadata({
      profile: effective,
      modelIds: usableModels.map(model => model.id),
      apiKey,
      signal,
      config,
    })
    if (!isCurrent() || signal.aborted) return
    for (const diagnostic of new Set(metadata.diagnostics)) {
      ctx.logger.debug(`model-capabilities: metadata unavailable for route "${providerName}": ${diagnostic}`)
    }
    const mayProbe = active && allowsActiveProbe(config.activeProbePolicy, effective.baseURL)
    const nextModels = []
    let providerChanged = false
    for (const model of models) {
      if (!isRecord(model) || typeof model.id !== 'string' || model.id.length === 0) {
        nextModels.push(model)
        continue
      }
      const key = modelKey(providerName, model.id)
      const pending = tentative.get(key)
      let discoveryModel = model
      if (pending !== undefined && isDeepStrictEqual(model, pending.after)) {
        discoveryModel = pending.before
        refreshedTentatives.add(key)
      } else if (pending !== undefined) {
        tentative.delete(key)
      }
      const capability = { ...(metadata.capabilities.get(model.id) ?? {}) }
      const routeReasoningDisabled = isRecord(raw.compat) && raw.compat.supportsReasoningEffort === false
      const modelReasoningDisabled = isRecord(discoveryModel.compat)
        && discoveryModel.compat.supportsReasoningEffort === false
      if (mayProbe
        && !routeReasoningDisabled
        && !modelReasoningDisabled
        && !('reasoningEfforts' in discoveryModel)
        && capability.reasoningEfforts === undefined) {
        const reasoningKey = probeKey('reasoning', providerName, effective, model.id)
        if (available(reasoningKey)) {
          attempt(reasoningKey)
          const efforts = await probeReasoningEfforts({ profile: effective, modelId: model.id, apiKey, signal, config })
          if (!isCurrent() || signal.aborted) return
          if (efforts !== undefined) {
            capability.reasoningEfforts = efforts
            capability.thinkingFormat = 'openai'
          }
        }
      }
      if (mayProbe && !('input' in discoveryModel) && !('defaultInput' in raw) && capability.image !== true) {
        const visionKey = probeKey('vision', providerName, effective, model.id)
        if (available(visionKey)) {
          attempt(visionKey)
          if (await probeVision({ profile: effective, modelId: model.id, apiKey, signal, config })) {
            capability.image = true
          }
          if (!isCurrent() || signal.aborted) return
        }
      }
      const augmented = augmentModel(discoveryModel, raw, capability)
      nextModels.push(augmented.model)
      if (!isDeepStrictEqual(model, augmented.model)) {
        providerChanged = true
        tentativeWrites.push({ key, before: structuredClone(discoveryModel), after: structuredClone(augmented.model) })
        const summary = augmented.changed.length > 0
          ? augmented.changed.join(', ')
          : 'removed stale discovered capabilities'
        summaries.push(`${providerName}/${model.id}: ${summary}`)
      }
    }
    if (providerChanged) {
      changes.push({ op: 'set', path: ['providers', providerName, 'models'], value: nextModels })
    }
  }
  if (!isCurrent() || signal.aborted) return
  if (changes.length > 0) {
    ownMutation.begin(descriptor.revision + 1)
    try {
      await ctx.settings.mutate(LLM_SETTINGS_NS, changes, descriptor.revision)
    } catch (error) {
      ownMutation.end(false)
      throw error
    }
    ownMutation.end(true)
    if (!isCurrent() || signal.aborted) {
      for (const entry of tentativeWrites) tentative.set(entry.key, { before: entry.before, after: entry.after })
      return
    }
    ctx.logger.info(`model-capabilities: saved discovered capabilities (${summaries.join('; ')})`)
  }
  for (const key of tentative.keys()) {
    if (!seenModelKeys.has(key)) tentative.delete(key)
  }
  for (const key of refreshedTentatives) tentative.delete(key)
  for (const key of roundAttempts) attempted.add(key)
}

/**
 * Mount capability discovery beside the official `llm-pi-ai` plugin.
 * @param {import('@deepseek-ai/cordis').Context} ctx - Cordis plugin context.
 * @param {unknown} input - deployment controls.
 * @returns {void}
 */
export function apply(ctx, input) {
  const config = resolveConfig(input)
  const attempted = new Set()
  const tentative = new Map()
  let requested = 0
  let running
  let currentController
  let generation = 0
  let pendingOwnMutation
  let stopped = false
  let schedule
  let request
  let invalidate

  const ownMutation = {
    begin: revision => { pendingOwnMutation = { revision, suppressed: false } },
    end: succeeded => {
      const pending = pendingOwnMutation
      pendingOwnMutation = undefined
      if (!succeeded && pending?.suppressed === true) schedule(true)
    },
  }

  const drain = async () => {
    while (!stopped && requested > 0) {
      const active = requested >= 2
      requested = 0
      const runGeneration = generation
      const controller = new AbortController()
      currentController = controller
      try {
        await reconcile(
          ctx,
          config,
          controller.signal,
          attempted,
          tentative,
          active,
          () => !stopped && generation === runGeneration,
          ownMutation,
        )
      } catch (error) {
        if (!controller.signal.aborted && !stopped) {
          ctx.logger.warn('model-capabilities: capability reconciliation failed; explicit model settings were left unchanged')
          ctx.logger.warn(error)
        }
      } finally {
        if (currentController === controller) currentController = undefined
      }
    }
  }
  const startDrain = () => {
    if (stopped || running !== undefined) return
    running = drain().finally(() => {
      running = undefined
      if (requested > 0) startDrain()
    })
  }
  request = active => {
    if (stopped) return
    requested = Math.max(requested, active ? 2 : 1)
    startDrain()
  }
  invalidate = () => {
    if (stopped) return
    generation++
    currentController?.abort(new Error('model-capabilities configuration changed'))
  }
  schedule = active => {
    invalidate()
    request(active)
  }

  ctx.on('settings/document-updated', (ns, revision) => {
    if (String(ns) !== LLM_SETTINGS_NS) return
    if (pendingOwnMutation?.revision === Number(revision)) {
      pendingOwnMutation.suppressed = true
      return
    }
    // SettingsProvider commits its resolved value immediately after this
    // synchronous event. Cancel stale work now, then read the committed value.
    invalidate()
    queueMicrotask(() => request(true))
  })
  ctx.on('credentials/reference-updated', (ref) => {
    const value = String(ref)
    const descriptor = llmDescriptor(ctx.settings)
    if (descriptor === undefined) return
    const providers = providersOf(descriptor.value)
    const usesReference = Object.keys(providers).some(provider => ownProvider(providers, provider)?.apiKeyEnv === value)
    if (!usesReference) return
    clearCredentialAttempts(attempted, value)
    schedule(true)
  })
  ctx.effect(() => {
    // Initial reconciliation is active-policy eligible so an existing local
    // provider gains capabilities immediately after this Bundle is installed.
    // Public endpoints still remain metadata-only under the default policy.
    queueMicrotask(() => schedule(true))
    return async () => {
      stopped = true
      generation++
      currentController?.abort(new Error('model-capabilities plugin disposed'))
      await running
    }
  }, 'model-capabilities.lifecycle')
}
