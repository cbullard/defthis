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
}
