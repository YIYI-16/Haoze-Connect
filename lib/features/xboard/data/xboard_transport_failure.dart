import 'dart:io';

import 'package:dio/dio.dart';

/// Safe transport diagnostics: values contain no request or account details.
enum XboardTransportFailure {
  certificateRejected,
  tlsHandshake,
  tlsProtocol,
  tlsInterrupted,
  connectionInterrupted,
  connection,
  timeout,
  cancelled,
  unknown;

  bool get canRetryGet => this == tlsInterrupted || this == connectionInterrupted;
}

/// An allowlist of diagnostic fields. Never stringify the exception itself.
class XboardTransportDiagnostic {
  XboardTransportDiagnostic(DioException error, {required this.attempt})
    : failure = classifyXboardTransportFailure(error),
      dioType = error.type,
      causeType = error.error.runtimeType.toString(),
      osErrorCode = switch (error.error) {
        final TlsException cause => cause.osError?.errorCode,
        final SocketException cause => cause.osError?.errorCode,
        _ => null,
      };

  final XboardTransportFailure failure;
  final DioExceptionType dioType;
  final String causeType;
  final int? osErrorCode;
  final int attempt;

  @override
  String toString() =>
      'xboard transport: category=${failure.name} attempt=$attempt '
      'dio=${dioType.name} cause=$causeType osErrorCode=$osErrorCode';
}

XboardTransportFailure classifyXboardTransportFailure(DioException error) {
  final cause = error.error;
  // Dart reports chain/hostname/expiry validation failures through BoringSSL's
  // verification marker, often inside HandshakeException rather than Dio's
  // badCertificate type. A generic HandshakeException does not prove rejection.
  if (error.type == DioExceptionType.badCertificate ||
      cause is CertificateException ||
      (cause is TlsException &&
          '${cause.message} ${cause.osError?.message ?? ''}'.contains('CERTIFICATE_VERIFY_FAILED'))) {
    return XboardTransportFailure.certificateRejected;
  }
  switch (error.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return XboardTransportFailure.timeout;
    case DioExceptionType.cancel:
      return XboardTransportFailure.cancelled;
    default:
      break;
  }

  if (cause is TlsException) {
    // The first message is emitted by Dart when the peer closes the connection
    // during negotiation. Do not retry arbitrary protocol or verification errors.
    if (cause.message.contains('Connection terminated during handshake') || _isInterrupted(cause.osError)) {
      return XboardTransportFailure.tlsInterrupted;
    }
    return cause is HandshakeException ? XboardTransportFailure.tlsHandshake : XboardTransportFailure.tlsProtocol;
  }
  if ((cause is SocketException && _isInterrupted(cause.osError)) ||
      (cause is HttpException && cause.message.contains('Connection closed before full header was received'))) {
    return XboardTransportFailure.connectionInterrupted;
  }
  if (cause is SocketException || error.type == DioExceptionType.connectionError) {
    return XboardTransportFailure.connection;
  }
  return XboardTransportFailure.unknown;
}

bool _isInterrupted(OSError? error) {
  // ECONNRESET, ECONNABORTED and EPIPE on Linux/Android, macOS and Windows.
  return const {32, 53, 54, 103, 104, 10053, 10054}.contains(error?.errorCode);
}
