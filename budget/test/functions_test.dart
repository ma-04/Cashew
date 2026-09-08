// Replaces the stock `widget_test.dart` that `flutter create` leaves behind.
// That one asserted a counter app that does not exist here, with its
// pumpWidget call commented out, so it could never pass - it failed every CI
// run. These cover small pure helpers instead: enough for `flutter test` to
// have something real to run, with no database, localization or widget
// binding to set up.

import "package:budget/functions.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  group("removeLastCharacter", () {
    test("removes the final character", () {
      expect(removeLastCharacter("abc"), "ab");
    });
    test("leaves an empty string empty", () {
      expect(removeLastCharacter(""), "");
    });
    test("empties a single character string", () {
      expect(removeLastCharacter("a"), "");
    });
  });

  group("hasDecimalPoints", () {
    test("is false for null", () {
      expect(hasDecimalPoints(null), false);
    });
    test("is false for a whole number", () {
      expect(hasDecimalPoints(12.0), false);
    });
    test("is true for a fractional number", () {
      expect(hasDecimalPoints(12.5), true);
    });
  });

  group("daysBetween", () {
    test("counts a single day inclusively", () {
      expect(daysBetween(DateTime(2024, 1, 1), DateTime(2024, 1, 1)), 1);
    });
    test("counts a range inclusively", () {
      expect(daysBetween(DateTime(2024, 1, 1), DateTime(2024, 1, 3)), 3);
    });
    test("ignores the time of day", () {
      expect(
        daysBetween(DateTime(2024, 1, 1, 23, 59), DateTime(2024, 1, 2, 0, 1)),
        2,
      );
    });
  });
}
