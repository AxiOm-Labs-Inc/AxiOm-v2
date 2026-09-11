import 'package:fpdart/fpdart.dart';
import 'package:axiom/core/utils/exception_handler.dart';
import 'package:axiom/features/stats/model/stats_failure.dart';
import 'package:axiom/axiomcore/generated/v2/hcore/hcore.pb.dart';
import 'package:axiom/axiomcore/axiom_core_service.dart';
import 'package:axiom/utils/custom_loggers.dart';

abstract interface class StatsRepository {
  Stream<Either<StatsFailure, SystemInfo>> watchStats();
}

class StatsRepositoryImpl with ExceptionHandler, InfraLogger implements StatsRepository {
  StatsRepositoryImpl({required this.singbox});

  final AxiomCoreService singbox;

  @override
  Stream<Either<StatsFailure, SystemInfo>> watchStats() {
    return singbox.watchStats().handleExceptions(StatsUnexpectedFailure.new);
  }
}
