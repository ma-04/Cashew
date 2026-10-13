// The smallest proof that the live instance answers as the fake claims, and
// that the client reads it.
@Tags(['live'])
library;

import 'package:budget/struct/firefly/fireflyApiClient.dart';
import 'package:budget/struct/firefly/fireflyModels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'firefly_live_env.dart';

void main() {
  liveGroup('live smoke', (live) {
    test('the instance is the version that the fake copies', () async {
      FireflyApiClient client = live.client();
      FireflyAbout about = await client.getAbout();
      expect(about.version, "6.7.9");
    });

    test('a date with an offset is stored as that instant', () async {
      int accountId = await live.createAssetAccount('Live checking');
      LiveResponse created = await live.createWithdrawal(
        sourceId: accountId,
        amount: "10.123",
        date: "2024-05-01T23:30:00+02:00",
        description: "Live smoke",
      );

      FireflyApiClient client = live.client();
      FireflyTransactionGroup group = await client.getTransaction(created.id);
      expect(group.splits, hasLength(1));
      DateTime date = group.splits.single.date;
      expect(date.isAtSameMomentAs(DateTime.utc(2024, 5, 1, 21, 30)), isTrue,
          reason: "read $date (${date.toUtc()})");
      expect(group.splits.single.amount, closeTo(10.123, 1e-9));

      LiveResponse raw = await live.get("/transactions/${created.id}");
      Map<String, dynamic> split =
          Map<String, dynamic>.from(raw.attributes["transactions"][0]);
      expect(split["date"], "2024-05-01T21:30:00+00:00");
      expect(split["amount"], "10.123000000000");
    });
  });
}
