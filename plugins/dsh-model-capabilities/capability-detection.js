/**
 * Capability metadata readers and bounded active probes for custom
 * OpenAI-compatible model providers.
 *
 * @module @maiziman/dsh-model-capabilities/detection
 */

import { randomInt } from 'node:crypto'

const ACTIVE_PROBE_POLICIES = new Set(['never', 'local-only', 'always'])
const REASONING_LEVELS = new Set(['minimal', 'low', 'medium', 'high', 'xhigh', 'max'])
const DEFAULT_REASONING_PROBE_EFFORTS = ['low', 'high', 'max']
const MAX_RESPONSE_BYTES = 2 * 1024 * 1024
const OPENROUTER_EFFORTS = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']
const OPENAI_COMPATIBLE_EFFORTS = ['none', 'low', 'medium', 'high']
const VISION_CHALLENGES = [
  {
    color: 'red',
    image: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAAvSURBVFhH7c6hAQAACMOw/f/08BwAJqKmKmnSz7LHdQAAAAAAAAAAAAAAAAAAAANUDfhqnpuFxwAAAABJRU5ErkJggg==',
  },
  {
    color: 'blue',
    image: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAABOSURBVFhHxcghAQAwDASx92+6E3A8AyHZdvdXQktoCS2hJbSEltASWkJLaAktoSW0hJbQElpCS2gJLaEltISW0BJaQktoCS2hJbSElrAeW5X4avNqqmgAAAAASUVORK5CYII=',
  },
]
const INVALID_REASONING_EFFORT = '__dsh_invalid_effort__'

/** HTTP response failure retained for conservative capability canaries. */
class HttpStatusError extends Error {
  constructor(message, status) {
    super(message)
    this.status = status
  }
}

/** Whether a value is a JSON-style object. */
function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

/** Return the non-empty strings in an unknown array. */
function stringArray(value) {
  if (!Array.isArray(value)) return []
  return value.filter(item => typeof item === 'string' && item.length > 0)
}

/** Return one object member when its parent is an object. */
function member(value, key) {
  return isRecord(value) ? value[key] : undefined
}

/** Return a color only when the model gave the requested single-word answer. */
function strictColorAnswer(value) {
  const normalized = value.trim().toLowerCase().replace(/^[\s"'`.,!?;:，。！？；：]+|[\s"'`.,!?;:，。！？；：]+$/gu, '')
  if (/^(?:red|红|红色)$/u.test(normalized)) return 'red'
  if (/^(?:blue|蓝|蓝色)$/u.test(normalized)) return 'blue'
  return undefined
}

/** Remove userinfo, query parameters, and fragments from a diagnostic URL. */
function displayUrl(raw) {
  try {
    const url = new URL(raw)
    url.username = ''
    url.password = ''
    url.search = ''
    url.hash = ''
    return url.toString()
  } catch {
    return '<invalid provider URL>'
  }
}

/**
 * Validate and resolve deployment controls.
 * @param {unknown} input - plugin configuration supplied by Cordis.
 * @returns {{metadataDiscovery: boolean, activeProbePolicy: 'never'|'local-only'|'always', reasoningProbe: boolean, visionProbe: boolean, reasoningProbeEfforts: string[], probeConcurrency: number, requestTimeoutMs: number, probeMaxTokens: number}}
 */
export function resolveConfig(input) {
  if (input !== undefined && !isRecord(input)) throw new TypeError('model-capabilities config must be an object')
  const source = input ?? {}
  const activeProbePolicy = source.activeProbePolicy ?? 'local-only'
  if (!ACTIVE_PROBE_POLICIES.has(activeProbePolicy)) {
    throw new TypeError('model-capabilities activeProbePolicy must be never, local-only, or always')
  }
  const reasoningProbeEfforts = source.reasoningProbeEfforts ?? DEFAULT_REASONING_PROBE_EFFORTS
  if (!Array.isArray(reasoningProbeEfforts)
    || reasoningProbeEfforts.length === 0
    || reasoningProbeEfforts.some(level => !REASONING_LEVELS.has(level))) {
    throw new TypeError('model-capabilities reasoningProbeEfforts must be a non-empty array of supported effort names')
  }
  if (new Set(reasoningProbeEfforts).size !== reasoningProbeEfforts.length) {
    throw new TypeError('model-capabilities reasoningProbeEfforts must not contain duplicates')
  }
  const positiveInteger = (key, fallback) => {
    const value = source[key] ?? fallback
    if (!Number.isSafeInteger(value) || value <= 0) {
      throw new TypeError(`model-capabilities ${key} must be a positive integer`)
    }
    return value
  }
  const boolean = (key, fallback) => {
    const value = source[key] ?? fallback
    if (typeof value !== 'boolean') throw new TypeError(`model-capabilities ${key} must be a boolean`)
    return value
  }
  return Object.freeze({
    metadataDiscovery: boolean('metadataDiscovery', true),
    activeProbePolicy,
    reasoningProbe: boolean('reasoningProbe', true),
    visionProbe: boolean('visionProbe', true),
    reasoningProbeEfforts: [...reasoningProbeEfforts],
    probeConcurrency: positiveInteger('probeConcurrency', 1),
    requestTimeoutMs: positiveInteger('requestTimeoutMs', 10_000),
    probeMaxTokens: positiveInteger('probeMaxTokens', 128),
  })
}

/**
 * Whether a URL names loopback, link-local, RFC 1918, unique-local IPv6, or a
 * exact `localhost` host.
 * @param {string} raw - provider base URL.
 * @returns {boolean} true when active probes stay on the local network.
 */
export function isLocalEndpoint(raw) {
  let hostname
  try {
    hostname = new URL(raw).hostname.replace(/^\[|\]$/gu, '').toLowerCase()
  } catch {
    return false
  }
  if (hostname === 'localhost') return true
  if (hostname === '::1') return true
  const ipv4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/u.exec(hostname)
  if (ipv4 !== null) {
    const octets = ipv4.slice(1).map(Number)
    if (octets.some(value => value > 255)) return false
    const [first, second] = octets
    return first === 10
      || first === 127
      || (first === 169 && second === 254)
      || (first === 172 && second >= 16 && second <= 31)
      || (first === 192 && second === 168)
  }
  const firstGroup = hostname.split(':', 1)[0]
  if (/^f[cd][0-9a-f]{2}$/u.test(firstGroup)) return true
  return /^fe[89ab][0-9a-f]$/u.test(firstGroup)
}

/** Convert declared effort values into the profile's selector-to-wire map. */
function reasoningEfforts(values, options = {}) {
  const result = {}
  for (const raw of values) {
    if (raw === 'none' || raw === 'off') result.off = raw
    else if (REASONING_LEVELS.has(raw)) result[raw] = raw
  }
  if (options.mandatory !== true && result.off === undefined && Object.keys(result).length > 0) result.off = null
  return Object.keys(result).some(key => key !== 'off') ? result : undefined
}

/** Add only capability facts not already present in the target. */
function mergeCapabilities(target, next) {
  if (next.image === true) target.image = true
  if (target.reasoningEfforts === undefined && next.reasoningEfforts !== undefined) {
    target.reasoningEfforts = next.reasoningEfforts
    target.supportsReasoningEffort = true
  }
  if (target.thinkingFormat === undefined && next.thinkingFormat !== undefined) {
    target.thinkingFormat = next.thinkingFormat
  }
  return target
}

/**
 * Read explicit model capability fields from a `/models` entry.
 * @param {unknown} input - one listing entry.
 * @returns {{image?: true, reasoningEfforts?: Record<string, string|null>, supportsReasoningEffort?: true, thinkingFormat?: 'openai'|'openrouter'}}
 */
export function capabilitiesFromModelEntry(input) {
  if (!isRecord(input)) return {}
  const result = {}
  const architecture = member(input, 'architecture')
  const modalitySources = [
    input.input_modalities,
    member(architecture, 'input_modalities'),
    input.modalities,
  ]
  if (modalitySources.some(value => stringArray(value).some(item => item.toLowerCase() === 'image'))) {
    result.image = true
  }
  const capabilityNames = [
    ...stringArray(input.capabilities),
    ...Object.entries(isRecord(input.capabilities) ? input.capabilities : {})
      .filter(([, enabled]) => enabled === true)
      .map(([key]) => key),
  ].map(value => value.toLowerCase())
  if (capabilityNames.some(value => value === 'vision' || value === 'image' || value === 'image-input')) {
    result.image = true
  }
  if (input.vision === true || input.supports_vision === true || input.supportsVision === true) result.image = true

  const supported = stringArray(input.supported_parameters).map(value => value.toLowerCase())
  const reasoning = member(input, 'reasoning')
  if (isRecord(reasoning)) {
    const declared = reasoning.supported_efforts
    const efforts = declared === null
      ? reasoningEfforts(OPENROUTER_EFFORTS, { mandatory: reasoning.mandatory === true })
      : reasoningEfforts(stringArray(declared), { mandatory: reasoning.mandatory === true })
    if (efforts !== undefined) {
      result.reasoningEfforts = efforts
      result.supportsReasoningEffort = true
      result.thinkingFormat = 'openrouter'
    }
  }
  if (result.reasoningEfforts === undefined && supported.includes('reasoning')) {
    result.reasoningEfforts = reasoningEfforts(OPENROUTER_EFFORTS)
    result.supportsReasoningEffort = true
    result.thinkingFormat = 'openrouter'
  }
  if (result.reasoningEfforts === undefined
    && supported.some(value => value === 'reasoning_effort' || value === 'reasoning-effort')) {
    result.reasoningEfforts = reasoningEfforts(OPENAI_COMPATIBLE_EFFORTS)
    result.supportsReasoningEffort = true
    result.thinkingFormat = 'openai'
  }
  if (result.reasoningEfforts === undefined
    && capabilityNames.some(value => value === 'thinking' || value === 'reasoning')) {
    const explicit = reasoningEfforts(stringArray(input.reasoning_efforts ?? input.supported_reasoning_efforts))
    if (explicit !== undefined) {
      result.reasoningEfforts = explicit
      result.supportsReasoningEffort = true
      result.thinkingFormat = 'openai'
    }
  }
  return result
}

/**
 * Read Ollama's documented `/api/show` capability array.
 * @param {unknown} input - Ollama show response.
 * @returns {{image?: true, reasoningEfforts?: Record<string, string|null>, supportsReasoningEffort?: true, thinkingFormat?: 'openai'}}
 */
export function capabilitiesFromOllamaShow(input) {
  if (!isRecord(input) || !Array.isArray(input.capabilities)) return {}
  const capabilities = stringArray(input.capabilities).map(value => value.toLowerCase())
  const result = {}
  if (capabilities.includes('vision')) result.image = true
  if (capabilities.includes('thinking')) {
    result.reasoningEfforts = reasoningEfforts(OPENAI_COMPATIBLE_EFFORTS)
    result.supportsReasoningEffort = true
    result.thinkingFormat = 'openai'
  }
  return result
}

/** Build the headers used by metadata and active requests. */
function requestHeaders(profile, apiKey, json) {
  const headers = { accept: 'application/json' }
  if (isRecord(profile.headers)) {
    for (const [key, value] of Object.entries(profile.headers)) {
      if (typeof value === 'string') headers[key] = value
    }
  }
  if (apiKey !== undefined && apiKey.length > 0) {
    for (const key of Object.keys(headers)) if (key.toLowerCase() === 'authorization') delete headers[key]
    headers.authorization = `Bearer ${apiKey}`
  }
  if (json) headers['content-type'] = 'application/json'
  return headers
}

/** Run one request under both plugin disposal and a per-request timeout. */
async function withRequestSignal(parentSignal, timeoutMs, callback) {
  const controller = new AbortController()
  const abort = () => controller.abort(parentSignal?.reason)
  if (parentSignal?.aborted) abort()
  else parentSignal?.addEventListener('abort', abort, { once: true })
  const timeout = setTimeout(() => controller.abort(new Error('request timed out')), timeoutMs)
  try {
    return await callback(controller.signal)
  } finally {
    clearTimeout(timeout)
    parentSignal?.removeEventListener('abort', abort)
  }
}

/** Read and parse a bounded JSON response. */
async function readJson(response, url) {
  const shown = displayUrl(url)
  const declared = Number(response.headers.get('content-length') ?? Number.NaN)
  if (Number.isFinite(declared) && declared > MAX_RESPONSE_BYTES) {
    await response.body?.cancel()
    throw new Error(`${shown} returned more than ${MAX_RESPONSE_BYTES} bytes`)
  }
  if (response.body === null) throw new Error(`${shown} returned no response body`)
  const reader = response.body.getReader()
  const chunks = []
  let total = 0
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      total += value.byteLength
      if (total > MAX_RESPONSE_BYTES) throw new Error(`${shown} returned more than ${MAX_RESPONSE_BYTES} bytes`)
      chunks.push(value)
    }
  } finally {
    await reader.cancel().catch(() => {})
  }
  const bytes = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes))
  } catch (error) {
    throw new Error(`${shown} did not return JSON`, { cause: error })
  }
}

/** Execute one bounded JSON request. */
async function fetchJson(fetchImpl, url, init, options) {
  return withRequestSignal(options.signal, options.config.requestTimeoutMs, async signal => {
    const response = await fetchImpl(url, { ...init, signal, redirect: 'error' })
    if (!response.ok) {
      await response.body?.cancel()
      throw new HttpStatusError(`${init.method ?? 'GET'} ${displayUrl(url)} returned HTTP ${response.status}`, response.status)
    }
    return readJson(response, url)
  })
}

/** Append a path without discarding a deployment prefix. */
function appendPath(baseURL, path) {
  const url = new URL(baseURL)
  url.pathname = `${url.pathname.replace(/\/+$/u, '')}/${path.replace(/^\/+/, '')}`
  url.hash = ''
  return url.toString()
}

/** Derive Ollama's native show endpoint from either an `/api` or `/v1` base. */
function ollamaShowUrl(baseURL) {
  const url = new URL(baseURL)
  const trimmed = url.pathname.replace(/\/+$/u, '')
  if (trimmed.endsWith('/api')) url.pathname = `${trimmed}/show`
  else url.pathname = '/api/show'
  url.search = ''
  url.hash = ''
  return url.toString()
}

/**
 * Read free capability metadata for every configured model.
 * @param {{profile: Record<string, unknown>, modelIds: readonly string[], apiKey?: string, fetchImpl?: typeof fetch, signal?: AbortSignal, config: ReturnType<typeof resolveConfig>}} options - provider and request controls.
 * @returns {Promise<{capabilities: Map<string, object>, diagnostics: string[]}>}
 */
export async function readProviderMetadata(options) {
  const { profile, modelIds, apiKey, config, signal } = options
  const fetchImpl = options.fetchImpl ?? fetch
  const capabilities = new Map(modelIds.map(id => [id, {}]))
  const diagnostics = []
  if (config.metadataDiscovery !== true || typeof profile.baseURL !== 'string' || profile.baseURL.length === 0) {
    return { capabilities, diagnostics }
  }
  try {
    const url = appendPath(profile.baseURL, 'models')
    const body = await fetchJson(fetchImpl, url, {
      method: 'GET',
      headers: requestHeaders(profile, apiKey, false),
    }, { signal, config })
    const rows = isRecord(body) && Array.isArray(body.data) ? body.data : []
    for (const row of rows) {
      if (!isRecord(row) || typeof row.id !== 'string' || !capabilities.has(row.id)) continue
      mergeCapabilities(capabilities.get(row.id), capabilitiesFromModelEntry(row))
    }
  } catch (error) {
    diagnostics.push(error instanceof Error ? error.message : String(error))
  }
  if (!isLocalEndpoint(profile.baseURL)) return { capabilities, diagnostics }
  for (const modelId of modelIds) {
    const current = capabilities.get(modelId)
    if (current.image === true && current.reasoningEfforts !== undefined) continue
    try {
      const url = ollamaShowUrl(profile.baseURL)
      const body = await fetchJson(fetchImpl, url, {
        method: 'POST',
        headers: requestHeaders(profile, apiKey, true),
        body: JSON.stringify({ model: modelId, verbose: false }),
      }, { signal, config })
      if (!isRecord(body) || !Array.isArray(body.capabilities)) break
      mergeCapabilities(current, capabilitiesFromOllamaShow(body))
    } catch (error) {
      diagnostics.push(error instanceof Error ? error.message : String(error))
      // A local OpenAI-compatible endpoint is not necessarily Ollama. One
      // failed `/api/show` identifies that optional metadata dialect for the
      // whole provider, so do not repeat the same failed request per model.
      break
    }
  }
  return { capabilities, diagnostics }
}

/** Return non-empty reasoning text from a chat-completions response. */
function reasoningEvidence(body) {
  const choices = isRecord(body) && Array.isArray(body.choices) ? body.choices : []
  const message = member(choices[0], 'message')
  if (!isRecord(message)) return false
  for (const key of ['reasoning_content', 'reasoning', 'reasoning_text', 'thinking']) {
    if (typeof message[key] === 'string' && message[key].trim().length > 0) return true
  }
  return typeof message.content === 'string' && /<think>[\s\S]+<\/think>/iu.test(message.content)
}

/** Return text content from a chat-completions response. */
function responseText(body) {
  const choices = isRecord(body) && Array.isArray(body.choices) ? body.choices : []
  const content = member(member(choices[0], 'message'), 'content')
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content.map(part => isRecord(part) && typeof part.text === 'string' ? part.text : '').join(' ')
}

/** Run tasks with a fixed concurrency ceiling while preserving result order. */
async function mapConcurrent(values, limit, callback) {
  const result = new Array(values.length)
  let cursor = 0
  const worker = async () => {
    for (;;) {
      const index = cursor++
      if (index >= values.length) return
      result[index] = await callback(values[index])
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, values.length) }, () => worker()))
  return result
}

/**
 * Prove selectable reasoning levels by requiring reasoning evidence for each
 * successful local chat request.
 * @param {{profile: Record<string, unknown>, modelId: string, apiKey?: string, fetchImpl?: typeof fetch, signal?: AbortSignal, config: ReturnType<typeof resolveConfig>}} options - provider and request controls.
 * @returns {Promise<Record<string, string|null>|undefined>} positively observed effort map.
 */
export async function probeReasoningEfforts(options) {
  const { profile, modelId, apiKey, config, signal } = options
  if (config.reasoningProbe !== true || typeof profile.baseURL !== 'string') return undefined
  const fetchImpl = options.fetchImpl ?? fetch
  const url = appendPath(profile.baseURL, 'chat/completions')
  const bodyFor = effort => JSON.stringify({
    model: modelId,
    messages: [{ role: 'user', content: 'Calculate 17 * 19. Think briefly, then give only the number.' }],
    reasoning_effort: effort,
    max_tokens: config.probeMaxTokens,
    stream: false,
  })
  try {
    await fetchJson(fetchImpl, url, {
      method: 'POST',
      headers: requestHeaders(profile, apiKey, true),
      body: bodyFor(INVALID_REASONING_EFFORT),
    }, { signal, config })
    return undefined
  } catch (error) {
    if (!(error instanceof HttpStatusError) || (error.status !== 400 && error.status !== 422)) return undefined
  }
  const accepted = await mapConcurrent(config.reasoningProbeEfforts, config.probeConcurrency, async effort => {
    try {
      const body = await fetchJson(fetchImpl, url, {
        method: 'POST',
        headers: requestHeaders(profile, apiKey, true),
        body: bodyFor(effort),
      }, { signal, config })
      return reasoningEvidence(body) ? effort : undefined
    } catch {
      return undefined
    }
  })
  const efforts = reasoningEfforts(accepted.filter(value => value !== undefined), { mandatory: true })
  return efforts
}

/**
 * Prove image input with two randomly ordered private inline color tiles.
 * @param {{profile: Record<string, unknown>, modelId: string, apiKey?: string, fetchImpl?: typeof fetch, signal?: AbortSignal, config: ReturnType<typeof resolveConfig>}} options - provider and request controls.
 * @returns {Promise<boolean>} true only when both responses are exact color words.
 */
export async function probeVision(options) {
  const { profile, modelId, apiKey, config, signal } = options
  if (config.visionProbe !== true || typeof profile.baseURL !== 'string') return false
  const fetchImpl = options.fetchImpl ?? fetch
  const url = appendPath(profile.baseURL, 'chat/completions')
  const offset = randomInt(VISION_CHALLENGES.length)
  const challenges = [...VISION_CHALLENGES.slice(offset), ...VISION_CHALLENGES.slice(0, offset)]
  for (const challenge of challenges) {
    try {
      const body = await fetchJson(fetchImpl, url, {
        method: 'POST',
        headers: requestHeaders(profile, apiKey, true),
        body: JSON.stringify({
          model: modelId,
          messages: [{
            role: 'user',
            content: [
              { type: 'text', text: 'What is the dominant color of this image? Answer with one color word.' },
              { type: 'image_url', image_url: { url: challenge.image } },
            ],
          }],
          max_tokens: Math.min(config.probeMaxTokens, 32),
          stream: false,
        }),
      }, { signal, config })
      if (strictColorAnswer(responseText(body)) !== challenge.color) return false
    } catch {
      return false
    }
  }
  return true
}

/** Whether active probes are allowed for one provider endpoint. */
export function allowsActiveProbe(policy, baseURL) {
  return policy === 'always' || (policy === 'local-only' && isLocalEndpoint(baseURL))
}
