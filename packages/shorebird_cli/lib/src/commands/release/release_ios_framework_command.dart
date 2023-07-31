import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/command.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/ios.dart';
import 'package:shorebird_cli/src/logger.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_build_mixin.dart';
import 'package:shorebird_cli/src/shorebird_config_mixin.dart';
import 'package:shorebird_cli/src/shorebird_environment.dart';
import 'package:shorebird_cli/src/shorebird_validation_mixin.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

class ReleaseIosFrameworkCommand extends ShorebirdCommand
    with ShorebirdConfigMixin, ShorebirdValidationMixin, ShorebirdBuildMixin {
  ReleaseIosFrameworkCommand() {
    argParser
      ..addOption(
        'release-version',
        help: '''
The version of the associated release (e.g. "1.0.0"). This should be the version
of the iOS app that is using this module.''',
        mandatory: true,
      )
      ..addFlag(
        'force',
        abbr: 'f',
        help: 'Release without confirmation if there are no errors.',
        negatable: false,
      );
  }

  @override
  String get description =>
      'Builds and submits your iOS framework to Shorebird.';

  @override
  String get name => 'ios-framework-alpha';

  @override
  Future<int> run() async {
    if (!platform.isMacOS) {
      logger.err('This command is only supported on macOS.');
      return ExitCode.unavailable.code;
    }

    try {
      await validatePreconditions(
        checkUserIsAuthenticated: true,
        checkShorebirdInitialized: true,
        validators: doctor.iosCommandValidators,
      );
    } on PreconditionFailedException catch (e) {
      return e.exitCode.code;
    }

    showiOSStatusWarning();

    const releasePlatform = ReleasePlatform.ios;
    final releaseVersion = results['release-version'] as String;
    final shorebirdYaml = ShorebirdEnvironment.getShorebirdYaml()!;
    final appId = shorebirdYaml.getAppId();
    final app = await codePushClientWrapper.getApp(appId: appId);

    final existingRelease = await codePushClientWrapper.maybeGetRelease(
      appId: appId,
      releaseVersion: releaseVersion,
    );
    if (existingRelease != null) {
      codePushClientWrapper.ensureReleaseIsNotActive(
        release: existingRelease,
        platform: releasePlatform,
      );
    }

    final buildProgress = logger.progress('Building iOS framework');

    try {
      await buildIosFramework();
    } catch (error) {
      buildProgress.fail('Failed to build iOS framework: $error');
      return ExitCode.software.code;
    }

    buildProgress.complete();

    final summary = [
      '''📱 App: ${lightCyan.wrap(app.displayName)} ${lightCyan.wrap('($appId)')}''',
      // TODO(felangel): uncomment once flavor support is added.
      // if (flavor != null) '🍧 Flavor: ${lightCyan.wrap(flavor)}',
      '📦 Release Version: ${lightCyan.wrap(releaseVersion)}',
      '''🕹️  Platform: ${lightCyan.wrap(releasePlatform.name)}''',
    ];

    logger.info('''

${styleBold.wrap(lightGreen.wrap('🚀 Ready to create a new release!'))}

${summary.join('\n')}
''');

    final force = results['force'] == true;
    final needConfirmation = !force;
    if (needConfirmation) {
      final confirm = logger.confirm('Would you like to continue?');

      if (!confirm) {
        logger.info('Aborting.');
        return ExitCode.success.code;
      }
    }

    final flutterRevisionProgress = logger.progress(
      'Fetching Flutter revision',
    );
    final String shorebirdFlutterRevision;
    try {
      shorebirdFlutterRevision = await getShorebirdFlutterRevision();
      flutterRevisionProgress.complete();
    } catch (error) {
      flutterRevisionProgress.fail('$error');
      return ExitCode.software.code;
    }

    final Release release;
    if (existingRelease != null) {
      release = existingRelease;
    } else {
      release = await codePushClientWrapper.createRelease(
        appId: appId,
        version: releaseVersion,
        flutterRevision: shorebirdFlutterRevision,
        platform: releasePlatform,
      );
    }

    final iosBuildDir = p.join(Directory.current.path, 'build', 'ios');
    final frameworkDirectory = Directory(
      p.join(iosBuildDir, 'framework', 'Release'),
    );
    final xcframeworkPath = p.join(frameworkDirectory.path, 'App.xcframework');

    await codePushClientWrapper.createIosFrameworkReleaseArtifacts(
      appId: appId,
      releaseId: release.id,
      appFrameworkPath: xcframeworkPath,
    );

    await codePushClientWrapper.updateReleaseStatus(
      appId: app.appId,
      releaseId: release.id,
      platform: releasePlatform,
      status: ReleaseStatus.active,
    );

    final relativeFrameworkDirectoryPath = p.relative(frameworkDirectory.path);
    logger
      ..success('\n✅ Published Release!')
      ..info('''

Your next step is to include the .xcframework files in ${lightCyan.wrap(relativeFrameworkDirectoryPath)} in your iOS app.

To do this:
    1. Add the relative path to $relativeFrameworkDirectoryPath to your app's Framework Search Paths in your Xcode build settings.
    2. Embed the App.xcframework and Flutter.framework in your Xcode project.

Instructions for these steps can be found at https://docs.flutter.dev/add-to-app/ios/project-setup#option-b---embed-frameworks-in-xcode.
''');

    return ExitCode.success.code;
  }
}