import 'package:axiom/core/db/provider/db_providers.dart';
import 'package:axiom/core/directories/directories_provider.dart';
import 'package:axiom/core/http_client/http_client_provider.dart';
import 'package:axiom/features/profile/data/profile_data_source.dart';
import 'package:axiom/features/profile/data/profile_parser.dart';
import 'package:axiom/features/profile/data/profile_path_resolver.dart';
import 'package:axiom/features/profile/data/profile_repository.dart';
import 'package:axiom/features/settings/data/config_option_data_providers.dart';
import 'package:axiom/axiomcore/axiom_core_service_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'profile_data_providers.g.dart';

@Riverpod(keepAlive: true)
Future<ProfileRepository> profileRepository(Ref ref) async {
  final repo = ProfileRepositoryImpl(
    profileDataSource: ref.watch(profileDataSourceProvider),
    profilePathResolver: ref.watch(profilePathResolverProvider),
    singbox: ref.watch(axiomCoreServiceProvider),
    configOptionRepository: ref.watch(configOptionRepositoryProvider),
    profileParser: ref.watch(profileParserProvider),
  );
  await repo.init().getOrElse((l) => throw l).run();
  return repo;
}

@Riverpod(keepAlive: true)
ProfileDataSource profileDataSource(Ref ref) {
  return ProfileDao(ref.watch(dbProvider));
}

@Riverpod(keepAlive: true)
ProfilePathResolver profilePathResolver(Ref ref) {
  return ProfilePathResolver(ref.watch(appDirectoriesProvider).requireValue.workingDir);
}

@Riverpod(keepAlive: true)
ProfileParser profileParser(Ref ref) {
  return ProfileParser(ref: ref, httpClient: ref.watch(httpClientProvider));
}
