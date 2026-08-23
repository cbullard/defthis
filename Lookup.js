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

function lookupCandidates(rawTerm) {
  var term = normalizedTerm(rawTerm)
  if (term.length === 0)
    return []

  var lowercaseTerm = term.toLocaleLowerCase()
  return lowercaseTerm === term ? [term] : [term, lowercaseTerm]
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
