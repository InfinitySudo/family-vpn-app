import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

/// Справочник стран для экрана «Страна подключения».
///
/// Зачем нужна СТАБИЛЬНАЯ страна: ChatGPT, Claude, Gemini и прочие AI-сервисы
/// смотрят на страну IP-адреса. Если адрес «прыгает» между странами или попадает
/// в неподдерживаемую — сервис выкидывает из аккаунта или пишет «недоступно в
/// вашем регионе». Поэтому пользователь выбирает страну один раз, выбор
/// сохраняется и применяется при каждом подключении.
class OknoCountry {
  const OknoCountry({
    required this.code,
    required this.name,
    required this.city,
    required this.landmark,
    this.aiFriendly = true,
  });

  /// ISO 3166-1 alpha-2, верхним регистром.
  final String code;
  final String name;
  /// Город, где стоят серверы (показывается под названием страны).
  final String city;
  /// Подпись достопримечательности на картинке (assets/landmarks/<cc>.jpg).
  final String landmark;
  /// Доступны ли из этой страны ChatGPT и другие AI-сервисы.
  final bool aiFriendly;

  String get assetPath => "assets/landmarks/${code.toLowerCase()}.jpg";

  /// Флаг-эмодзи из кода страны (региональные индикаторы).
  String get flagEmoji => String.fromCharCodes(code.toUpperCase().codeUnits.map((c) => 0x1F1E6 + c - 0x41));

  static const List<OknoCountry> known = [
    OknoCountry(code: "LV", name: "Латвия", city: "Рига", landmark: "Дом Черноголовых, Рига"),
    OknoCountry(code: "EE", name: "Эстония", city: "Таллин", landmark: "Старый город, Таллин"),
    OknoCountry(code: "LT", name: "Литва", city: "Вильнюс", landmark: "Башня Гедимина, Вильнюс"),
    OknoCountry(code: "FI", name: "Финляндия", city: "Хельсинки", landmark: "Кафедральный собор, Хельсинки"),
    OknoCountry(code: "SE", name: "Швеция", city: "Стокгольм", landmark: "Гамла стан, Стокгольм"),
    OknoCountry(code: "NL", name: "Нидерланды", city: "Амстердам", landmark: "Каналы Амстердама"),
    OknoCountry(code: "DE", name: "Германия", city: "Берлин", landmark: "Бранденбургские ворота, Берлин"),
    OknoCountry(code: "PL", name: "Польша", city: "Варшава", landmark: "Рыночная площадь, Варшава"),
    OknoCountry(code: "CZ", name: "Чехия", city: "Прага", landmark: "Карлов мост, Прага"),
    OknoCountry(code: "AT", name: "Австрия", city: "Вена", landmark: "Дворец Шёнбрунн, Вена"),
    OknoCountry(code: "CH", name: "Швейцария", city: "Цюрих", landmark: "Старый город, Цюрих"),
    OknoCountry(code: "FR", name: "Франция", city: "Париж", landmark: "Эйфелева башня, Париж"),
    OknoCountry(code: "GB", name: "Великобритания", city: "Лондон", landmark: "Биг-Бен, Лондон"),
    OknoCountry(code: "US", name: "США", city: "Нью-Йорк", landmark: "Статуя Свободы, Нью-Йорк"),
    OknoCountry(code: "TR", name: "Турция", city: "Стамбул", landmark: "Айя-София, Стамбул"),
    OknoCountry(code: "KZ", name: "Казахстан", city: "Астана", landmark: "Центр Астаны"),
    // страны, откуда AI-сервисы НЕ работают — на случай если такой сервер появится
    OknoCountry(code: "RU", name: "Россия", city: "", landmark: "", aiFriendly: false),
    OknoCountry(code: "BY", name: "Беларусь", city: "", landmark: "", aiFriendly: false),
    OknoCountry(code: "CN", name: "Китай", city: "", landmark: "", aiFriendly: false),
    OknoCountry(code: "IR", name: "Иран", city: "", landmark: "", aiFriendly: false),
  ];

  static OknoCountry byCode(String code) {
    final c = code.toUpperCase();
    for (final k in known) {
      if (k.code == c) return k;
    }
    // Неизвестная страна: флаг нарисуется по коду, название — сам код.
    return OknoCountry(code: c, name: c, city: "", landmark: "", aiFriendly: false);
  }

  /// Есть ли у страны картинка достопримечательности в ассетах.
  bool get hasLandmark => landmark.isNotEmpty;
}

/// Тег узла подписки: «Окно-LV-1-Reality» (новый агрегатор, со страной)
/// или «Окно-1-Reality» (старый, без страны — весь первый флот стоит в Риге).
final RegExp _tagWithCountry = RegExp(r"^Окно-([A-Za-z]{2})-(\d+)-(.+)$");
final RegExp _tagLegacy = RegExp(r"^Окно-(\d+)-(.+)$");

/// Код страны узла: из тега, иначе из гео-инфо ядра, иначе Рига (LV) для старых
/// тегов «Окно-N-…». Пустая строка — страна неизвестна.
String countryCodeOfTag(String tag, {String coreCountryCode = ""}) {
  final m = _tagWithCountry.firstMatch(tag);
  if (m != null) return m.group(1)!.toUpperCase();
  if (coreCountryCode.isNotEmpty) return coreCountryCode.toUpperCase();
  if (_tagLegacy.hasMatch(tag)) return "LV";
  return "";
}

String countryCodeOfOutbound(OutboundInfo o) => countryCodeOfTag(o.tag, coreCountryCode: o.ipinfo.countryCode);

/// Человеческое имя узла для списка: «Сервер 1 · Reality».
String serverLabelOfTag(String tag) {
  final m = _tagWithCountry.firstMatch(tag);
  if (m != null) return "Сервер ${m.group(2)} · ${m.group(3)}";
  final l = _tagLegacy.firstMatch(tag);
  if (l != null) return "Сервер ${l.group(1)} · ${l.group(2)}";
  return tag;
}

/// Значение задержки, которое ядро отдаёт при таймауте.
const int oknoDelayTimeout = 65000;

bool isDelayTimeout(int d) => d >= oknoDelayTimeout;
bool isDelayKnown(int d) => d > 0;
