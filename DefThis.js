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

function utf8ByteLength(value) {
  var text = String(value || "")
  var bytes = 0
  for (var index = 0; index < text.length; index++) {
    var code = text.charCodeAt(index)
    if (code <= 0x7f) {
      bytes += 1
    } else if (code <= 0x7ff) {
      bytes += 2
    } else if (code >= 0xd800 && code <= 0xdbff
               && index + 1 < text.length
               && text.charCodeAt(index + 1) >= 0xdc00
               && text.charCodeAt(index + 1) <= 0xdfff) {
      bytes += 4
      index += 1
    } else {
      bytes += 3
    }
  }
  return bytes
}

function cachePayloadText(entries) {
  return JSON.stringify({ version: 1, entries: entries }, null, 2) + "\n"
}

function boundedCacheEntries(cacheEntries, maxEntries, maxBytes) {
  var entries = cacheEntries && typeof cacheEntries === "object" ? cacheEntries : ({})
  var entryLimit = Math.max(0, Math.floor(Number(maxEntries) || 0))
  var byteLimit = Math.max(0, Math.floor(Number(maxBytes) || 0))
  var keys = Object.keys(entries)
  var start = Math.max(0, keys.length - entryLimit)

  function entriesFrom(offset) {
    var bounded = ({})
    for (var index = offset; index < keys.length; index++)
      bounded[keys[index]] = entries[keys[index]]
    return bounded
  }

  var bounded = entriesFrom(start)
  while (start < keys.length && utf8ByteLength(cachePayloadText(bounded)) > byteLimit) {
    start += 1
    bounded = entriesFrom(start)
  }
  return bounded
}

function withBoundedCacheEntry(cacheEntries, cacheKey, definitions, maxEntries, maxBytes) {
  var entries = cacheEntries && typeof cacheEntries === "object" ? cacheEntries : ({})
  var key = String(cacheKey || "")
  var ordered = ({})
  var keys = Object.keys(entries)
  for (var index = 0; index < keys.length; index++) {
    if (keys[index] !== key)
      ordered[keys[index]] = entries[keys[index]]
  }
  if (key.length > 0 && Array.isArray(definitions) && definitions.length > 0)
    ordered[key] = definitions
  return boundedCacheEntries(ordered, maxEntries, maxBytes)
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
