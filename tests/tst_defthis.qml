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

  function test_countsUtf8Bytes() {
    compare(DefThis.utf8ByteLength("plain"), 5)
    compare(DefThis.utf8ByteLength("café"), 5)
    compare(DefThis.utf8ByteLength("😀"), 4)
  }

  function test_boundsCacheByEntryCountAndRecency() {
    var entries = {
      first: [{ definition: "First." }],
      second: [{ definition: "Second." }],
      third: [{ definition: "Third." }]
    }
    var bounded = DefThis.boundedCacheEntries(entries, 2, 10000)
    compare(Object.keys(bounded).length, 2)
    verify(bounded.first === undefined)
    verify(bounded.second !== undefined)
    verify(bounded.third !== undefined)

    bounded = DefThis.withBoundedCacheEntry(
      bounded, "second", [{ definition: "Updated." }], 2, 10000)
    compare(Object.keys(bounded)[0], "third")
    compare(Object.keys(bounded)[1], "second")
    compare(bounded.second[0].definition, "Updated.")
  }

  function test_boundsSerializedCacheBytes() {
    var entries = {
      first: [{ definition: new Array(121).join("A") }],
      second: [{ definition: new Array(121).join("B") }]
    }
    var bounded = DefThis.boundedCacheEntries(entries, 10, 220)
    verify(DefThis.utf8ByteLength(DefThis.cachePayloadText(bounded)) <= 220)
    verify(Object.keys(bounded).length < 2)
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
