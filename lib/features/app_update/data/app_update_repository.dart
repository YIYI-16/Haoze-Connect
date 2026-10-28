import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/utils/exception_handler.dart';
import 'package:hiddify/features/app_update/data/github_release_parser.dart';
import 'package:hiddify/features/app_update/model/app_update_failure.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/utils/utils.dart';

abstract interface class AppUpdateRepository {
  TaskEither<AppUpdateFailure, RemoteVersionEntity> getLatestVersion({
    bool includePreReleases = false,
    Release release = Release.general,
  });
}

class AppUpdateRepositoryImpl
    with ExceptionHandler, InfraLogger
    implements AppUpdateRepository {
  AppUpdateRepositoryImpl({required this.httpClient});

  final DioHttpClient httpClient;

  @override
  TaskEither<AppUpdateFailure, RemoteVersionEntity> getLatestVersion({
    bool includePreReleases = false,
    Release release = Release.general,
  }) {
    return exceptionHandler(() async {
      if (!Constants.hasUpdateChannel) {
        throw Exception(
          "no update channel configured (XBOARD_UPDATE_URL not set)",
        );
      }
      final apiUrl = _releasesApiUrl();
      if (apiUrl == null) {
        throw Exception(
          "XBOARD_UPDATE_URL manual check only supports GitHub repository URLs",
        );
      }
      if (!release.allowCustomUpdateChecker) {
        throw Exception("custom update checkers are not supported");
      }
      final response = await httpClient.get<List>(apiUrl);
      if (response.statusCode != 200 || response.data == null) {
        loggy.warning("failed to fetch latest version info");
        return left(const AppUpdateFailure.unexpected());
      }

      final releases = response.data!.map(
        (e) => GithubReleaseParser.parse(e as Map<String, dynamic>),
      );
      late RemoteVersionEntity latest;
      if (includePreReleases) {
        latest = releases.first;
      } else {
        latest = releases.firstWhere((e) => e.preRelease == false);
      }
      return right(latest);
    }, AppUpdateFailure.unexpected);
  }

  /// Derives the GitHub releases API endpoint from the configured
  /// [Constants.xboardUpdateUrl]. Returns `null` when the configured URL is not
  /// a GitHub repository URL (e.g. an appcast feed, which the automatic
  /// upgrader consumes directly). Only the maintainer-configured repository is
  /// ever queried — never upstream Hiddify endpoints.
  String? _releasesApiUrl() {
    final uri = Uri.tryParse(Constants.xboardUpdateUrl);
    if (uri == null || uri.host != 'github.com') return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) return null;
    final owner = segments[0];
    final repo = segments[1].endsWith('.git')
        ? segments[1].substring(0, segments[1].length - 4)
        : segments[1];
    return "https://api.github.com/repos/$owner/$repo/releases";
  }
}
