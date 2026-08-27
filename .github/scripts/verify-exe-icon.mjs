import assert from 'node:assert/strict'
import fs from 'node:fs'
import { pathToFileURL } from 'node:url'

const expectedSizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
const [icoPath, exePath, reseditPath] = process.argv.slice(2)

if (!icoPath || !exePath || !reseditPath) {
  throw new Error('usage: verify-exe-icon.mjs <icon.ico> <app.exe> <resedit-index.js>')
}

const { Data, NtExecutable, NtExecutableResource, Resource } = await import(pathToFileURL(reseditPath).href)

function pngDescriptor(value, label) {
  const bytes = Buffer.from(value)
  assert.ok(bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])), `${label} is not PNG-compressed`)
  assert.equal(bytes.toString('ascii', 12, 16), 'IHDR', `${label} has no PNG IHDR`)
  const width = bytes.readUInt32BE(16)
  const height = bytes.readUInt32BE(20)
  assert.equal(width, height, `${label} is not square`)
  assert.equal(bytes[24], 8, `${label} must use 8-bit PNG channels`)
  assert.equal(bytes[25], 6, `${label} must use RGBA PNG pixels`)
  return { bytes, size: width }
}

function rawDescriptors(items, label) {
  return items.map((item, index) => {
    assert.equal(item.isRaw(), true, `${label} entry ${index + 1} is not a raw PNG icon`)
    return pngDescriptor(item.bin, `${label} entry ${index + 1}`)
  })
}

function assertSizes(items, label) {
  const sizes = items.map(({ size }) => size).sort((left, right) => left - right)
  assert.deepEqual(sizes, expectedSizes, `${label} must contain exactly the nine supported sizes`)
}

const iconFile = Data.IconFile.from(fs.readFileSync(icoPath))
const sourceIcons = rawDescriptors(iconFile.icons.map(({ data }) => data), 'source ICO')
assertSizes(sourceIcons, 'source ICO')

const executable = NtExecutable.from(fs.readFileSync(exePath))
const resources = NtExecutableResource.from(executable)
const groups = Resource.IconGroupEntry.fromEntries(resources.entries)
assert.equal(groups.length, 1, 'packaged EXE must contain exactly one icon group')

const groupSizes = groups[0].icons.map(({ width, height }) => {
  const normalizedWidth = width || 256
  const normalizedHeight = height || 256
  assert.equal(normalizedWidth, normalizedHeight, 'packaged EXE icon-group entry is not square')
  return { size: normalizedWidth }
})
assertSizes(groupSizes, 'packaged EXE icon group')

const embeddedIcons = rawDescriptors(groups[0].getIconItemsFromEntries(resources.entries), 'packaged EXE')
assertSizes(embeddedIcons, 'packaged EXE')

const sourceBySize = new Map(sourceIcons.map((item) => [item.size, item.bytes]))
for (const embedded of embeddedIcons) {
  assert.ok(embedded.bytes.equals(sourceBySize.get(embedded.size)), `packaged EXE ${embedded.size}px icon differs from the source ICO`)
}

console.log(`verified embedded icon sizes: ${expectedSizes.join(', ')}`)
