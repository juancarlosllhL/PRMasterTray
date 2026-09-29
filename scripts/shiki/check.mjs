import fs from 'node:fs'
import vm from 'node:vm'

const [bundlePath, noticesPath] = process.argv.slice(2)
const context = {}
vm.runInNewContext(fs.readFileSync(bundlePath, 'utf8'), context)
const shiki = context.prmaster
const fail = message => { console.error(`check failed: ${message}`); process.exit(1) }

for (const name of ['highlight', 'themeColours', 'languages', 'themes']) {
  if (typeof shiki?.[name] !== 'function') fail(`prmaster.${name} is not exported`)
}
const languages = shiki.languages()
if (languages.length !== 25) fail(`expected 25 languages, got ${languages.length}`)
for (const theme of shiki.themes()) {
  for (const language of languages) {
    const result = JSON.parse(shiki.highlight([['let a = "b" // c']], language, theme))
    if (!Array.isArray(result.segments?.[0]) || result.segments[0].length !== 1) fail(`${language} in ${theme}`)
  }
  if (shiki.themeColours(theme).length < 5) fail(`${theme} has too few colours`)
}
const notices = fs.readFileSync(noticesPath, 'utf8')
for (const file of [...shiki.grammarFiles(), ...shiki.themes().map(theme => `${theme}.json`)]) {
  if (!notices.includes(file)) fail(`notices miss ${file}`)
}
if (!notices.includes('MIT License')) fail('notices miss Shiki\'s own licence')
console.log(`bundle ok: ${languages.length} languages, ${shiki.themes().length} themes`)
