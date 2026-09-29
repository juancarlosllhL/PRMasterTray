import { createHighlighterCoreSync } from '@shikijs/core'
import { createJavaScriptRegexEngine } from '@shikijs/engine-javascript'
import cpp from '@shikijs/langs/cpp'
import csharp from '@shikijs/langs/csharp'
import css from '@shikijs/langs/css'
import docker from '@shikijs/langs/docker'
import go from '@shikijs/langs/go'
import graphql from '@shikijs/langs/graphql'
import hcl from '@shikijs/langs/hcl'
import html from '@shikijs/langs/html'
import java from '@shikijs/langs/java'
import javascript from '@shikijs/langs/javascript'
import json from '@shikijs/langs/json'
import kotlin from '@shikijs/langs/kotlin'
import make from '@shikijs/langs/make'
import markdown from '@shikijs/langs/markdown'
import python from '@shikijs/langs/python'
import ruby from '@shikijs/langs/ruby'
import rust from '@shikijs/langs/rust'
import shellscript from '@shikijs/langs/shellscript'
import sql from '@shikijs/langs/sql'
import swift from '@shikijs/langs/swift'
import toml from '@shikijs/langs/toml'
import tsx from '@shikijs/langs/tsx'
import typescript from '@shikijs/langs/typescript'
import xml from '@shikijs/langs/xml'
import yaml from '@shikijs/langs/yaml'
import githubDarkDefault from '@shikijs/themes/github-dark-default'
import githubDarkHighContrast from '@shikijs/themes/github-dark-high-contrast'
import githubLightDefault from '@shikijs/themes/github-light-default'
import githubLightHighContrast from '@shikijs/themes/github-light-high-contrast'

const languages = {
  cpp, csharp, css, docker, go, graphql, hcl, html, java, javascript, json, kotlin, make, markdown,
  python, ruby, rust, shellscript, sql, swift, toml, tsx, typescript, xml, yaml,
}
const themes = [githubLightDefault, githubDarkDefault, githubLightHighContrast, githubDarkHighContrast]

const highlighter = createHighlighterCoreSync({
  engine: createJavaScriptRegexEngine(),
  themes,
  langs: Object.values(languages),
})

// Returns JSON: each segment is null when Shiki's lines do not map one to one onto the input.
function highlight(segments, language, theme) {
  const foreground = highlighter.getTheme(theme).fg.toUpperCase()
  const colours = []
  const colourIndex = new Map()
  const indexOf = colour => {
    const key = (colour ?? '').toUpperCase()
    if (!colourIndex.has(key)) { colourIndex.set(key, colours.length); colours.push(key) }
    return colourIndex.get(key)
  }
  const result = segments.map(lines => {
    if (lines.length === 0) return []
    const code = lines.join('\n')
    const tokens = highlighter.codeToTokensBase(code, { lang: language, theme, tokenizeMaxLineLength: 2000 })
    if (tokens.length !== lines.length) return null
    let lineStart = 0
    return tokens.map((line, index) => {
      const ranges = []
      for (const token of line) {
        const style = Math.max(token.fontStyle ?? 0, 0)
        if (token.content.length === 0 || (style === 0 && (token.color ?? '').toUpperCase() === foreground)) continue
        ranges.push(token.offset - lineStart, token.content.length, indexOf(token.color), style)
      }
      lineStart += lines[index].length + 1
      return ranges
    })
  })
  return JSON.stringify({ colours, segments: result })
}

function themeColours(theme) {
  const resolved = highlighter.getTheme(theme)
  const foregrounds = resolved.settings.map(rule => rule.settings?.foreground).filter(Boolean)
  return [...new Set([resolved.fg, ...foregrounds].map(colour => colour.toUpperCase()))]
}

globalThis.prmaster = {
  highlight,
  themeColours,
  languages: () => Object.keys(languages),
  themes: () => themes.map(theme => theme.name),
  grammarFiles: () => [...new Set(Object.values(languages).flat().map(grammar => `${grammar.name}.json`))],
}
