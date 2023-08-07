import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/command.dart';
import 'package:shorebird_cli/src/logger.dart';

mixin ShorebirdArtifactMixin on ShorebirdCommand {
  String aarArtifactDirectory({
    required String packageName,
    required String buildNumber,
  }) =>
      p.joinAll([
        Directory.current.path,
        'build',
        'host',
        'outputs',
        'repo',
        ...packageName.split('.'),
        'flutter_release',
        buildNumber,
      ]);

  String aarArtifactPath({
    required String packageName,
    required String buildNumber,
  }) =>
      p.join(
        aarArtifactDirectory(
          packageName: packageName,
          buildNumber: buildNumber,
        ),
        'flutter_release-$buildNumber.aar',
      );

  Future<String> extractAar({
    required String packageName,
    required String buildNumber,
    required UnzipFn unzipFn,
  }) async {
    final aarDirectory = aarArtifactDirectory(
      packageName: packageName,
      buildNumber: buildNumber,
    );
    final aarPath = aarArtifactPath(
      packageName: packageName,
      buildNumber: buildNumber,
    );

    final zipDir = Directory.systemTemp.createTempSync();
    final zipPath = p.join(zipDir.path, 'flutter_release-$buildNumber.zip');
    logger.detail('Extracting $aarPath to $zipPath');

    // Copy the .aar file to a .zip file so package:archive knows how to read it
    File(aarPath).copySync(zipPath);
    final extractedZipDir = p.join(
      aarDirectory,
      'flutter_release-$buildNumber',
    );
    // Unzip the .zip file to a directory so we can read the .so files
    await unzipFn(zipPath, extractedZipDir);
    return extractedZipDir;
  }

  /// Returns the path to the .ipa file generated by `flutter build ipa`. Throws
  /// an exception if there is not exactly one .ipa file in the build directory,
  /// or if there is no build directory.
  String getIpaPath() {
    final ipaBuildDirectory = Directory(
      p.join(
        Directory.current.path,
        'build',
        'ios',
        'ipa',
      ),
    );

    if (!ipaBuildDirectory.existsSync()) {
      throw Exception('No directory found at ${ipaBuildDirectory.path}');
    }

    final ipaFiles = ipaBuildDirectory
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => p.extension(f.path) == '.ipa');

    if (ipaFiles.isEmpty) {
      throw Exception('No .ipa files found in ${ipaBuildDirectory.path}');
    }

    if (ipaFiles.length > 1) {
      throw Exception(
        'More than one .ipa file found in ${ipaBuildDirectory.path}',
      );
    }

    return ipaFiles.single.path;
  }

  static const String appXcframeworkName = 'App.xcframework';

  /// Returns the path to the App.xcframework generated by
  /// `shorebird release ios-framework-alpha` or
  /// `shorebird patch ios-framework-alpha`.
  String getAppXcframeworkPath() {
    return p.join(getAppXcframeworkDirectory().path, appXcframeworkName);
  }

  /// Returns the [Directory] containing the App.xcframework generated by
  /// `shorebird release ios-framework-alpha` or
  /// `shorebird patch ios-framework-alpha`.
  Directory getAppXcframeworkDirectory() => Directory(
        p.join(
          Directory.current.path,
          'build',
          'ios',
          'framework',
          'Release',
        ),
      );

  /// Finds the most recently-edited app.dill file in the .dart_tool directory.
  // TODO(bryanoltman): This is an enormous hack – we don't know that this is
  // the correct file.
  File newestAppDill() {
    final dartToolBuildDir = Directory(
      p.join(
        Directory.current.path,
        '.dart_tool',
        'flutter_build',
      ),
    );

    return dartToolBuildDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => p.basename(f.path) == 'app.dill')
        .reduce(
          (a, b) =>
              a.statSync().modified.isAfter(b.statSync().modified) ? a : b,
        );
  }
}
