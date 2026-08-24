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

}
