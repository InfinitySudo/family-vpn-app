import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/family/country/okno_country.dart';
import 'package:hiddify/features/family/country/okno_country_notifier.dart';

OknoServer s(String tag, int delay) => OknoServer(tag: tag, country: countryCodeOfTag(tag), delay: delay);

void main() {
  test("протокол из тега", () {
    expect(protocolOfTag("Окно-LV-1-Reality"), "Reality");
    expect(protocolOfTag("Окно-FI-3-HY2"), "HY2");
    expect(protocolOfTag("Окно-2-HY2"), "HY2");
    expect(isUdpProtocolTag("Окно-FI-3-HY2"), isTrue);
    expect(isUdpProtocolTag("Окно-FI-3-Reality"), isFalse);
  });

  test("Reality впереди HY2 даже при худшем пинге", () {
    final r = rankServers([s("Окно-FI-3-HY2", 40), s("Окно-FI-3-Reality", 120), s("Окно-NL-4-Reality", 90)]);
    expect(r.map((e) => e.tag).toList(), ["Окно-NL-4-Reality", "Окно-FI-3-Reality", "Окно-FI-3-HY2"]);
  });

  test("неизмеренный Reality впереди живого HY2, таймауты в конце", () {
    final r = rankServers([s("Окно-FI-3-HY2", 40), s("Окно-FI-3-Reality", 0), s("Окно-NL-4-Reality", oknoDelayTimeout), s("Окно-NL-4-HY2", oknoDelayTimeout)]);
    expect(r.map((e) => e.tag).toList(), ["Окно-FI-3-Reality", "Окно-FI-3-HY2", "Окно-NL-4-Reality", "Окно-NL-4-HY2"]);
  });

  test("HY2 берётся, только когда все Reality не отвечают", () {
    final r = rankServers([s("Окно-FI-3-Reality", oknoDelayTimeout), s("Окно-FI-3-HY2", 300)]);
    expect(r.first.tag, "Окно-FI-3-HY2");
  });
}
