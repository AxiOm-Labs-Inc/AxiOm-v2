import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/widget/axiom_branding.dart';
import 'package:hiddify/features/account/widget/account_section.dart';
import 'package:hiddify/features/profile/notifier/profiles_update_notifier.dart';
import 'package:hiddify/features/profile/overview/profiles_notifier.dart';
import 'package:hiddify/features/profile/widget/profile_tile.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProfilesPage extends HookConsumerWidget {
  const ProfilesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final asyncProfiles = ref.watch(profilesNotifierProvider);

    ref.listen(profilesNotifierProvider, (_, next) {
      if (next.hasValue && next.value!.isEmpty) {
        context.goNamed('home');
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: AxiOmSectionTitle(title: t.pages.profiles.title),
        actions: [
          IconButton(
            onPressed: () => ref.read(foregroundProfilesUpdateNotifierProvider.notifier).trigger(),
            icon: const Icon(Icons.update_rounded),
            tooltip: t.pages.profiles.updateSubscriptions,
          ),
          IconButton(
            onPressed: () => ref.read(dialogNotifierProvider.notifier).showSortProfiles(),
            icon: const Icon(Icons.sort_rounded),
            tooltip: t.common.sort,
          ),
          const Gap(8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async => await ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),
        label: Text(t.pages.profiles.add),
        icon: const Icon(Icons.add_rounded),
      ),
      body: asyncProfiles.when(
        data: (profiles) => ListView.builder(
          padding: const EdgeInsets.all(12).copyWith(bottom: 84),
          itemCount: profiles.length + 1, // +1 for account section
          itemBuilder: (context, index) {
            if (index == 0) {
              return const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: AccountSection(),
              );
            }
            final profile = profiles[index - 1];
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ProfileTile(profile: profile),
            );
          },
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(child: Text(t.presentShortError(error))),
      ),
    );
  }
}
