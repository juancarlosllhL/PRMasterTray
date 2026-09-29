import fs from 'node:fs'
import vm from 'node:vm'
import { grammars } from 'tm-grammars'

const [bundlePath, outputPath] = process.argv.slice(2)
const context = {}
vm.runInNewContext(fs.readFileSync(bundlePath, 'utf8'), context)
const wanted = new Set([
  ...context.prmaster.grammarFiles(),
  ...context.prmaster.themes().map(theme => `${theme}.json`),
])

const covered = new Set()

function sections(path) {
  const [header, ...rest] = fs.readFileSync(path, 'utf8').split(/^=+$/m)
  const kept = rest.filter(section => {
    const files = (section.match(/^Files:\s*(.+)$/m)?.[1] ?? '').split(/[,\s]+/)
    files.filter(file => wanted.has(file)).forEach(file => covered.add(file))
    return files.some(file => wanted.has(file))
  })
  return [header.trim(), ...kept.map(section => section.trim())].join(`\n\n${'='.repeat(80)}\n`)
}

// tm-grammars' NOTICE skips grammars whose upstream declares no licence; credit their source instead.
function unlicensed() {
  const lines = [...wanted].filter(file => !covered.has(file)).map(file => {
    const grammar = grammars.find(entry => `${entry.name}.json` === file)
    return `Files:   ${file}\nSource:  ${grammar?.source ?? 'unknown'}`
  })
  return ['Grammars with no licence declared upstream:', ...lines].join('\n\n')
}

const grammarNotices = sections('node_modules/tm-grammars/NOTICE')
const themeNotices = sections('node_modules/tm-themes/NOTICE')
fs.writeFileSync(outputPath, [
  `PRMaster bundles Shiki with the TextMate grammars and themes below.\n\n${fs.readFileSync('node_modules/@shikijs/core/LICENSE', 'utf8').trim()}`,
  grammarNotices,
  themeNotices,
  unlicensed(),
].join(`\n\n${'#'.repeat(80)}\n\n`) + '\n')
