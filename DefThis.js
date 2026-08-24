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
