import { createHash } from 'node:crypto'
import { readFileSync, statSync } from 'node:fs'
import { basename, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'

import { load as loadYaml } from 'js-yaml'

function parseArguments(argv) {
  const values = new Map()
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]
    const value = argv[index + 1]
    if (!key?.startsWith('--') || value === undefined) {
      throw new Error(`invalid argument near ${key ?? '<end>'}`)
    }
    values.set(key.slice(2), value)
  }
  return values
}

function required(values, name) {
  const value = values.get(name)
  if (!value) throw new Error(`missing required argument --${name}`)
  return resolve(value)
}

function assertEqual(label, actual, expected) {
  if (actual !== expected) {
    throw new Error(`${label} mismatch: expected ${expected}, received ${actual}`)
  }
}

function main() {
  const args = parseArguments(process.argv.slice(2))
  const installerPath = required(args, 'installer')
  const signaturePath = required(args, 'signature')
  const latestJsonPath = required(args, 'latest-json')
  const latestYmlPath = required(args, 'latest-yml')
  const tauriConfigPath = required(args, 'tauri-config')
  const expectedVersion = args.get('expected-version')
  if (!expectedVersion) throw new Error('missing required argument --expected-version')

  const installer = readFileSync(installerPath)
  const signature = readFileSync(signaturePath, 'utf8').trim()
  const latestJson = JSON.parse(readFileSync(latestJsonPath, 'utf8'))
  const latestYml = loadYaml(readFileSync(latestYmlPath, 'utf8'))
  const assetName = basename(installerPath)
  const expectedUrlSuffix = `/${assetName}`
  const sha512 = createHash('sha512').update(installer).digest('base64')
  const size = statSync(installerPath).size

  assertEqual('latest.json version', latestJson.version, expectedVersion)
  for (const platform of ['windows-x86_64-nsis', 'windows-x86_64']) {
    const metadata = latestJson.platforms?.[platform]
    if (!metadata) throw new Error(`latest.json platform missing: ${platform}`)
    assertEqual(`${platform} signature`, metadata.signature, signature)
    if (!metadata.url?.endsWith(expectedUrlSuffix)) {
      throw new Error(`${platform} URL mismatch: ${metadata.url}`)
    }
  }

  assertEqual('latest.yml version', String(latestYml.version), expectedVersion)
  assertEqual('latest.yml path', latestYml.path, assetName)
  assertEqual('latest.yml SHA-512', latestYml.sha512, sha512)
  const electronFile = latestYml.files?.[0]
  if (!electronFile) throw new Error('latest.yml files[0] is missing')
  assertEqual('latest.yml file URL', electronFile.url, assetName)
  assertEqual('latest.yml file SHA-512', electronFile.sha512, sha512)
  assertEqual('latest.yml file size', Number(electronFile.size), size)

  const signatureResult = spawnSync('cargo', [
    'run',
    '--quiet',
    '--manifest-path', resolve('src-tauri/Cargo.toml'),
    '--example', 'verify_update_signature',
    '--', tauriConfigPath, installerPath, signaturePath,
  ], { encoding: 'utf8' })
  if (signatureResult.status !== 0) {
    throw new Error(`signature verification failed: ${signatureResult.stderr.trim()}`)
  }

  process.stdout.write(`${JSON.stringify({
    version: expectedVersion,
    installerPath,
    signatureValid: true,
    size,
    sha256: createHash('sha256').update(installer).digest('hex').toUpperCase(),
    sha512,
  }, null, 2)}\n`)
}

try {
  main()
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
  process.exitCode = 1
}
