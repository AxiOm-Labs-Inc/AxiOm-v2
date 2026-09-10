import 'dart:io';

import 'package:hiddify/utils/utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PreferencesMigration with InfraLogger {
  PreferencesMigration({required this.sharedPreferences});

  final SharedPreferences sharedPreferences;

  static const versionKey = "preferences_version";

  Future<void> migrate() async {
    final currentVersion = sharedPreferences.getInt(versionKey) ?? 0;

    final List<PreferencesMigrationStep> migrationSteps = [
      PreferencesVersion1Migration(sharedPreferences),
      PreferencesVersion2Migration(sharedPreferences),
      PreferencesVersion3Migration(sharedPreferences),
      PreferencesVersion4Migration(sharedPreferences),
      PreferencesVersion5Migration(sharedPreferences),
      PreferencesVersion6Migration(sharedPreferences),
      PreferencesVersion7Migration(sharedPreferences),
    ];

    if (currentVersion == migrationSteps.length) {
      loggy.debug("already using the latest version (v$currentVersion)");
      return;
    }

    final stopWatch = Stopwatch()..start();
    loggy.debug("migrating from v[$currentVersion] to v[${migrationSteps.length}]");
    for (int i = currentVersion; i < migrationSteps.length; i++) {
      loggy.debug("step [$i](v${i + 1})");
      await migrationSteps[i].migrate();
      await sharedPreferences.setInt(versionKey, i + 1);
    }
    stopWatch.stop();
    loggy.debug("migration took [${stopWatch.elapsedMilliseconds}]ms");
  }
}

abstract interface class PreferencesMigrationStep {
  PreferencesMigrationStep(this.sharedPreferences);

  final SharedPreferences sharedPreferences;

  Future<void> migrate();
}

class PreferencesVersion1Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion1Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    if (sharedPreferences.getString("service-mode") case final String serviceMode) {
      final newMode = switch (serviceMode) {
        "proxy" || "system-proxy" || "vpn" => serviceMode,
        "systemProxy" => "system-proxy",
        "tun" => "vpn",
        _ => PlatformUtils.isDesktop ? "system-proxy" : "vpn",
      };
      loggy.debug("changing service-mode from [$serviceMode] to [$newMode]");
      await sharedPreferences.setString("service-mode", newMode);
    }

    if (sharedPreferences.getString("ipv6-mode") case final String ipv6Mode) {
      loggy.debug("changing ipv6-mode from [$ipv6Mode] to [${_ipv6Mapper(ipv6Mode)}]");
      await sharedPreferences.setString("ipv6-mode", _ipv6Mapper(ipv6Mode));
    }

    if (sharedPreferences.getString("remote-domain-dns-strategy") case final String remoteDomainStrategy) {
      loggy.debug(
        "changing [remote-domain-dns-strategy] = [$remoteDomainStrategy] to [remote-dns-domain-strategy] = [${_domainStrategyMapper(remoteDomainStrategy)}]",
      );
      await sharedPreferences.remove("remote-domain-dns-strategy");
      await sharedPreferences.setString("remote-dns-domain-strategy", _domainStrategyMapper(remoteDomainStrategy));
    }

    if (sharedPreferences.getString("direct-domain-dns-strategy") case final String directDomainStrategy) {
      loggy.debug(
        "changing [direct-domain-dns-strategy] = [$directDomainStrategy] to [direct-dns-domain-strategy] = [${_domainStrategyMapper(directDomainStrategy)}]",
      );
      await sharedPreferences.remove("direct-domain-dns-strategy");
      await sharedPreferences.setString("direct-dns-domain-strategy", _domainStrategyMapper(directDomainStrategy));
    }

    if (sharedPreferences.getInt("localDns-port") case final int directPort) {
      loggy.debug("changing [localDns-port] to [direct-port]");
      await sharedPreferences.remove("localDns-port");
      await sharedPreferences.setInt("direct-port", directPort);
    }

    await sharedPreferences.remove("execute-config-as-is");
    await sharedPreferences.remove("enable-tun");
    await sharedPreferences.remove("set-system-proxy");

    await sharedPreferences.remove("cron_profiles_update");
  }

  String _ipv6Mapper(String persisted) => switch (persisted) {
    "ipv4_only" || "prefer_ipv4" || "prefer_ipv4" || "ipv6_only" => persisted,
    "disable" => "ipv4_only",
    "enable" => "prefer_ipv4",
    "prefer" => "prefer_ipv6",
    "only" => "ipv6_only",
    _ => "ipv4_only",
  };

  String _domainStrategyMapper(String persisted) => switch (persisted) {
    "ipv4_only" || "prefer_ipv4" || "prefer_ipv4" || "ipv6_only" => persisted,
    "auto" => "",
    "preferIpv6" => "prefer_ipv6",
    "preferIpv4" => "prefer_ipv4",
    "ipv4Only" => "ipv4_only",
    "ipv6Only" => "ipv6_only",
    _ => "",
  };
}

/// В регионе ru весь .ru/geoip:ru идёт мимо туннеля, а сохранённый direct-dns указывал на
/// Cloudflare по plain-UDP — его режет DPI, поэтому direct-домены не резолвились и страницы
/// (Яндекс в первую очередь) висели. Дефолт уже исправлен, но у установленных приложений в
/// SharedPreferences лежит старое значение, до которого новый дефолт не дотягивается.
class PreferencesVersion2Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion2Migration(super.sharedPreferences);

  /// Значения, которые мог проставить только прежний дефолт. Осознанно выбранный
  /// пользователем сервер не трогаем.
  static const _staleDefaults = {"udp://1.1.1.1", "1.1.1.1"};

  @override
  Future<void> migrate() async {
    // Ключа нет, если регион ни разу не меняли — тогда действует дефолт, а он ru.
    if ((sharedPreferences.getString("region") ?? "ru") != "ru") return;

    final directDns = sharedPreferences.getString("direct-dns-address");
    if (directDns == null || !_staleDefaults.contains(directDns)) return;

    loggy.debug("region=ru: changing [direct-dns-address] from [$directDns] to [udp://77.88.8.8]");
    await sharedPreferences.setString("direct-dns-address", "udp://77.88.8.8");
  }
}

/// Две правки 4.2.1, каждая — с тем же подвохом, что и в v2: дефолт до установленных
/// приложений не дотягивается, потому что настройки персистентны.
///
/// 1. `tun-implementation`: на `gvisor` не работает direct-выход. При region=ru ядро
///    отправляет `.ru` мимо туннеля, и в этом стеке такие соединения не покидают
///    устройство — страница висит до таймаута, запросы не доходят даже до сайта. Это и
///    ломало Яндекс, а следом Госуслуги. На `system` работает.
/// 2. `ipv6-mode`: у нод FR и NL нет глобального IPv6, соединения на IPv6-адреса рвутся
///    (сильнее всего страдает Telegram). Прежний дефолт `prefer_ipv4` IPv6 НЕ отключает.
class PreferencesVersion3Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion3Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    // Сбрасывается ЛЮБОЕ прежнее значение, включая выбранное пользователем вручную.
    // В отличие от v2 здесь это осознанно: `gvisor` и `mixed` ломают direct-выход, а
    // включённый IPv6 рвёт соединения через FR и NL, у которых нет глобального IPv6.
    // То есть «свой» выбор здесь означает сломанное соединение, а не другое поведение.
    // Настройки остаются в UI — вернуть их можно, но стартуют все с рабочих значений.
    final tun = sharedPreferences.getString("tun-implementation");
    if (tun != "system") {
      loggy.debug("changing [tun-implementation] from [$tun] to [system]");
      await sharedPreferences.setString("tun-implementation", "system");
    }

    final ipv6 = sharedPreferences.getString("ipv6-mode");
    if (ipv6 != "ipv4_only") {
      loggy.debug("changing [ipv6-mode] from [$ipv6] to [ipv4_only]");
      await sharedPreferences.setString("ipv6-mode", "ipv4_only");
    }
  }
}

/// Direct DNS: `udp://77.88.8.8` / Cloudflare при включённом VPN не резолвят .ru
/// (браузер: «Поиск login.procloud.ru…» → «Сервер не найден»; без VPN — ок).
/// Рабочий путь — `local` (системный DNS на underlying network). Дефолт уже
/// `local`, но у установленных приложений в prefs лежит старое значение.
class PreferencesVersion4Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion4Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    // Принудительно для всех: прежние udp://77.88.8.8 и udp://1.1.1.1 — сломанный
    // путь при VPN, а не осознанный «другой» выбор. UI настройку оставляет.
    final directDns = sharedPreferences.getString("direct-dns-address");
    if (directDns != "local") {
      loggy.debug("changing [direct-dns-address] from [$directDns] to [local]");
      await sharedPreferences.setString("direct-dns-address", "local");
    }
  }
}

/// `direct-dns-domain-strategy`: при `auto`/`prefer_ipv4` ядро всё равно шлёт AAAA
/// для direct-доменов (.ru при region=ru) на системный резолвер — на строгих сетях
/// (Wi-Fi с файрволом, РФ-резолверы) они висят по несколько секунд, страницы .ru
/// грузятся рывками. `ipv4_only` полностью убирает AAAA у direct-DNS. Дефолт уже
/// `ipv4_only`, но у установленных приложений в prefs лежит старое значение.
class PreferencesVersion5Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion5Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    // Принудительно для всех: `auto`/`prefer_ipv4`/`prefer_ipv6` для direct-DNS — это
    // AAAA-столл на строгих сетях, а не осознанный «другой» выбор. UI настройку оставляет.
    final strategy = sharedPreferences.getString("direct-dns-domain-strategy");
    if (strategy != "ipv4_only") {
      loggy.debug("changing [direct-dns-domain-strategy] from [$strategy] to [ipv4_only]");
      await sharedPreferences.setString("direct-dns-domain-strategy", "ipv4_only");
    }
  }
}

/// `service-mode` на Windows: системный прокси уважают не все программы — часть
/// браузеров ходит мимо него (свои настройки прокси, DoH), приложения со своим
/// сетевым стеком тем более. Симптом обманчивый: VPN «подключён», часть сайтов
/// работает, а конкретный сервис — нет (10.09.2026: Telegram Web не открывался ни
/// на одном сервере при полностью исправных транспортах). Режим `vpn` (TUN)
/// перехватывает трафик всех приложений и такого класса отказов не имеет.
///
/// Дефолт уже `vpn` (`ServiceMode.defaultMode`), но у установленных приложений в
/// prefs лежит `system-proxy` — либо от прежнего дефолта, либо от миграции v1.
/// Только Windows: TUN там поднимается тем же процессом, который при старте
/// сам запрашивает права администратора (`main.cpp`, `RelaunchElevated`; в
/// манифесте намеренно `asInvoker`). Linux и macOS не трогаем.
class PreferencesVersion6Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion6Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    if (!Platform.isWindows) return;

    // `proxy` (голый локальный порт) не трогаем: его выбирают осознанно, когда
    // прокси прописывают в конкретную программу руками. Перебиваем только
    // `system-proxy` — значение прежнего дефолта, то есть не выбор пользователя.
    final mode = sharedPreferences.getString("service-mode");
    if (mode == null || mode == "system-proxy") {
      loggy.debug("changing [service-mode] from [$mode] to [vpn]");
      await sharedPreferences.setString("service-mode", "vpn");
    }
  }
}

/// Локальные порты AxiOm совпадали с апстримом Hiddify — мы его форк, и дефолты
/// перешли дословно: `mixed-port` 12334, `tproxy` 12335, `redirect` 12336,
/// `direct` (DNS) 12337, управляющее API ядра 16756.
///
/// Если на устройстве стоят оба приложения, они делят одни и те же сокеты на
/// `127.0.0.1`, а на Android localhost общий для всех приложений вообще. Отсюда
/// то, что видел владелец: открываешь чужой Hiddify — он показывает «VPN
/// включён» и наш трафик, потому что читает управляющее API нашего ядра. Второй
/// эффект тише: кто стартовал позже, не может занять порт.
class PreferencesVersion7Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion7Migration(super.sharedPreferences);

  /// Только значения прежних дефолтов. Порт, выставленный руками, не трогаем:
  /// его меняли осознанно, и вслепую перебить его — значит сломать чью-то
  /// рабочую связку с другим софтом на этом порту.
  static const _moves = {
    "mixed-port": (12334, 23334),
    "tproxy-port": (12335, 23335),
    "redirect-port": (12336, 23336),
    "direct-port": (12337, 23337),
    "clash-api-port": (16756, 23756),
  };

  @override
  Future<void> migrate() async {
    for (final entry in _moves.entries) {
      final (oldDefault, newDefault) = entry.value;
      final current = sharedPreferences.getInt(entry.key);
      // Ключа нет — действует новый дефолт, писать ничего не нужно.
      if (current == null || current != oldDefault) continue;
      loggy.debug("changing [${entry.key}] from [$current] to [$newDefault]");
      await sharedPreferences.setInt(entry.key, newDefault);
    }
  }
}
