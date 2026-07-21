import { createHash } from 'node:crypto'
import { copyFileSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

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
  return value
}

function main() {
  const args = parseArguments(process.argv.slice(2))
  const installerPath = resolve(required(args, 'installer'))
  const signaturePath = resolve(required(args, 'signature'))
  const outputDirectory = resolve(required(args, 'output-dir'))
  const version = required(args, 'version')
  const assetName = required(args, 'asset-name')
  const repository = required(args, 'repository')
  const notes = required(args, 'notes')
  const releaseDate = new Date(args.get('release-date') ?? Date.now()).toISOString()

  if (!/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version)) {
    throw new Error(`invalid release version ${version}`)
  }
  if (!assetName.includes(version) || /[\\/]/.test(assetName)) {
    throw new Error(`asset name ${assetName} must contain version ${version} and no path separators`)
  }
  if (!/^[^/\s]+\/[^/\s]+$/.test(repository)) {
    throw new Error(`invalid GitHub repository ${repository}`)
  }

  const installer = readFileSync(installerPath)
  const signature = readFileSync(signaturePath, 'utf8').trim()
  if (!signature) throw new Error('updater signature is empty')

  const sha512 = createHash('sha512').update(installer).digest('base64')
  const size = statSync(installerPath).size
  const downloadUrl = `https://github.com/${repository}/releases/download/v${version}/${assetName}`
  const latestJson = {
    version,
    notes,
    pub_date: releaseDate,
    platforms: {
      'windows-x86_64-nsis': {
        signature,
        url: downloadUrl,
      },
      'windows-x86_64': {
        signature,
        url: downloadUrl,
      },
    },
  }
  const latestYml = [
    `version: ${version}`,
    'files:',
    `  - url: ${assetName}`,
    `    sha512: ${sha512}`,
    `    size: ${size}`,
    `path: ${assetName}`,
    `sha512: ${sha512}`,
    `releaseDate: '${releaseDate}'`,
    '',
  ].join('\n')

  mkdirSync(outputDirectory, { recursive: true })
  const releaseInstallerPath = join(outputDirectory, assetName)
  const releaseSignaturePath = `${releaseInstallerPath}.sig`
  const latestJsonPath = join(outputDirectory, 'latest.json')
  const latestYmlPath = join(outputDirectory, 'latest.yml')
  if (installerPath !== resolve(releaseInstallerPath)) copyFileSync(installerPath, releaseInstallerPath)
  writeFileSync(releaseSignaturePath, signature)
  writeFileSync(latestJsonPath, `${JSON.stringify(latestJson, null, 2)}\n`)
  writeFileSync(latestYmlPath, latestYml)
  process.stdout.write(`${JSON.stringify({
    releaseInstallerPath,
    releaseSignaturePath,
    latestJsonPath,
    latestYmlPath,
    sha512,
    size,
  }, null, 2)}\n`)
}

try {
  main()
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
  process.exitCode = 1
}
