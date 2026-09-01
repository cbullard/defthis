.pragma library

function normalizedTerm(rawText) {
  var term = String(rawText || "").trim()
  var edgePunctuation = "\"“”‘’.,;:!?()[]{}<>"

  while (term.length > 0 && edgePunctuation.indexOf(term.charAt(0)) !== -1)
    term = term.slice(1)
  while (term.length > 0 && edgePunctuation.indexOf(term.charAt(term.length - 1)) !== -1)
    term = term.slice(0, -1)

  if (term.length === 0 || term.length > 80 || /\s/.test(term))
    return ""
  return term
}

function lowercaseFallback(rawTerm) {
  var term = normalizedTerm(rawTerm)
  if (term.length === 0)
    return ""

  var lowercaseTerm = term.toLocaleLowerCase()
  return lowercaseTerm === term ? "" : lowercaseTerm
}

function historyLimit(value, fallback) {
  var limit = Number(value)
  if (isNaN(limit)) limit = fallback === undefined ? 50 : Number(fallback)
  if (isNaN(limit)) limit = 50
  return Math.max(0, Math.floor(limit))
}

function normalizeRecentTerms(values, cacheEntries, limit) {
  var source = Array.isArray(values) ? values : []
  var entries = cacheEntries && typeof cacheEntries === "object" ? cacheEntries : ({})
  var maximum = historyLimit(limit, 50)
  var seen = ({})
  var recent = []

  for (var index = 0; index < source.length && recent.length < maximum; index++) {
    var term = normalizedTerm(source[index])
    var key = term.toLocaleLowerCase()
    var definitions = entries[key]
    if (!term || seen[key] || !Array.isArray(definitions) || definitions.length === 0)
      continue
    seen[key] = true
    recent.push(term)
  }

  return recent
}

function recentTermsFromEntries(cacheEntries, limit) {
  var entries = cacheEntries && typeof cacheEntries === "object" ? cacheEntries : ({})
  var terms = []
  for (var key in entries) {
    if (Array.isArray(entries[key]) && entries[key].length > 0)
      terms.unshift(key)
  }
  return normalizeRecentTerms(terms, entries, limit)
}

function recordRecentTerm(values, rawTerm, cacheEntries, limit) {
  var term = normalizedTerm(rawTerm)
  var source = Array.isArray(values) ? values.slice() : []
  if (term.length > 0) source.unshift(term)
  return normalizeRecentTerms(source, cacheEntries, limit)
}

function removeRecentTerm(values, rawTerm, cacheEntries, limit) {
  var target = normalizedTerm(rawTerm).toLocaleLowerCase()
  var source = Array.isArray(values) ? values : []
  var remaining = []
  for (var index = 0; index < source.length; index++) {
    var term = normalizedTerm(source[index])
    if (term.length > 0 && term.toLocaleLowerCase() !== target)
      remaining.push(term)
  }
  return normalizeRecentTerms(remaining, cacheEntries, limit)
}

function cacheEntriesWithoutTerm(cacheEntries, rawTerm) {
  var entries = cacheEntries && typeof cacheEntries === "object" ? cacheEntries : ({})
  var target = normalizedTerm(rawTerm).toLocaleLowerCase()
  var remaining = ({})
  for (var key in entries) {
    if (key.toLocaleLowerCase() !== target)
      remaining[key] = entries[key]
  }
  return remaining
}

function cacheAliasesWithoutTerm(cacheAliases, rawTerm) {
  var aliases = cacheAliases && typeof cacheAliases === "object"
    ? cacheAliases : ({})
  var target = normalizedTerm(rawTerm).toLocaleLowerCase()
  var remaining = ({})
  for (var key in aliases) {
    var resolved = normalizedTerm(aliases[key]).toLocaleLowerCase()
    if (key.toLocaleLowerCase() !== target && resolved !== target)
      remaining[key] = aliases[key]
  }
  return remaining
}

function plainText(html) {
  return String(html || "")
    .replace(/<[^>]*>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"")
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&#(\d+);/g, function(match, value) {
      return String.fromCharCode(parseInt(value, 10))
    })
    .replace(/\s+/g, " ")
    .trim()
}

function definitionsFromResponse(rawJson) {
  var payload
  try {
    payload = JSON.parse(rawJson)
  } catch (error) {
    return []
  }

  var entries = payload && payload.en instanceof Array ? payload.en : []
  var definitions = []
  for (var entryIndex = 0; entryIndex < entries.length; entryIndex++) {
    var entry = entries[entryIndex] || {}
    var senses = entry.definitions instanceof Array ? entry.definitions : []
    for (var senseIndex = 0; senseIndex < senses.length; senseIndex++) {
      var definition = plainText((senses[senseIndex] || {}).definition)
      if (definition.length > 0) {
        definitions.push({
          partOfSpeech: String(entry.partOfSpeech || ""),
          definition: definition
        })
      }
      if (definitions.length >= 8)
        return definitions
    }
  }
  return definitions
}

function singularLemma(definitions) {
  var entries = definitions instanceof Array ? definitions : []
  var prefix = "plural of "
  for (var index = 0; index < entries.length; index++) {
    var entry = entries[index] || {}
    if (String(entry.partOfSpeech || "").toLocaleLowerCase() !== "noun")
      continue
    var definition = String(entry.definition || "").trim()
    if (definition.toLocaleLowerCase().indexOf(prefix) !== 0)
      continue
    var lemma = normalizedTerm(definition.slice(prefix.length))
    if (lemma.length > 0)
      return lemma
  }
  return ""
}
