import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

/// Retries are owned by a single page operation, never by a gallery timer.
/// The initial attempt is followed by at most three delayed retries.
class ImageRetryPolicy {
  const ImageRetryPolicy({
    this.delays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
  });

  final List<Duration> delays;
  int get maxAttempts => delays.length + 1;

  bool canRetry(Object error, int failures) =>
      failures <= delays.length && isTransient(error);

  static bool isTransient(Object error) {
    if (error is DioException) {
      if (CancelToken.isCancel(error)) return false;
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          return true;
        case DioExceptionType.badResponse:
          return retryableStatus(error.response?.statusCode);
        default:
          return error.error != null && isTransient(error.error!);
      }
    }
    return error is HandshakeException ||
        error is SocketException ||
        error is TimeoutException ||
        error is HttpException;
  }

  static bool retryableStatus(int? status) =>
      const {403, 404, 408, 500, 502, 503, 504}.contains(status);

  Future<void> wait(int failures, CancelToken? token) async {
    token?.throwIfCancellationRequested();
    final delay = delays[failures - 1];
    if (token == null) {
      await Future<void>.delayed(delay);
    } else {
      final done = Completer<void>();
      final timer = Timer(delay, done.complete);
      token.whenCancel.then((error) {
        if (!done.isCompleted) done.completeError(error);
      });
      try {
        await done.future;
      } finally {
        timer.cancel();
      }
    }
    token?.throwIfCancellationRequested();
  }
}

extension ImageTransferCancellation on CancelToken {
  void throwIfCancellationRequested() {
    if (isCancelled) throw cancelError!;
  }
}
