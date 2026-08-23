import QtQuick
import QtTest
import "../Lookup.js" as Lookup

TestCase {
  name: "Lookup"

  function test_normalizesSelectedWords() {
    compare(Lookup.normalizedTerm("  serendipity  "), "serendipity")
    compare(Lookup.normalizedTerm("“well-known”"), "well-known")
    compare(Lookup.normalizedTerm("café"), "café")
    compare(Lookup.normalizedTerm("two words"), "")
    compare(Lookup.normalizedTerm(""), "")
  }

  function test_preservesCaseBeforeTryingLowercase() {
    compare(Lookup.lowercaseFallback("Serendipity"), "serendipity")
    compare(Lookup.lowercaseFallback("US"), "us")
    compare(Lookup.lowercaseFallback("serendipity"), "")
    compare(Lookup.lowercaseFallback("two words"), "")
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
    var definitions = Lookup.definitionsFromResponse(response)
    compare(definitions.length, 2)
    compare(definitions[0].partOfSpeech, "Noun")
    compare(definitions[0].definition, "A happy accident.")
    compare(Lookup.definitionsFromResponse("not json").length, 0)
  }
}
