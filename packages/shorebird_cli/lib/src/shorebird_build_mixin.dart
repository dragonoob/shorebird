import 'dart:io';

import 'package:collection/collection.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/command.dart';
import 'package:shorebird_cli/src/engine_config.dart';
import 'package:shorebird_cli/src/logger.dart';
import 'package:shorebird_cli/src/os/operating_system_interface.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';

enum Arch {
  arm64,
  arm32,
  x86_64,
}

class ArchMetadata {
  const ArchMetadata({
    required this.path,
    required this.arch,
    required this.enginePath,
  });

  final String path;
  final String arch;
  final String enginePath;
}

/// Used to wrap code that invokes `flutter build` with Shorebird's fork of
/// Flutter.
typedef ShorebirdBuildCommand = Future<void> Function();

/// {@template build_exception}
/// Thrown when a build fails.
/// {@endtemplate}
class BuildException implements Exception {
  /// {@macro build_exception}
  BuildException(this.message);

  /// Information about the build failure.
  final String message;
}

/// {@template export_method}
/// The method used to export the IPA.
/// {@endtemplate}
enum ExportMethod {
  appStore('app-store', 'Upload to the App Store'),
  adHoc(
    'ad-hoc',
    '''
Test on designated devices that do not need to be registered with the Apple developer account.
    Requires a distribution certificate.''',
  ),
  development(
    'development',
    '''Test only on development devices registered with the Apple developer account.''',
  ),
  enterprise(
    'enterprise',
    'Distribute an app registered with the Apple Developer Enterprise Program.',
  );

  /// {@macro export_method}
  const ExportMethod(this.argName, this.description);

  /// The command-line argument name for this export method.
  final String argName;

  /// A description of this method and how/when it should be used.
  final String description;
}

mixin ShorebirdBuildMixin on ShorebirdCommand {
  // This exists only so tests can get the full list.
  static const allAndroidArchitectures = <Arch, ArchMetadata>{
    Arch.arm64: ArchMetadata(
      path: 'arm64-v8a',
      arch: 'aarch64',
      enginePath: 'android_release_arm64',
    ),
    Arch.arm32: ArchMetadata(
      path: 'armeabi-v7a',
      arch: 'arm',
      enginePath: 'android_release',
    ),
    Arch.x86_64: ArchMetadata(
      path: 'x86_64',
      arch: 'x86_64',
      enginePath: 'android_release_x64',
    ),
  };

  // TODO(felangel): extend to other platforms.
  Map<Arch, ArchMetadata> get architectures {
    // Flutter has a whole bunch of logic to parse the --local-engine flag.
    // We probably need similar.
    // It's a bit odd to grab off the shorebird process, but it's the easiest
    // way to have a single source of truth for the engine config for now.
    if (engineConfig.localEngine != null) {
      final localEngineOutName = engineConfig.localEngine;
      final metaDataEntry = allAndroidArchitectures.entries.firstWhereOrNull(
        (entry) => localEngineOutName == entry.value.enginePath,
      );
      if (metaDataEntry == null) {
        throw Exception(
          'Unknown local engine architecture for '
          '--local-engine=$localEngineOutName\n'
          'Known values: '
          '${allAndroidArchitectures.values.map((e) => e.enginePath)}',
        );
      }
      return {metaDataEntry.key: metaDataEntry.value};
    }
    return allAndroidArchitectures;
  }

  Future<void> buildAppBundle({
    String? flavor,
    String? target,
    String? flutterRevision,
  }) async {
    return _runShorebirdBuildCommand(
      flutterRevision: flutterRevision,
      command: () async {
        const executable = 'flutter';
        final arguments = [
          'build',
          'appbundle',
          '--release',
          if (flavor != null) '--flavor=$flavor',
          if (target != null) '--target=$target',
          ...results.rest,
        ];

        final result = await process.run(
          executable,
          arguments,
          runInShell: true,
        );

        if (result.exitCode != ExitCode.success.code) {
          throw ProcessException(
            'flutter',
            arguments,
            result.stderr.toString(),
            result.exitCode,
          );
        }
      },
    );
  }

  Future<void> buildAar({
    required String buildNumber,
    String? flutterRevision,
  }) async {
    return _runShorebirdBuildCommand(
      flutterRevision: flutterRevision,
      command: () async {
        const executable = 'flutter';
        final arguments = [
          'build',
          'aar',
          '--no-debug',
          '--no-profile',
          '--build-number=$buildNumber',
          ...results.rest,
        ];

        final result = await process.run(
          executable,
          arguments,
          runInShell: true,
        );

        if (result.exitCode != ExitCode.success.code) {
          throw ProcessException(
            'flutter',
            arguments,
            result.stderr.toString(),
            result.exitCode,
          );
        }
      },
    );
  }

  Future<void> buildApk({
    String? flavor,
    String? target,
    bool splitPerAbi = false,
    String? flutterRevision,
  }) async {
    return _runShorebirdBuildCommand(
      flutterRevision: flutterRevision,
      command: () async {
        const executable = 'flutter';
        final arguments = [
          'build',
          'apk',
          '--release',
          if (flavor != null) '--flavor=$flavor',
          if (target != null) '--target=$target',
          // TODO(bryanoltman): reintroduce coverage when we can support this.
          // See https://github.com/shorebirdtech/shorebird/issues/1141.
          // coverage:ignore-start
          if (splitPerAbi) '--split-per-abi',
          // coverage:ignore-end
          ...results.rest,
        ];

        final result = await process.run(
          executable,
          arguments,
          runInShell: true,
        );

        if (result.exitCode != ExitCode.success.code) {
          throw ProcessException(
            'flutter',
            arguments,
            result.stderr.toString(),
            result.exitCode,
          );
        }
      },
    );
  }

  /// Calls `flutter build ipa`. If [codesign] is false, this will only build
  /// an .xcarchive and _not_ an .ipa.
  Future<void> buildIpa({
    required bool codesign,
    File? exportOptionsPlist,
    String? flavor,
    String? target,
    String? flutterRevision,
  }) async {
    return _runShorebirdBuildCommand(
      flutterRevision: flutterRevision,
      command: () async {
        const executable = 'flutter';
        final arguments = [
          'build',
          'ipa',
          '--release',
          if (flavor != null) '--flavor=$flavor',
          if (target != null) '--target=$target',
          if (!codesign) '--no-codesign',
          if (codesign)
            '''--export-options-plist=${(exportOptionsPlist ?? createExportOptionsPlist()).path}''',
          ...results.rest,
        ];

        final result = await process.run(
          executable,
          arguments,
          runInShell: true,
        );

        if (result.exitCode != ExitCode.success.code) {
          throw ProcessException(
            'flutter',
            arguments,
            result.stderr.toString(),
            result.exitCode,
          );
        }

        if (result.stderr
            .toString()
            .contains('Encountered error while creating the IPA')) {
          final errorMessage = _failedToCreateIpaErrorMessage(
            stderr: result.stderr.toString(),
          );

          throw BuildException(errorMessage);
        }
      },
    );
  }

  /// Creates an ExportOptions.plist file, which is used to tell xcodebuild to
  /// not manage the app version and build number. If we don't do this, then
  /// xcodebuild will increment the build number if it detects an App Store
  /// Connect build with the same version and build number. This is a problem
  /// for us when patching, as patches need to have the same version and build
  /// number as the release they are patching.
  /// See
  /// https://developer.apple.com/forums/thread/690647?answerId=689925022#689925022
  File createExportOptionsPlist({
    ExportMethod exportMethod = ExportMethod.appStore,
  }) {
    final plistContents = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>uploadBitcode</key>
  <false/>
  <key>method</key>
  <string>${exportMethod.argName}</string>
</dict>
</plist>
''';
    final tempDir = Directory.systemTemp.createTempSync();
    final exportPlistFile = File(p.join(tempDir.path, 'ExportOptions.plist'))
      ..createSync(recursive: true)
      ..writeAsStringSync(plistContents);
    return exportPlistFile;
  }

  /// Builds a release iOS framework (.xcframework) for the current project.
  Future<void> buildIosFramework({String? flutterRevision}) async {
    return _runShorebirdBuildCommand(
      flutterRevision: flutterRevision,
      command: () async {
        const executable = 'flutter';
        final arguments = [
          'build',
          'ios-framework',
          '--no-debug',
          '--no-profile',
          ...results.rest,
        ];

        final result = await process.run(
          executable,
          arguments,
          runInShell: true,
        );

        if (result.exitCode != ExitCode.success.code) {
          throw ProcessException(
            'flutter',
            arguments,
            result.stderr.toString(),
            result.exitCode,
          );
        }
      },
    );
  }

  /// A wrapper around [command] (which runs a `flutter build` command with
  /// Shorebird's fork of Flutter) with a try/finally that runs
  /// `flutter pub get` with the system installation of Flutter to reset
  /// `.dart_tool/package_config.json` to the system Flutter.
  Future<void> _runShorebirdBuildCommand({
    required ShorebirdBuildCommand command,
    String? flutterRevision,
  }) async {
    final currentFlutterRevision = shorebirdEnv.flutterRevision;
    flutterRevision ??= currentFlutterRevision;

    try {
      if (currentFlutterRevision != flutterRevision) {
        final flutterVersionProgress = logger.progress(
          'Switching to Flutter revision $flutterRevision',
        );
        await shorebirdFlutter.useRevision(revision: flutterRevision);
        flutterVersionProgress.complete();
      }

      await command();
    } finally {
      if (currentFlutterRevision != flutterRevision) {
        final flutterVersionProgress = logger.progress(
          '''Switching back to original Flutter revision $currentFlutterRevision''',
        );
        await shorebirdFlutter.useRevision(revision: currentFlutterRevision);
        flutterVersionProgress.complete();
      }

      await _systemFlutterPubGet();
    }
  }

  /// This is a hack to reset `.dart_tool/package_config.json` to point to the
  /// Flutter SDK on the user's PATH. This is necessary because Flutter commands
  /// run by shorebird update the package_config.json file to point to
  /// shorebird's version of Flutter, which confuses VS Code. See
  /// https://github.com/shorebirdtech/shorebird/issues/1101 for more info.
  Future<void> _systemFlutterPubGet() async {
    const executable = 'flutter';
    if (osInterface.which(executable) == null) {
      // If the user doesn't have Flutter on their PATH, then we can't run
      // `flutter pub get` with the system Flutter.
      return;
    }

    final arguments = ['--no-version-check', 'pub', 'get', '--offline'];

    final result = await process.run(
      executable,
      arguments,
      runInShell: true,
      useVendedFlutter: false,
    );

    if (result.exitCode != ExitCode.success.code) {
      logger.warn(
        '''
Build was successful, but `flutter pub get` failed to run after the build completed. You may see unexpected behavior in VS Code.

Either run `flutter pub get` manually, or follow the steps in ${link(uri: Uri.parse('https://docs.shorebird.dev/troubleshooting#i-installed-shorebird-and-now-i-cant-run-my-app-in-vs-code'))}.
''',
      );
    }
  }

  String _failedToCreateIpaErrorMessage({required String stderr}) {
    // The full error text consists of many repeated lines of the format:
    // (newlines added for line length)
    //
    // [   +1 ms] Encountered error while creating the IPA:
    // [        ] error: exportArchive: Team "Team" does not have permission to
    //      create "iOS In House" provisioning profiles.
    //    error: exportArchive: No profiles for 'com.example.dev' were found
    //    error: exportArchive: No signing certificate "iOS Distribution" found
    //    error: exportArchive: Communication with Apple failed
    //    error: exportArchive: No signing certificate "iOS Distribution" found
    //    error: exportArchive: Team "My Team" does not have permission to
    //      create "iOS App Store" provisioning profiles.
    //    error: exportArchive: No profiles for 'com.example.demo' were found
    //    error: exportArchive: Communication with Apple failed
    //    error: exportArchive: No signing certificate "iOS Distribution" found
    //    error: exportArchive: Communication with Apple failed
    final exportArchiveRegex = RegExp(r'error: exportArchive: (.+)$');

    return stderr
        .split('\n')
        .map((l) => l.trim())
        .toSet()
        .map(exportArchiveRegex.firstMatch)
        .whereType<Match>()
        .map((m) => '    ${m.group(1)!}')
        .join('\n');
  }

  /// Creates an AOT snapshot of the given [appDillPath] at [outFilePath] and
  /// returns the resulting file.
  Future<File> buildElfAotSnapshot({
    required String appDillPath,
    required String outFilePath,
  }) async {
    final arguments = [
      '--deterministic',
      '--snapshot-kind=app-aot-elf',
      '--elf=$outFilePath',
      appDillPath,
    ];

    final result = await process.run(
      shorebirdArtifacts.getArtifactPath(
        artifact: ShorebirdArtifact.genSnapshot,
      ),
      arguments,
    );

    if (result.exitCode != ExitCode.success.code) {
      throw Exception('Failed to create snapshot: ${result.stderr}');
    }

    return File(outFilePath);
  }
}
