import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/proxy/data/server_list_cache.dart';
import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/features/proxy/model/server_option.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ServerSelectorCard extends HookConsumerWidget {
  const ServerSelectorCard({super.key, this.expanded = false});

  /// When true, uses more vertical padding (full proxies route).
  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    final proxies = ref.watch(proxiesOverviewNotifierProvider);
    final prefs = ref.watch(sharedPreferencesProvider).requireValue;

    // When the service is not running, fall back to the server list cached
    // from the last connected session so a server can be picked offline.
    Widget offlineOrMessage() {
      final cached = readCachedServerOptions(prefs);
      if (cached.isNotEmpty) {
        return _ServerSelectorBody(
          options: cached,
          groupTag: null,
          selectedRawTag: null,
          live: false,
          expanded: expanded,
        );
      }
      return _SelectorShell(
        child: Text(
          'Подключитесь, чтобы выбрать сервер',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: expanded ? 16 : 8),
      child: proxies.when(
        data: (group) {
          if (group == null) {
            return _SelectorShell(
              child: Text(
                t.pages.proxies.empty,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }
          return _ServerSelectorBody(
            options: ServerOption.parse(group),
            groupTag: group.tag,
            selectedRawTag: group.selected,
            live: true,
            expanded: expanded,
          );
        },
        loading: () => const _SelectorShell(
          child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
        ),
        error: (error, _) => error is ServiceNotRunning
            ? offlineOrMessage()
            : _SelectorShell(
                child: Text(
                  t.presentShortError(error),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
      ),
    );
  }
}

class _SelectorShell extends StatelessWidget {
  const _SelectorShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: .3)),
      ),
      child: child,
    );
  }
}

class _ServerSelectorBody extends HookConsumerWidget {
  const _ServerSelectorBody({
    required this.options,
    required this.groupTag,
    required this.selectedRawTag,
    required this.live,
    required this.expanded,
  });

  /// Parsed server options — from the live core when [live], otherwise cached.
  final List<ServerOption> options;

  /// Live group tag / current selection (null when offline).
  final String? groupTag;
  final String? selectedRawTag;

  /// Whether a running core backs this selector (enables ping + applying).
  final bool live;
  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    const accent = Color(0xFF5DCAA5);
    final warpEnabled = ref.watch(ConfigOptions.enableWarp);

    final itemsSignature = options.map((o) => '${o.rawTag}:${o.delay}').join('|');
    final countryList = useMemoized(
      () => ServerOption.countries(options).toList()..sort((a, b) => a.compareTo(b)),
      [itemsSignature],
    );
    final fastestOption = useMemoized(() => ServerOption.fastest(options), [itemsSignature]);

    final prefs = ref.watch(sharedPreferencesProvider).requireValue;
    final countryPref = useMemoized(
      () => PreferencesEntry<String, String>(
        preferences: prefs,
        key: 'server_selector_country',
        defaultValue: ServerOption.autoCountryKey,
      ),
    );
    final protocolPref = useMemoized(
      () => PreferencesEntry<String, String>(
        preferences: prefs,
        key: 'server_selector_protocol',
        defaultValue: '',
      ),
    );
    final transportPref = useMemoized(
      () => PreferencesEntry<String, String>(
        preferences: prefs,
        key: 'server_selector_transport',
        defaultValue: '',
      ),
    );

    // Restore the previously selected server instead of defaulting to auto.
    final selectedCountry = useState<String?>(countryPref.read());
    final selectedProtocol = useState<String?>(
      protocolPref.read().isEmpty ? null : protocolPref.read(),
    );
    final selectedTransport = useState<String?>(
      transportPref.read().isEmpty ? null : transportPref.read(),
    );

    // Cache the live server list so it can be shown/selected before connecting.
    useEffect(() {
      if (live && options.isNotEmpty) {
        writeCachedServerOptions(prefs, options);
      }
      return null;
    }, [itemsSignature, live]);

    // Enforce the remembered (non-auto) selection so the core does not silently
    // fall back to another server on reconnect/restart.
    useEffect(() {
      if (options.isEmpty || selectedCountry.value == ServerOption.autoCountryKey) return null;
      final c = selectedCountry.value;
      if (c == null) return null;
      final protocols = ServerOption.protocolsFor(options, c);
      if (protocols.isEmpty) {
        // Remembered country is no longer available — fall back to auto.
        selectedCountry.value = ServerOption.autoCountryKey;
        countryPref.write(ServerOption.autoCountryKey);
        return null;
      }
      final p = protocols.contains(selectedProtocol.value) ? selectedProtocol.value! : protocols.first;
      if (selectedProtocol.value != p) {
        selectedProtocol.value = p;
        protocolPref.write(p);
      }
      final available = ServerOption.transportsFor(options, c, p);
      if (available.isEmpty) return null;
      final tr = available.contains(selectedTransport.value) ? selectedTransport.value! : available.first;
      if (selectedTransport.value != tr) {
        selectedTransport.value = tr;
        transportPref.write(tr);
      }
      final option = ServerOption.find(options, c, p, tr);
      if (live && option != null && selectedRawTag != option.rawTag) {
        Future.microtask(
          () => ref.read(proxiesOverviewNotifierProvider.notifier).changeProxy(groupTag!, option.rawTag),
        );
      }
      return null;
    }, [itemsSignature, selectedCountry.value, selectedProtocol.value, selectedTransport.value]);

    // Auto-mode: trigger a single url-test when no usable delays are available
    // yet. Guarded so it does not re-fire on every delay update, which would
    // loop endlessly when all servers are unreachable.
    final autoTested = useRef(false);
    useEffect(() {
      if (!live || options.isEmpty || selectedCountry.value != ServerOption.autoCountryKey) {
        autoTested.value = false;
        return null;
      }
      if (ServerOption.fastest(options) != null) return null;
      if (autoTested.value) return null;
      autoTested.value = true;

      Future.microtask(
        () => ref.read(proxiesOverviewNotifierProvider.notifier).urlTest(groupTag!),
      );
      return null;
    }, [itemsSignature, selectedCountry.value]);

    useEffect(() {
      if (!live || options.isEmpty || selectedCountry.value != ServerOption.autoCountryKey) return null;

      Future.microtask(() async {
        final best = ServerOption.fastest(options);
        if (best == null) return;
        selectedProtocol.value = best.protocol;
        selectedTransport.value = best.transport;
        if (selectedRawTag != best.rawTag) {
          await ref.read(proxiesOverviewNotifierProvider.notifier).changeProxy(groupTag!, best.rawTag);
        }
      });
      return null;
    }, [itemsSignature, selectedCountry.value]);

    final isAuto = selectedCountry.value == ServerOption.autoCountryKey;
    final country = isAuto ? fastestOption?.country : selectedCountry.value;
    final protocol = isAuto ? fastestOption?.protocol : selectedProtocol.value;
    final transport = isAuto ? fastestOption?.transport : selectedTransport.value;
    final protocols = !isAuto && country != null ? ServerOption.protocolsFor(options, country) : <String>[];
    final transports = !isAuto && country != null && protocol != null
        ? ServerOption.transportsFor(options, country, protocol)
        : <String>[];

    Future<void> applySelection(String? newCountry, String? newProtocol, String? newTransport) async {
      if (!live || newCountry == null || newProtocol == null || newTransport == null) return;
      final option = ServerOption.find(options, newCountry, newProtocol, newTransport);
      if (option == null) return;
      if (selectedRawTag == option.rawTag) return;
      await ref.read(proxiesOverviewNotifierProvider.notifier).changeProxy(groupTag!, option.rawTag);
    }

    String formatDelay(int? delay) {
      if (delay == null || delay <= 0 || delay >= 65000) return '—';
      return '$delayмс';
    }

    Widget buildCountryDropdown(WidgetRef ref) {
      final dropdownValue = isAuto
          ? ServerOption.autoCountryKey
          : (country != null && countryList.contains(country) ? country : null);

      return DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          hint: Text(
            'Выберите страну',
            style: theme.textTheme.bodyMedium,
          ),
          value: dropdownValue,
          onTap: live ? () => ref.read(proxiesOverviewNotifierProvider.notifier).urlTest(groupTag!) : null,
          items: [
            DropdownMenuItem(
              value: ServerOption.autoCountryKey,
              child: Row(
                children: [
                  Icon(Icons.bolt_rounded, size: 18, color: accent),
                  const Gap(8),
                  Expanded(
                    child: Text(
                      '${t.common.auto} (самый быстрый)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    formatDelay(fastestOption?.delay),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: fastestOption != null && fastestOption!.delay < 300
                          ? accent
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            ...countryList.map((c) {
              final delay = ServerOption.bestDelayForCountry(options, c);
              return DropdownMenuItem(
                value: c,
                child: Row(
                  children: [
                    Text(ServerOption.countryFlagEmoji(c), style: const TextStyle(fontSize: 18)),
                    const Gap(8),
                    Expanded(child: Text(c, overflow: TextOverflow.ellipsis)),
                    Text(
                      formatDelay(delay),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: delay != null && delay < 300 ? accent : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
          onChanged: countryList.isEmpty && fastestOption == null
              ? null
              : (value) async {
                  if (value == null) return;
                  if (value == ServerOption.autoCountryKey) {
                    selectedCountry.value = ServerOption.autoCountryKey;
                    await countryPref.write(ServerOption.autoCountryKey);
                    final best = ServerOption.fastest(options);
                    if (best == null) return;
                    selectedProtocol.value = best.protocol;
                    selectedTransport.value = best.transport;
                    await applySelection(best.country, best.protocol, best.transport);
                    return;
                  }
                  selectedCountry.value = value;
                  final nextProtocols = ServerOption.protocolsFor(options, value);
                  final nextProtocol = nextProtocols.contains(selectedProtocol.value)
                      ? selectedProtocol.value!
                      : nextProtocols.first;
                  selectedProtocol.value = nextProtocol;
                  final nextTransports = ServerOption.transportsFor(options, value, nextProtocol);
                  final nextTransport = nextTransports.contains(selectedTransport.value)
                      ? selectedTransport.value!
                      : nextTransports.first;
                  selectedTransport.value = nextTransport;
                  await countryPref.write(value);
                  await protocolPref.write(nextProtocol);
                  await transportPref.write(nextTransport);
                  await applySelection(value, nextProtocol, nextTransport);
                },
        ),
      );
    }

    Widget labelRow(String label, String value) {
      return Row(
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Gap(12),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    Widget buildProtocolRow(WidgetRef ref) {
      if (isAuto) {
        if (fastestOption == null) return const SizedBox.shrink();
        return labelRow(
          'Протокол',
          '${ServerOption.countryFlagEmoji(fastestOption!.country)} ${fastestOption!.country} · ${ServerOption.protocolLabel(fastestOption!.protocol)}',
        );
      }

      if (country == null || protocols.isEmpty) return const SizedBox.shrink();

      if (protocols.length == 1) {
        return labelRow('Протокол', ServerOption.protocolLabel(protocols.first));
      }

      return Row(
        children: [
          Text(
            'Протокол',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Gap(8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: protocol != null && protocols.contains(protocol) ? protocol : protocols.first,
                onTap: live ? () => ref.read(proxiesOverviewNotifierProvider.notifier).urlTest(groupTag!) : null,
                items: protocols.map((p) {
                  final delay = ServerOption.bestDelayForProtocol(options, country, p);
                  return DropdownMenuItem(
                    value: p,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            ServerOption.protocolLabel(p),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          formatDelay(delay),
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (value) async {
                  if (value == null) return;
                  selectedProtocol.value = value;
                  final nextTransports = ServerOption.transportsFor(options, country, value);
                  final nextTransport = nextTransports.contains(selectedTransport.value)
                      ? selectedTransport.value!
                      : nextTransports.first;
                  selectedTransport.value = nextTransport;
                  await protocolPref.write(value);
                  await transportPref.write(nextTransport);
                  await applySelection(country, value, nextTransport);
                },
              ),
            ),
          ),
        ],
      );
    }

    Widget buildTransportRow(WidgetRef ref) {
      // Hysteria2 (QUIC) and Naive (HTTP/2) each have a single transport — hide the row.
      if (protocol == ServerOption.protocolHysteria2 || protocol == ServerOption.protocolNaive) {
        return const SizedBox.shrink();
      }

      if (isAuto) {
        if (fastestOption == null ||
            fastestOption!.protocol == ServerOption.protocolHysteria2 ||
            fastestOption!.protocol == ServerOption.protocolNaive) {
          return const SizedBox.shrink();
        }
        return labelRow('Транспорт', ServerOption.transportLabel(fastestOption!.transport));
      }

      if (country == null || protocol == null || transports.isEmpty) {
        return const SizedBox.shrink();
      }

      if (transports.length == 1) {
        return labelRow('Транспорт', ServerOption.transportLabel(transports.first));
      }

      return Row(
        children: [
          Text(
            'Транспорт',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Gap(8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: transport != null && transports.contains(transport) ? transport : transports.first,
                onTap: live ? () => ref.read(proxiesOverviewNotifierProvider.notifier).urlTest(groupTag!) : null,
                items: transports.map((tr) {
                  final delay = ServerOption.find(options, country, protocol, tr)?.delay;
                  return DropdownMenuItem(
                    value: tr,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            ServerOption.transportLabel(tr),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          formatDelay(delay != null && delay > 0 && delay < 65000 ? delay : null),
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (value) async {
                  if (value == null) return;
                  selectedTransport.value = value;
                  await transportPref.write(value);
                  await applySelection(country, protocol, value);
                },
              ),
            ),
          ),
        ],
      );
    }

    final selectedDelay = isAuto
        ? fastestOption?.delay
        : (country != null && protocol != null && transport != null
            ? ServerOption.find(options, country, protocol, transport)?.delay
            : null);

    return _SelectorShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (warpEnabled) ...[
            Row(
              children: [
                Icon(Icons.shield_rounded, size: 14, color: accent),
                const Gap(6),
                Expanded(
                  child: Text(
                    'Дополнительное шифрование WARP',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const Gap(10),
          ],
          Row(
            children: [
              Text(
                'Сервер',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (live)
                IconButton(
                  tooltip: 'Обновить пинг',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: () => ref.read(proxiesOverviewNotifierProvider.notifier).urlTest(groupTag!),
                  icon: Icon(Icons.refresh_rounded, size: 20, color: theme.colorScheme.primary),
                ),
            ],
          ),
          const Gap(8),
          Text(
            'Страна',
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const Gap(4),
          buildCountryDropdown(ref),
          const Gap(10),
          buildProtocolRow(ref),
          const Gap(10),
          buildTransportRow(ref),
          if (!live) ...[
            const Gap(8),
            Text(
              'Пинг — после подключения',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ] else if ((country != null && transport != null) || (isAuto && fastestOption != null)) ...[
            const Gap(8),
            Text(
              'Пинг: ${formatDelay(selectedDelay != null && selectedDelay > 0 && selectedDelay < 65000 ? selectedDelay : null)}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
