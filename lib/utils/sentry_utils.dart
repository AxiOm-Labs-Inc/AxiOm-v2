import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:axiom/core/model/failures.dart';
import 'package:axiom/features/proxy/model/proxy_failure.dart';

// Sentry analytics removed in AxiOm. These helpers are retained for compilation compatibility.

bool canSendEvent(dynamic throwable) {
  return switch (throwable) {
    UnexpectedFailure(:final error) => canSendEvent(error),
    DioException _ => false,
    SocketException _ => false,
    UnknownIp _ => false,
    HttpException _ => false,
    HandshakeException _ => false,
    ExpectedFailure _ => false,
    ExpectedMeasuredFailure _ => false,
    _ => true,
  };
}

bool canLogEvent(dynamic throwable) => switch (throwable) {
  ExpectedMeasuredFailure _ => true,
  _ => canSendEvent(throwable),
};
