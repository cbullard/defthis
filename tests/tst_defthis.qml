import QtQuick
import QtTest
import "../DefThis.js" as DefThis

TestCase {
  name: "DefThis"

  function test_normalizesSelectedWords() {
    compare(DefThis.normalizedTerm("  serendipity  "), "serendipity")
    compare(DefThis.normalizedTerm("“well-known”"), "well-known")
    compare(DefThis.normalizedTerm("café"), "café")
    compare(DefThis.normalizedTerm("two words"), "")
    compare(DefThis.normalizedTerm(""), "")
  }

  function test_preservesCaseBeforeTryingLowercase() {
    compare(DefThis.lowercaseFallback("Serendipity"), "serendipity")
    compare(DefThis.lowercaseFallback("US"), "us")
    compare(DefThis.lowercaseFallback("serendipity"), "")
    compare(DefThis.lowercaseFallback("two words"), "")
  }

  function test_tracksUniqueRecentTerms() {
    var entries = {
      luminous: [{ definition: "Emitting light." }],
      ephemeral: [{ definition: "Lasting briefly." }],
      serendipity: [{ definition: "A happy accident." }]
    }
    var recent = ["ephemeral", "luminous"]

    recent = DefThis.recordRecentTerm(recent, "Luminous", entries, 3)
    compare(recent.length, 2)
    compare(recent[0], "Luminous")
    compare(recent[1], "ephemeral")

    recent = DefThis.recordRecentTerm(recent, "serendipity", entries, 2)
    compare(recent.length, 2)
    compare(recent[0], "serendipity")
    compare(recent[1], "Luminous")
  }

  function test_filtersInvalidRecentTerms() {
    var entries = {
      luminous: [{ definition: "Emitting light." }],
      empty: []
    }
    var recent = DefThis.normalizeRecentTerms(
      ["luminous", "LUMINOUS", "two words", "empty", "missing"], entries, 50)

    compare(recent.length, 1)
    compare(recent[0], "luminous")
  }

  function test_migratesAndRemovesRecentTerms() {
    var entries = {
      first: [{ definition: "First." }],
      second: [{ definition: "Second." }]
    }
    var recent = DefThis.recentTermsFromEntries(entries, 50)
    compare(recent.length, 2)
    compare(recent[0], "second")
    compare(recent[1], "first")

    entries = DefThis.cacheEntriesWithoutTerm(entries, "SECOND")
    verify(entries.first !== undefined)
    verify(entries.second === undefined)
    recent = DefThis.removeRecentTerm(recent, "SECOND", entries, 50)
    compare(recent.length, 1)
    compare(recent[0], "first")
  }

  function test_parsesWiktionaryDefinitions() {
    var response = JSON.stringify({
      en: [{
        partOfSpeech: "Noun",
        definitions: [
          { definition: "A <a href=\"/wiki/happy\">happy</a> accident." },
          { definition: "An unexpected discovery." }
        ]
      }]
    })
    var definitions = DefThis.definitionsFromResponse(response)
    compare(definitions.length, 2)
    compare(definitions[0].partOfSpeech, "Noun")
    compare(definitions[0].definition, "A happy accident.")
    compare(DefThis.definitionsFromResponse("not json").length, 0)
  }

  function test_extractsSingularLemmaFromNounPluralDefinition() {
    var definitions = [
      {
        partOfSpeech: "Verb",
        definition: "third-person singular simple present indicative of knife"
      },
      { partOfSpeech: "Noun", definition: "plural of knife" },
      { partOfSpeech: "Noun", definition: "plural of knive" }
    ]
    compare(DefThis.singularLemma(definitions), "knife")
    compare(DefThis.singularLemma([
      { partOfSpeech: "Noun", definition: "Plural of child." }
    ]), "child")
  }

  function test_rejectsNonNounAndMultiwordPluralTargets() {
    compare(DefThis.singularLemma([
      { partOfSpeech: "Verb", definition: "plural of cat" }
    ]), "")
    compare(DefThis.singularLemma([
      { partOfSpeech: "Noun", definition: "plural of two words" }
    ]), "")
  }

  function test_removesAliasesForDeletedTerms() {
    var aliases = { children: "child", knives: "knife", cats: "cat" }
    var remaining = DefThis.cacheAliasesWithoutTerm(aliases, "child")
    verify(remaining.children === undefined)
    compare(remaining.knives, "knife")
    compare(remaining.cats, "cat")
  }
}
