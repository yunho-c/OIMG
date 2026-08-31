import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oimg/main.dart';
import 'package:oimg/src/build/distribution.dart';
import 'package:oimg/src/file_open/file_open_channel.dart';
import 'package:oimg/src/file_open/file_open_controller.dart';
import 'package:oimg/src/file_open/file_open_providers.dart';
import 'package:oimg/src/optimization/optimization_providers.dart';
import 'package:oimg/src/rust/slimg_api.dart';
import 'package:oimg/src/rust/types.dart';
import 'package:oimg/src/settings/app_settings.dart';
import 'package:oimg/src/settings/app_settings_controller.dart';
import 'package:oimg/src/settings/app_settings_repository.dart';
import 'package:oimg/src/settings/developer_diagnostics.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

void main() {
  PackageInfo.setMockInitialValues(
    appName: 'OIMG',
    packageName: 'com.yunho-c.oimg',
    version: '0.1.2',
    buildNumber: '5',
    buildSignature: '',
  );

  testWidgets('renders empty state with no startup files', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi();
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(scaffold.floatingHeader, isTrue);
    expect(appBar.surfaceOpacity, 0.10);
    expect(appBar.surfaceBlur, 4);
    expect(find.text('Optimize images easily'), findsOneWidget);
    expect(find.text('Built with care by '), findsOneWidget);
    expect(find.text('v0.1.2 · Built with care by '), findsNothing);
    expect(
      find.byKey(const ValueKey('empty-state-browse-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('empty-state-hero-gradient-panel')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('empty-state-hero-acrylic-panel')),
      findsOneWidget,
    );
    expect(find.byType(DropRegion), findsOneWidget);
  });

  testWidgets('stored gradient panel preference changes empty state hero', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = _FakeAppSettingsStore()
      ..value = AppSettings.defaults
          .copyWith(homeAcrylicPanelEnabled: false)
          .toJsonString();
    final slimg = _FakeSlimgApi();
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
    );
    await controller.initialize();

    await tester.pumpWidget(
      _buildApp(controller: controller, slimg: slimg, store: store),
    );
    await tester.pumpAndSettle();

    expect(find.text('Optimize images easily'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('empty-state-hero-acrylic-panel')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('empty-state-hero-gradient-panel')),
      findsOneWidget,
    );
  });

  testWidgets('feature card hover shows a preview panel', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi();
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('empty-state-feature-preview-panel')),
      findsNothing,
    );

    final card = find.byKey(const ValueKey('empty-state-feature-preview'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(card));
    await mouse.moveTo(tester.getCenter(card));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(
      find.byKey(const ValueKey('empty-state-feature-preview-panel')),
      findsOneWidget,
    );
  });

  testWidgets('browse menu shows file and folder actions on empty state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi();
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('empty-state-browse-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('empty-state-open-files')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('empty-state-open-folder')),
      findsOneWidget,
    );
  });

  testWidgets('browse files action opens a session from the empty state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final channel = _FakeFileOpenChannel()..pickFilesResult = ['/tmp/hero.png'];
    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/hero.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(channel: channel, slimg: slimg);
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('empty-state-browse-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('empty-state-open-files')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(channel.pickFilesCallCount, 1);
    expect(find.text('hero.png'), findsWidgets);
  });

  testWidgets('browse folder action opens a session from the empty state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const path = '/tmp/oimg-empty-state/inside.png';
    final channel = _FakeFileOpenChannel()..pickFolderResult = [path];
    final slimg = _FakeSlimgApi(inspectResults: {path: _metadata('png', 2400)});
    final controller = FileOpenController(channel: channel, slimg: slimg);
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('empty-state-browse-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('empty-state-open-folder')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(channel.pickFolderCallCount, 1);
    expect(find.text('inside.png'), findsWidgets);
  });

  testWidgets(
    'shows a transparency warning when the selected codec cannot preserve alpha',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {
          '/tmp/transparent.png': _metadata('png', 2400, hasTransparency: true),
        },
      );
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/transparent.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'JPEG does not support transparency. Transparent areas will be flattened.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'shows an optimized preview size warning when the preview is larger than the source',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 1000)},
      )..previewSizeBytes = 1200;
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Original image is smaller.'), findsOneWidget);
    },
  );

  testWidgets(
    'does not show the optimized preview size warning when the preview is smaller or equal',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 1200)},
      )..previewSizeBytes = 1200;
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Original image is smaller.'), findsNothing);
    },
  );

  testWidgets(
    'does not show the optimized preview size warning while the preview is still loading',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 1000)},
        previewDelay: const Duration(seconds: 5),
      )..previewSizeBytes = 1600;
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Original image is smaller.'), findsNothing);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'does not show the optimized preview size warning in folder mode',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {
          '/tmp/animals/cat.png': _metadata('png', 1000),
          '/tmp/animals/dog.png': _metadata('png', 900),
        },
      )..previewSizeBytes = 1400;
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/animals/cat.png', '/tmp/animals/dog.png'],
      );
      await controller.initialize();
      controller.showFolder('/tmp/animals');

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pumpAndSettle();

      expect(find.text('Original image is smaller.'), findsNothing);
    },
  );

  testWidgets(
    'preview header shows transparent as a separate label before the resolution',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {
          '/tmp/transparent.png': _metadata('png', 2400, hasTransparency: true),
        },
      );
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/transparent.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pumpAndSettle();

      expect(find.text('transparent'), findsOneWidget);
      expect(find.text('48 x 32'), findsOneWidget);
      expect(find.textContaining('|'), findsNothing);
    },
  );

  testWidgets(
    'preview header shows only the resolution for opaque images and keeps the megapixel tooltip wrapper',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      );
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pumpAndSettle();

      expect(find.text('48 x 32'), findsOneWidget);
      expect(find.text('transparent'), findsNothing);
      expect(
        find.ancestor(of: find.text('48 x 32'), matching: find.byType(Tooltip)),
        findsOneWidget,
      );
    },
  );

  testWidgets('renders startup session, preview, and actions', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {
        '/tmp/first.png': _metadata('png', 2400),
        '/tmp/second.jpg': _metadata('jpeg', 1800),
      },
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png', '/tmp/second.jpg'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Original'), findsWidgets);
    expect(find.text('Optimized'), findsWidgets);
    expect(find.text('Optimize'), findsOneWidget);
    expect(find.text('Optimize selected'), findsNothing);
    expect(find.text('Optimize all'), findsNothing);
    expect(find.text('first.png'), findsWidgets);
    expect(find.text('second.jpg'), findsWidgets);
    expect(find.text('JPEG'), findsWidgets);
    expect(find.text('Pixel Match'), findsOneWidget);
    expect(find.text('MS-SSIM'), findsOneWidget);
    expect(find.text('SSIMULACRA 2'), findsOneWidget);
    expect(find.text('50.0%'), findsOneWidget);
    expect(find.text('0.987'), findsOneWidget);

    await tester.tap(find.text('second.jpg').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(controller.currentPath, '/tmp/second.jpg');
    expect(find.text('second.jpg'), findsWidgets);
  });

  testWidgets('quality rows resolve independently after preview loads', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg =
        _FakeSlimgApi(
            inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
          )
          ..pixelMatchDelay = const Duration(milliseconds: 40)
          ..msSsimDelay = const Duration(milliseconds: 120)
          ..ssimulacra2Delay = const Duration(milliseconds: 200);
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 170));

    expect(find.byType(CircularProgressIndicator), findsNWidgets(3));

    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('98.7%'), findsAtLeastNWidgets(1));
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));

    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('0.987'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('92.4'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('similarity stat updates eagerly as metrics resolve', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg =
        _FakeSlimgApi(
            inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
          )
          ..pixelMatchDelay = const Duration(milliseconds: 40)
          ..msSsimDelay = const Duration(milliseconds: 120)
          ..ssimulacra2Delay = const Duration(milliseconds: 200)
          ..pixelMatchValue = 90.0
          ..msSsimValue = 0.5
          ..ssimulacra2Value = 30.0;
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 170));

    expect(_similarityLoadingFinder(), findsNothing);
    expect(_similarityValueFinder('—'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 50));
    expect(_similarityLoadingFinder(), findsNothing);
    expect(_similarityValueFinder('~90.0%'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 80));
    expect(_similarityApproximateValueFinder(), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(_similarityValueFinder('56.7%'), findsOneWidget);
  });

  testWidgets('similarity stat ignores unavailable metrics', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg =
        _FakeSlimgApi(
            inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
          )
          ..pixelMatchValue = 80.0
          ..msSsimValue = null
          ..ssimulacra2Value = 20.0;
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(_similarityValueFinder('50.0%'), findsOneWidget);
  });

  testWidgets('similarity stat shows 100% for full-quality metrics', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg =
        _FakeSlimgApi(
            inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
          )
          ..pixelMatchValue = 100.0
          ..msSsimValue = 1.0
          ..ssimulacra2Value = 100.0;
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(_similarityLoadingFinder(), findsNothing);
    expect(_similarityValueFinder('100%'), findsOneWidget);
  });

  testWidgets(
    'quality rows format full-quality metrics without extra decimals',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg =
          _FakeSlimgApi(
              inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
            )
            ..pixelMatchValue = 100.0
            ..msSsimValue = 1.0
            ..ssimulacra2Value = 100.0;
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('100%'), findsAtLeastNWidgets(1));
      expect(find.text('1.00'), findsOneWidget);
      expect(find.text('100'), findsAtLeastNWidgets(1));
    },
  );

  testWidgets('bottom stats retain values while quality preview recomputes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      previewDelay: const Duration(milliseconds: 300),
    )..previewSizeBytes = 1200;
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    expect(
      _bottomStatValueText(tester, label: 'Optimized', value: '1.2 KB'),
      isNotNull,
    );
    expect(
      _bottomStatValueText(tester, label: 'Savings', value: '50.0%'),
      isNotNull,
    );
    expect(_similarityValueFinder('96.6%'), findsOneWidget);

    slimg
      ..previewSizeBytes = 800
      ..pixelMatchValue = 80.0
      ..msSsimValue = 0.8
      ..ssimulacra2Value = 75.0;

    final start = _qualitySliderValueOffset(tester, value: 80);
    final end = _qualitySliderValueOffset(tester, value: 55);
    await tester.dragFrom(start, end - start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('bottom-stat-Optimized')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    expect(
      _bottomStatValueText(tester, label: 'Optimized', value: '1.2 KB'),
      isNotNull,
    );
    expect(
      _bottomStatValueText(tester, label: 'Savings', value: '50.0%'),
      isNotNull,
    );
    expect(_similarityValueFinder('96.6%'), findsOneWidget);
    expect(_similarityValueFinder('—'), findsNothing);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final animatedOptimizedValue = _bottomStatDisplayValue(
      tester,
      label: 'Optimized',
    );
    expect(animatedOptimizedValue, isNot('1.2 KB'));
    expect(animatedOptimizedValue, isNot('800 B'));

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(
      _bottomStatValueText(tester, label: 'Optimized', value: '800 B'),
      isNotNull,
    );
    expect(
      _bottomStatValueText(tester, label: 'Savings', value: '66.7%'),
      isNotNull,
    );
    expect(_similarityValueFinder('78.3%'), findsOneWidget);
  });

  testWidgets('similarity stat shows N/A when all metrics are unavailable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg =
        _FakeSlimgApi(
            inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
          )
          ..pixelMatchValue = null
          ..msSsimValue = null
          ..ssimulacra2Value = null;
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(_similarityLoadingFinder(), findsNothing);
    expect(_similarityValueFinder('N/A'), findsOneWidget);
  });

  testWidgets('folder mode keeps similarity stat as N/A', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {
        '/tmp/animals/cat.png': _metadata('png', 2400),
        '/tmp/animals/dog.png': _metadata('png', 2200),
      },
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/animals/cat.png', '/tmp/animals/dog.png'],
    );
    await controller.initialize();
    controller.showFolder('/tmp/animals');

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    expect(_similarityLoadingFinder(), findsNothing);
    expect(_similarityValueFinder('N/A'), findsOneWidget);
  });

  testWidgets('preview mode row defaults to original until preview exists', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      previewDelay: const Duration(seconds: 5),
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.byKey(const ValueKey('preview-display-mode-row')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('preview-mode-Original')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('preview-mode-Optimized')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('preview-mode-Difference')),
      findsOneWidget,
    );
    expect(slimg.differenceCallCount, 0);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
  });

  testWidgets('difference mode computes lazily and shows loading state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
    )..differenceDelay = const Duration(milliseconds: 100);
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(slimg.differenceCallCount, 0);

    await tester.tap(find.byKey(const ValueKey('preview-mode-Difference')));
    await tester.pump();

    expect(slimg.differenceCallCount, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.byKey(const ValueKey('difference-preview-loading')),
      findsNothing,
    );

    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byKey(const ValueKey('preview-mode-Original')));
    await tester.pump();
    expect(slimg.differenceCallCount, 1);

    await tester.tap(find.byKey(const ValueKey('preview-mode-Difference')));
    await tester.pump();
    expect(slimg.differenceCallCount, 1);
  });

  testWidgets(
    'difference mode keeps the preview visible while loading first frame',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final differenceFrame = await _differenceFrame(
        width: 48,
        height: 32,
        rgbaBytes: _rgbaBytesFromGrayscaleMeans(List<int>.filled(48 * 32, 0)),
      );
      addTearDown(differenceFrame.image.dispose);
      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      );
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(
        _buildApp(
          controller: controller,
          slimg: slimg,
          differenceFrameBuilder: () async {
            await Future<void>.delayed(const Duration(milliseconds: 1000));
            return differenceFrame;
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byKey(const ValueKey('preview-mode-Difference')));
      await tester.pump();

      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(
        find.byKey(const ValueKey('difference-preview-ready')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('difference-preview-loading')),
        findsNothing,
      );

      await tester.pump(const Duration(milliseconds: 900));

      expect(
        find.byKey(const ValueKey('difference-preview-ready')),
        findsOneWidget,
      );
    },
  );

  testWidgets('preview transform is preserved across difference mode', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final differenceFrame = await _differenceFrame(
      width: 48,
      height: 32,
      rgbaBytes: _rgbaBytesFromGrayscaleMeans(List<int>.filled(48 * 32, 0)),
    );
    addTearDown(differenceFrame.image.dispose);
    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(
      _buildApp(
        controller: controller,
        slimg: slimg,
        differenceFrameBuilder: () async => differenceFrame,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final imageViewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final sharedController = imageViewer.transformationController!;
    final transform = Matrix4.identity()
      ..translateByDouble(24.0, 18.0, 0.0, 1.0)
      ..scaleByDouble(2.0, 2.0, 1.0, 1.0);
    sharedController.value = transform;
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('preview-mode-Difference')));
    await tester.pump();

    final differenceViewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(differenceViewer.transformationController, same(sharedController));
    expect(
      differenceViewer.transformationController!.value.storage,
      orderedEquals(transform.storage),
    );

    await tester.tap(find.byKey(const ValueKey('preview-mode-Original')));
    await tester.pump();

    final originalViewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(originalViewer.transformationController, same(sharedController));
    expect(
      originalViewer.transformationController!.value.storage,
      orderedEquals(transform.storage),
    );
  });

  testWidgets('switching back to a file reuses cached preview and metrics', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {
        '/tmp/first.png': _metadata('png', 2400),
        '/tmp/second.png': _metadata('png', 1800),
      },
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png', '/tmp/second.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(slimg.previewCallCount, 1);
    expect(slimg.pixelMatchCallCount, 1);
    expect(slimg.msSsimCallCount, 1);
    expect(slimg.ssimulacra2CallCount, 1);

    await tester.tap(find.text('second.png').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(slimg.previewCallCount, 2);
    expect(slimg.pixelMatchCallCount, 2);
    expect(slimg.msSsimCallCount, 2);
    expect(slimg.ssimulacra2CallCount, 2);

    await tester.tap(find.text('first.png').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(slimg.previewCallCount, 2);
    expect(slimg.pixelMatchCallCount, 2);
    expect(slimg.msSsimCallCount, 2);
    expect(slimg.ssimulacra2CallCount, 2);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('switching back to a file reuses cached difference image', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {
        '/tmp/first.png': _metadata('png', 2400),
        '/tmp/second.png': _metadata('png', 1800),
      },
    )..differenceDelay = const Duration(milliseconds: 80);
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png', '/tmp/second.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const ValueKey('preview-mode-Difference')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(slimg.differenceCallCount, 1);

    await tester.tap(find.text('second.png').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('first.png').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.byKey(const ValueKey('preview-mode-Difference')));
    await tester.pump();

    expect(slimg.differenceCallCount, 1);
  });

  testWidgets('cache eviction disposes old preview artifacts', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {
        '/tmp/huge-a.png': ImageMetadata(
          width: 4096,
          height: 4096,
          format: 'png',
          fileSize: BigInt.from(2400),
          hasTransparency: false,
        ),
        '/tmp/huge-b.png': ImageMetadata(
          width: 4096,
          height: 4096,
          format: 'png',
          fileSize: BigInt.from(2200),
          hasTransparency: false,
        ),
      },
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/huge-a.png', '/tmp/huge-b.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(slimg.previewCallCount, 1);
    expect(slimg.disposedPreviewArtifactIds, isEmpty);

    await tester.tap(find.text('huge-b.png').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(slimg.previewCallCount, 2);
    expect(slimg.disposedPreviewArtifactIds, hasLength(1));

    await tester.tap(find.text('huge-a.png').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(slimg.previewCallCount, 3);
  });

  testWidgets('analyze sweep populates the chart without changing the slider', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
    )..analyzeSampleDelay = const Duration(milliseconds: 20);
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.widgetWithText(OutlineButton, 'Analyze'), findsOneWidget);
    expect(find.byType(LineChart), findsNothing);
    expect(find.text('80'), findsWidgets);

    await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    final runningChart = tester.widget<LineChart>(find.byType(LineChart));
    expect(runningChart.data.extraLinesData.verticalLines, isEmpty);

    await tester.pumpAndSettle();

    expect(find.byType(LineChart), findsOneWidget);
    expect(find.text('80'), findsWidgets);

    final chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart.data.lineTouchData.handleBuiltInTouches, isFalse);
    expect(chart.data.lineBarsData, hasLength(3));
    expect(chart.data.maxX, 1575);
    expect(chart.data.gridData.verticalInterval, 375);
    expect(chart.data.titlesData.bottomTitles.sideTitles.interval, 375);
    expect(chart.data.extraLinesData.verticalLines, isEmpty);
    expect(chart.data.rangeAnnotations.verticalRangeAnnotations, isEmpty);
  });

  testWidgets('analyze chart keeps original marker near optimized sizes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2000)},
    )..analyzeSampleDelay = const Duration(milliseconds: 20);
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
    await tester.pumpAndSettle();

    final chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart.data.maxX, 2100);
    expect(chart.data.gridData.verticalInterval, 500);
    expect(chart.data.titlesData.bottomTitles.sideTitles.interval, 500);
    expect(chart.data.extraLinesData.verticalLines, hasLength(1));
    expect(chart.data.extraLinesData.verticalLines.first.x, 2000);
    expect(chart.data.rangeAnnotations.verticalRangeAnnotations, hasLength(1));
    expect(chart.data.rangeAnnotations.verticalRangeAnnotations.first.x1, 2000);
    expect(chart.data.rangeAnnotations.verticalRangeAnnotations.first.x2, 2100);
  });

  testWidgets('analyze button toggles completed chart visibility', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
    )..analyzeSampleDelay = const Duration(milliseconds: 20);
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
    await tester.pumpAndSettle();

    expect(find.byType(LineChart), findsOneWidget);
    expect(find.widgetWithText(OutlineButton, 'Hide'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlineButton, 'Hide'));
    await tester.pumpAndSettle();

    expect(find.byType(LineChart), findsNothing);
    expect(find.widgetWithText(OutlineButton, 'Show'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlineButton, 'Show'));
    await tester.pumpAndSettle();

    expect(find.byType(LineChart), findsOneWidget);
    expect(find.widgetWithText(OutlineButton, 'Hide'), findsOneWidget);
  });

  testWidgets(
    'selecting an analyze chart point updates the quality setting without clearing the chart',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = _FakeAppSettingsStore();
      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      )..analyzeSampleDelay = const Duration(milliseconds: 20);
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(
        _buildApp(controller: controller, slimg: slimg, store: store),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();

      final chart = tester.widget<LineChart>(find.byType(LineChart));
      final firstBar = chart.data.lineBarsData.first;
      final firstSpot = firstBar.spots.first;
      chart.data.lineTouchData.touchCallback?.call(
        FlTapDownEvent(
          TapDownDetails(
            localPosition: Offset.zero,
            kind: PointerDeviceKind.mouse,
          ),
        ),
        LineTouchResponse(
          touchLocation: Offset.zero,
          touchChartCoordinate: Offset.zero,
          lineBarSpots: [TouchLineBarSpot(firstBar, 0, firstSpot, 0)],
        ),
      );
      await tester.pumpAndSettle();

      final settings = AppSettings.fromJsonString((await store.read())!);
      expect(settings.quality, 100);
      expect(find.byType(LineChart), findsOneWidget);
    },
  );

  testWidgets(
    'selecting an analyze chart point keeps selected sample metrics visible while preview reloads',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = _FakeAppSettingsStore();
      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      )..analyzeSampleDelay = const Duration(milliseconds: 20);
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(
        _buildApp(controller: controller, slimg: slimg, store: store),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();

      final pixelMatchCallsBeforeSelection = slimg.pixelMatchCallCount;
      final msSsimCallsBeforeSelection = slimg.msSsimCallCount;
      final ssimulacra2CallsBeforeSelection = slimg.ssimulacra2CallCount;

      slimg.pixelMatchDelay = const Duration(seconds: 5);
      slimg.msSsimDelay = const Duration(seconds: 5);
      slimg.ssimulacra2Delay = const Duration(seconds: 5);

      final chart = tester.widget<LineChart>(find.byType(LineChart));
      final firstBar = chart.data.lineBarsData.first;
      final firstSpot = firstBar.spots.first;
      chart.data.lineTouchData.touchCallback?.call(
        FlTapDownEvent(
          TapDownDetails(
            localPosition: Offset.zero,
            kind: PointerDeviceKind.mouse,
          ),
        ),
        LineTouchResponse(
          touchLocation: Offset.zero,
          touchChartCoordinate: Offset.zero,
          lineBarSpots: [TouchLineBarSpot(firstBar, 0, firstSpot, 0)],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      final settings = AppSettings.fromJsonString((await store.read())!);
      expect(settings.quality, 100);
      expect(find.byType(LineChart), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('0.950'), findsOneWidget);
      expect(find.text('98.3'), findsOneWidget);
      expect(
        _bottomStatValueText(tester, label: 'Similarity', value: '97.8%'),
        isNotNull,
      );
      expect(slimg.pixelMatchCallCount, pixelMatchCallsBeforeSelection);
      expect(slimg.msSsimCallCount, msSsimCallsBeforeSelection);
      expect(slimg.ssimulacra2CallCount, ssimulacra2CallsBeforeSelection);

      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'hovering an analyze chart point does not update the quality setting',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = _FakeAppSettingsStore();
      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      )..analyzeSampleDelay = const Duration(milliseconds: 20);
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(
        _buildApp(controller: controller, slimg: slimg, store: store),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();

      final chart = tester.widget<LineChart>(find.byType(LineChart));
      final firstBar = chart.data.lineBarsData.first;
      final lastSpot = firstBar.spots.last;
      chart.data.lineTouchData.touchCallback?.call(
        FlPointerHoverEvent(const PointerHoverEvent(position: Offset.zero)),
        LineTouchResponse(
          touchLocation: Offset.zero,
          touchChartCoordinate: Offset.zero,
          lineBarSpots: [
            TouchLineBarSpot(firstBar, 0, lastSpot, firstBar.spots.length - 1),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(await store.read(), isNull);
      expect(
        _bottomStatValueText(tester, label: 'Optimized', value: '1.5 KB'),
        isNotNull,
      );
      expect(find.byType(LineChart), findsOneWidget);
    },
  );

  testWidgets(
    'hovering another analyze sample after selection keeps the optimized preview renderable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = _FakeAppSettingsStore();
      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      )..analyzeSampleDelay = const Duration(milliseconds: 20);
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(
        _buildApp(controller: controller, slimg: slimg, store: store),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();

      final chart = tester.widget<LineChart>(find.byType(LineChart));
      final firstBar = chart.data.lineBarsData.first;
      final firstSpot = firstBar.spots.first;
      final lastSpot = firstBar.spots.last;

      chart.data.lineTouchData.touchCallback?.call(
        FlTapDownEvent(
          TapDownDetails(
            localPosition: Offset.zero,
            kind: PointerDeviceKind.mouse,
          ),
        ),
        LineTouchResponse(
          touchLocation: Offset.zero,
          touchChartCoordinate: Offset.zero,
          lineBarSpots: [TouchLineBarSpot(firstBar, 0, firstSpot, 0)],
        ),
      );
      await tester.pumpAndSettle();

      chart.data.lineTouchData.touchCallback?.call(
        FlPointerHoverEvent(const PointerHoverEvent(position: Offset.zero)),
        LineTouchResponse(
          touchLocation: Offset.zero,
          touchChartCoordinate: Offset.zero,
          lineBarSpots: [
            TouchLineBarSpot(firstBar, 0, lastSpot, firstBar.spots.length - 1),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Unable to load first.png.'), findsNothing);
      expect(find.byType(LineChart), findsOneWidget);
    },
  );

  testWidgets(
    'leaving the analyze chart restores the committed sample stats after hover',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = _FakeAppSettingsStore();
      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      )..analyzeSampleDelay = const Duration(milliseconds: 20);
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(
        _buildApp(controller: controller, slimg: slimg, store: store),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();

      final chart = tester.widget<LineChart>(find.byType(LineChart));
      final firstBar = chart.data.lineBarsData.first;
      final committedSpot = firstBar.spots.first;
      chart.data.lineTouchData.touchCallback?.call(
        FlTapDownEvent(
          TapDownDetails(
            localPosition: Offset.zero,
            kind: PointerDeviceKind.mouse,
          ),
        ),
        LineTouchResponse(
          touchLocation: Offset.zero,
          touchChartCoordinate: Offset.zero,
          lineBarSpots: [TouchLineBarSpot(firstBar, 0, committedSpot, 0)],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _bottomStatValueText(tester, label: 'Optimized', value: '700 B'),
        isNotNull,
      );

      final hoveredSpot = firstBar.spots.last;
      chart.data.lineTouchData.touchCallback?.call(
        FlPointerHoverEvent(const PointerHoverEvent(position: Offset.zero)),
        LineTouchResponse(
          touchLocation: Offset.zero,
          touchChartCoordinate: Offset.zero,
          lineBarSpots: [
            TouchLineBarSpot(
              firstBar,
              0,
              hoveredSpot,
              firstBar.spots.length - 1,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _bottomStatValueText(tester, label: 'Optimized', value: '1.5 KB'),
        isNotNull,
      );

      final chartRegion = tester.widget<MouseRegion>(
        find.byKey(const ValueKey('analyze-chart-region')),
      );
      chartRegion.onExit?.call(const PointerExitEvent(position: Offset.zero));
      await tester.pumpAndSettle();

      expect(
        _bottomStatValueText(tester, label: 'Optimized', value: '700 B'),
        isNotNull,
      );
      expect(
        _bottomStatValueText(tester, label: 'Similarity', value: '97.8%'),
        isNotNull,
      );

      final settings = AppSettings.fromJsonString((await store.read())!);
      expect(settings.quality, 100);
    },
  );

  testWidgets(
    'analyze header shows live quality while running and hovered quality after completion',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      )..analyzeSampleDelay = const Duration(milliseconds: 80);
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));

      expect(find.text('Q0'), findsOneWidget);

      await tester.pumpAndSettle();

      final chart = tester.widget<LineChart>(find.byType(LineChart));
      final firstBar = chart.data.lineBarsData.first;
      final firstSpot = firstBar.spots.first;
      chart.data.lineTouchData.touchCallback?.call(
        FlPointerHoverEvent(const PointerHoverEvent(position: Offset.zero)),
        LineTouchResponse(
          touchLocation: Offset.zero,
          touchChartCoordinate: Offset.zero,
          lineBarSpots: [TouchLineBarSpot(firstBar, 0, firstSpot, 0)],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Q100'), findsOneWidget);
      expect(find.text('Q0'), findsNothing);
    },
  );

  testWidgets(
    'running analyze auto-selects the newest completed sample for preview data',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      )..analyzeSampleDelay = const Duration(milliseconds: 120);
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MyApp)),
      );
      final analyzeState = container.read(analyzeRunControllerProvider);
      final selectedSample = container.read(selectedAnalyzeSampleProvider);
      final optimizedDisplay = container.read(currentOptimizedDisplayProvider);

      expect(analyzeState.isRunning, isTrue);
      expect(selectedSample, isNotNull);
      expect(selectedSample!.quality, 0);
      expect(optimizedDisplay, isNotNull);
      expect(optimizedDisplay!.artifactId, 'analyze-artifact-0');
      expect(
        _bottomStatValueText(tester, label: 'Optimized', value: '1.5 KB'),
        isNotNull,
      );

      await container
          .read(analyzeRunControllerProvider.notifier)
          .cancelAnalyze();
      await tester.pump();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('hovering an analyze chart point preserves difference mode', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
    )..analyzeSampleDelay = const Duration(milliseconds: 20);
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const ValueKey('preview-mode-Difference')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(slimg.differenceCallCount, 1);

    await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump(const Duration(milliseconds: 200));

    final chart = tester.widget<LineChart>(find.byType(LineChart));
    final firstBar = chart.data.lineBarsData.first;
    final firstSpot = firstBar.spots.first;
    chart.data.lineTouchData.touchCallback?.call(
      FlPointerHoverEvent(const PointerHoverEvent(position: Offset.zero)),
      LineTouchResponse(
        touchLocation: Offset.zero,
        touchChartCoordinate: Offset.zero,
        lineBarSpots: [TouchLineBarSpot(firstBar, 0, firstSpot, 0)],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MyApp)),
    );
    expect(slimg.differenceCallCount, greaterThanOrEqualTo(2));
    expect(
      container.read(currentPreviewDisplayModeProvider),
      PreviewDisplayMode.difference,
    );
  });

  testWidgets(
    'difference mode follows quality slider changes without reselecting the mode',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.jpg': _metadata('jpeg', 2400)},
      );
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.jpg'],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('preview-mode-Difference')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(slimg.differenceCallCount, 1);
      expect(find.text('Difference preview unavailable.'), findsNothing);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MyApp)),
      );
      await container.read(appSettingsProvider.notifier).setQuality(55);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        container.read(currentPreviewDisplayModeProvider),
        PreviewDisplayMode.difference,
      );
      expect(slimg.differenceCallCount, greaterThan(1));
      expect(find.text('Difference preview unavailable.'), findsNothing);
    },
  );

  testWidgets(
    'selecting an analyze sample in difference mode keeps analyze artifacts alive',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = _FakeAppSettingsStore();
      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.jpg': _metadata('jpeg', 2400)},
      )..analyzeSampleDelay = const Duration(milliseconds: 20);
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.jpg'],
      );
      await controller.initialize();

      await tester.pumpWidget(
        _buildApp(controller: controller, slimg: slimg, store: store),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('preview-mode-Difference')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final chart = tester.widget<LineChart>(find.byType(LineChart));
      final firstBar = chart.data.lineBarsData.first;
      final firstSpot = firstBar.spots[3];
      final lastSpot = firstBar.spots.last;

      chart.data.lineTouchData.touchCallback?.call(
        FlTapDownEvent(
          TapDownDetails(
            localPosition: Offset.zero,
            kind: PointerDeviceKind.mouse,
          ),
        ),
        LineTouchResponse(
          touchLocation: Offset.zero,
          touchChartCoordinate: Offset.zero,
          lineBarSpots: [TouchLineBarSpot(firstBar, 0, firstSpot, 3)],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(slimg.analyzeJobCount, 1);

      chart.data.lineTouchData.touchCallback?.call(
        FlPointerHoverEvent(const PointerHoverEvent(position: Offset.zero)),
        LineTouchResponse(
          touchLocation: Offset.zero,
          touchChartCoordinate: Offset.zero,
          lineBarSpots: [
            TouchLineBarSpot(firstBar, 0, lastSpot, firstBar.spots.length - 1),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(slimg.analyzeJobCount, 1);
      expect(find.text('Difference preview unavailable.'), findsNothing);
    },
  );

  testWidgets(
    'retained async image preview keeps the previous frame while loading',
    (tester) async {
      final firstFrame = await _differenceFrame(
        width: 4,
        height: 4,
        rgbaBytes: Uint8List(4 * 4 * 4),
      );
      addTearDown(firstFrame.image.dispose);

      await tester.pumpWidget(
        _buildDifferencePreviewHost(
          child: const DifferencePreview(
            retentionScopeKey: 'first',
            frame: AsyncData<PreviewDifferenceFrame?>(null),
            fileName: 'first.png',
            showCoordinates: true,
            useRgbSwatches: false,
            unavailableMessage: 'Difference preview unavailable.',
          ),
        ),
      );
      await tester.pump();

      await tester.pumpWidget(
        _buildDifferencePreviewHost(
          child: DifferencePreview(
            retentionScopeKey: 'first',
            frame: AsyncData<PreviewDifferenceFrame?>(firstFrame),
            fileName: 'first.png',
            showCoordinates: true,
            useRgbSwatches: false,
            unavailableMessage: 'Difference preview unavailable.',
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('difference-preview-ready')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('difference-preview-loading')),
        findsNothing,
      );

      await tester.pumpWidget(
        _buildDifferencePreviewHost(
          child: const DifferencePreview(
            retentionScopeKey: 'first',
            frame: AsyncLoading<PreviewDifferenceFrame?>(),
            fileName: 'first.png',
            showCoordinates: true,
            useRgbSwatches: false,
            unavailableMessage: 'Difference preview unavailable.',
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('difference-preview-ready')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('difference-preview-loading')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'difference preview hides the error stats card when no frame is available',
    (tester) async {
      await tester.pumpWidget(
        _buildDifferencePreviewHost(
          child: const DifferencePreview(
            retentionScopeKey: 'first',
            frame: AsyncData<PreviewDifferenceFrame?>(null),
            fileName: 'first.png',
            showCoordinates: true,
            useRgbSwatches: false,
            unavailableMessage: 'Difference preview unavailable.',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('difference-preview-stats-card')),
        findsNothing,
      );
    },
  );

  testWidgets('difference preview shows deterministic error stats', (
    tester,
  ) async {
    final frame = await _differenceFrame(
      width: 5,
      height: 4,
      rgbaBytes: _rgbaBytesFromGrayscaleMeans(<int>[
        0,
        0,
        0,
        0,
        0,
        30,
        30,
        30,
        30,
        30,
        60,
        60,
        60,
        60,
        60,
        120,
        120,
        120,
        240,
        255,
      ]),
    );
    addTearDown(frame.image.dispose);

    await tester.pumpWidget(
      _buildDifferencePreviewHost(
        child: Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: DifferencePreview(
              retentionScopeKey: 'first',
              frame: AsyncData<PreviewDifferenceFrame?>(frame),
              fileName: 'first.png',
              showCoordinates: true,
              useRgbSwatches: false,
              unavailableMessage: 'Difference preview unavailable.',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('difference-preview-stats-card')),
      findsOneWidget,
    );
    expect(find.text('Mean'), findsOneWidget);
    expect(find.text('Top 10%'), findsOneWidget);
    expect(find.text('Top 1%'), findsOneWidget);
    expect(find.text('65.3'), findsOneWidget);
    expect(find.text('247.5'), findsOneWidget);
    expect(find.text('255.0'), findsOneWidget);
  });

  testWidgets('difference preview uses error stats from the raw image', (
    tester,
  ) async {
    final frame = await _differenceFrame(
      width: 2,
      height: 2,
      rgbaBytes: Uint8List(2 * 2 * 4),
      differenceStats: const RawImageDifferenceStats(
        mean: 2.3,
        top10Percent: 7.8,
        top1Percent: 9.1,
      ),
    );
    addTearDown(frame.image.dispose);

    await tester.pumpWidget(
      _buildDifferencePreviewHost(
        child: Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: DifferencePreview(
              retentionScopeKey: 'first',
              frame: AsyncData<PreviewDifferenceFrame?>(frame),
              fileName: 'first.png',
              showCoordinates: true,
              useRgbSwatches: false,
              unavailableMessage: 'Difference preview unavailable.',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2.3'), findsOneWidget);
    expect(find.text('7.8'), findsOneWidget);
    expect(find.text('9.1'), findsOneWidget);
  });

  testWidgets(
    'difference preview keeps the error stats card visible during retained loading',
    (tester) async {
      final firstFrame = await _differenceFrame(
        width: 2,
        height: 2,
        rgbaBytes: _rgbaBytesFromGrayscaleMeans(<int>[0, 0, 0, 255]),
      );
      addTearDown(firstFrame.image.dispose);

      Widget buildPreview(AsyncValue<PreviewDifferenceFrame?> frameValue) {
        return _buildDifferencePreviewHost(
          child: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: DifferencePreview(
                retentionScopeKey: 'first',
                frame: frameValue,
                fileName: 'first.png',
                showCoordinates: true,
                useRgbSwatches: false,
                unavailableMessage: 'Difference preview unavailable.',
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(
        buildPreview(AsyncData<PreviewDifferenceFrame?>(firstFrame)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('difference-preview-stats-card')),
        findsOneWidget,
      );
      expect(find.text('63.8'), findsOneWidget);

      await tester.pumpWidget(
        buildPreview(const AsyncLoading<PreviewDifferenceFrame?>()),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('difference-preview-stats-card')),
        findsOneWidget,
      );
      expect(find.text('63.8'), findsOneWidget);
    },
  );

  testWidgets(
    'difference preview updates the error stats card after a retained frame swap',
    (tester) async {
      final firstFrame = await _differenceFrame(
        width: 2,
        height: 2,
        rgbaBytes: _rgbaBytesFromGrayscaleMeans(<int>[0, 0, 0, 255]),
      );
      final secondFrame = await _differenceFrame(
        width: 2,
        height: 2,
        rgbaBytes: _rgbaBytesFromGrayscaleMeans(<int>[255, 255, 255, 255]),
      );
      addTearDown(firstFrame.image.dispose);
      addTearDown(secondFrame.image.dispose);

      Widget buildPreview(AsyncValue<PreviewDifferenceFrame?> frameValue) {
        return _buildDifferencePreviewHost(
          child: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: DifferencePreview(
                retentionScopeKey: 'first',
                frame: frameValue,
                fileName: 'first.png',
                showCoordinates: true,
                useRgbSwatches: false,
                unavailableMessage: 'Difference preview unavailable.',
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(
        buildPreview(AsyncData<PreviewDifferenceFrame?>(firstFrame)),
      );
      await tester.pumpAndSettle();
      expect(find.text('63.8'), findsOneWidget);

      await tester.pumpWidget(
        buildPreview(const AsyncLoading<PreviewDifferenceFrame?>()),
      );
      await tester.pumpAndSettle();
      expect(find.text('63.8'), findsOneWidget);

      await tester.pumpWidget(
        buildPreview(AsyncData<PreviewDifferenceFrame?>(secondFrame)),
      );
      await tester.pumpAndSettle();

      expect(find.text('255.0'), findsNWidgets(3));
      expect(find.text('63.8'), findsNothing);
    },
  );

  testWidgets(
    'difference preview shows RGB tooltip after one second of hover stillness',
    (tester) async {
      final frame = await _differenceFrame(
        width: 4,
        height: 4,
        rgbaBytes: _rgbaBytesForSinglePixel(
          width: 4,
          height: 4,
          pixelX: 2,
          pixelY: 2,
          red: 12,
          green: 34,
          blue: 56,
        ),
      );
      addTearDown(frame.image.dispose);

      await tester.pumpWidget(
        _buildDifferencePreviewHost(
          child: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: DifferencePreview(
                retentionScopeKey: 'first',
                frame: AsyncData<PreviewDifferenceFrame?>(frame),
                fileName: 'first.png',
                showCoordinates: true,
                useRgbSwatches: false,
                unavailableMessage: 'Difference preview unavailable.',
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final region = find.byKey(const ValueKey('difference-preview-region'));
      final center = tester.getCenter(region);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: center);
      await mouse.moveTo(center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 999));

      expect(
        find.byKey(const ValueKey('difference-preview-tooltip')),
        findsNothing,
      );

      await tester.pump(const Duration(milliseconds: 1));

      expect(find.text('x 2, y 2'), findsOneWidget);
      expect(find.text('R  12 G  34 B  56'), findsOneWidget);

      await mouse.moveTo(center + const Offset(10, 0));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('difference-preview-tooltip')),
        findsOneWidget,
      );
    },
  );

  testWidgets('difference preview context menu can hide tooltip coordinates', (
    tester,
  ) async {
    final frame = await _differenceFrame(
      width: 4,
      height: 4,
      rgbaBytes: _rgbaBytesForSinglePixel(
        width: 4,
        height: 4,
        pixelX: 2,
        pixelY: 2,
        red: 12,
        green: 34,
        blue: 56,
      ),
    );
    addTearDown(frame.image.dispose);

    var showCoordinates = true;
    var useRgbSwatches = false;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          return _buildDifferencePreviewHost(
            child: Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: DifferencePreview(
                  retentionScopeKey: 'first',
                  frame: AsyncData<PreviewDifferenceFrame?>(frame),
                  fileName: 'first.png',
                  showCoordinates: showCoordinates,
                  useRgbSwatches: useRgbSwatches,
                  onShowCoordinatesChanged: (value) {
                    setState(() {
                      showCoordinates = value;
                    });
                  },
                  onUseRgbSwatchesChanged: (value) {
                    setState(() {
                      useRgbSwatches = value;
                    });
                  },
                  unavailableMessage: 'Difference preview unavailable.',
                ),
              ),
            ),
          );
        },
      ),
    );
    await tester.pump();

    final region = find.byKey(const ValueKey('difference-preview-region'));
    final center = tester.getCenter(region);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: center);
    await mouse.moveTo(center);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('x 2, y 2'), findsOneWidget);
    expect(find.text('R  12 G  34 B  56'), findsOneWidget);

    await tester.tap(region, buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Show coordinates'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('difference-tooltip-coordinates-toggle')),
    );
    await tester.pumpAndSettle();

    expect(showCoordinates, isFalse);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await mouse.moveTo(center + const Offset(1, 0));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('R  12 G  34 B  56'), findsOneWidget);
    expect(find.textContaining('x 2, y 2'), findsNothing);
  });

  testWidgets(
    'difference preview context menu can use swatches for RGB labels',
    (tester) async {
      final frame = await _differenceFrame(
        width: 4,
        height: 4,
        rgbaBytes: _rgbaBytesForSinglePixel(
          width: 4,
          height: 4,
          pixelX: 2,
          pixelY: 2,
          red: 12,
          green: 34,
          blue: 56,
        ),
      );
      addTearDown(frame.image.dispose);

      var showCoordinates = true;
      var useRgbSwatches = false;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            return _buildDifferencePreviewHost(
              child: Center(
                child: SizedBox(
                  width: 200,
                  height: 200,
                  child: DifferencePreview(
                    retentionScopeKey: 'first',
                    frame: AsyncData<PreviewDifferenceFrame?>(frame),
                    fileName: 'first.png',
                    showCoordinates: showCoordinates,
                    useRgbSwatches: useRgbSwatches,
                    onShowCoordinatesChanged: (value) {
                      setState(() {
                        showCoordinates = value;
                      });
                    },
                    onUseRgbSwatchesChanged: (value) {
                      setState(() {
                        useRgbSwatches = value;
                      });
                    },
                    unavailableMessage: 'Difference preview unavailable.',
                  ),
                ),
              ),
            );
          },
        ),
      );
      await tester.pump();

      final region = find.byKey(const ValueKey('difference-preview-region'));
      final center = tester.getCenter(region);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: center);
      await mouse.moveTo(center);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('x 2, y 2'), findsOneWidget);
      expect(find.text('R  12 G  34 B  56'), findsOneWidget);

      await tester.tap(region, buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Use color swatches for RGB labels'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('difference-tooltip-swatches-toggle')),
      );
      await tester.pumpAndSettle();

      expect(useRgbSwatches, isTrue);

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await mouse.moveTo(center + const Offset(1, 0));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('x 2, y 2'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('difference-preview-tooltip-r-swatch')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('difference-preview-tooltip-g-swatch')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('difference-preview-tooltip-b-swatch')),
        findsOneWidget,
      );
      expect(find.text(' 12'), findsOneWidget);
      expect(find.text(' 34'), findsOneWidget);
      expect(find.text(' 56'), findsOneWidget);
      expect(find.textContaining('R  12'), findsNothing);
    },
  );

  testWidgets(
    'difference preview tooltip stays hidden over viewport background and hides on pan',
    (tester) async {
      final frame = await _differenceFrame(
        width: 4,
        height: 2,
        rgbaBytes: _rgbaBytesForSinglePixel(
          width: 4,
          height: 2,
          pixelX: 2,
          pixelY: 1,
          red: 80,
          green: 90,
          blue: 100,
        ),
      );
      addTearDown(frame.image.dispose);

      await tester.pumpWidget(
        _buildDifferencePreviewHost(
          child: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: DifferencePreview(
                retentionScopeKey: 'first',
                frame: AsyncData<PreviewDifferenceFrame?>(frame),
                fileName: 'first.png',
                showCoordinates: true,
                useRgbSwatches: false,
                unavailableMessage: 'Difference preview unavailable.',
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final region = find.byKey(const ValueKey('difference-preview-region'));
      final topLeft = tester.getTopLeft(region);
      final center = tester.getCenter(region);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: topLeft);
      await mouse.moveTo(topLeft + const Offset(100, 20));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.byKey(const ValueKey('difference-preview-tooltip')),
        findsNothing,
      );

      await mouse.moveTo(center);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('x 2, y 1'), findsOneWidget);
      expect(find.text('R  80 G  90 B 100'), findsOneWidget);

      await tester.drag(region, const Offset(20, 20));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('difference-preview-tooltip')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'difference preview tooltip updates after a retained frame swap',
    (tester) async {
      final firstFrame = await _differenceFrame(
        width: 4,
        height: 4,
        rgbaBytes: _rgbaBytesForSinglePixel(
          width: 4,
          height: 4,
          pixelX: 2,
          pixelY: 2,
          red: 10,
          green: 20,
          blue: 30,
        ),
      );
      final secondFrame = await _differenceFrame(
        width: 4,
        height: 4,
        rgbaBytes: _rgbaBytesForSinglePixel(
          width: 4,
          height: 4,
          pixelX: 2,
          pixelY: 2,
          red: 40,
          green: 50,
          blue: 60,
        ),
      );
      addTearDown(firstFrame.image.dispose);
      addTearDown(secondFrame.image.dispose);

      Widget buildPreview(AsyncValue<PreviewDifferenceFrame?> frameValue) {
        return _buildDifferencePreviewHost(
          child: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: DifferencePreview(
                retentionScopeKey: 'first',
                frame: frameValue,
                fileName: 'first.png',
                showCoordinates: true,
                useRgbSwatches: false,
                unavailableMessage: 'Difference preview unavailable.',
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(
        buildPreview(AsyncData<PreviewDifferenceFrame?>(firstFrame)),
      );
      await tester.pump();

      final region = find.byKey(const ValueKey('difference-preview-region'));
      final center = tester.getCenter(region);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: center);
      await mouse.moveTo(center);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('x 2, y 2'), findsOneWidget);
      expect(find.text('R  10 G  20 B  30'), findsOneWidget);

      await tester.pumpWidget(
        buildPreview(const AsyncLoading<PreviewDifferenceFrame?>()),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('difference-preview-ready')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('difference-preview-tooltip')),
        findsNothing,
      );

      await tester.pumpWidget(
        buildPreview(AsyncData<PreviewDifferenceFrame?>(secondFrame)),
      );
      await tester.pump();

      await mouse.moveTo(center + const Offset(1, 0));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('x 2, y 2'), findsOneWidget);
      expect(find.text('R  40 G  50 B  60'), findsOneWidget);
    },
  );

  testWidgets(
    'optimized preview size warning updates when an analyze sample is hovered',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 900)},
        previewDelay: const Duration(seconds: 5),
      )..analyzeSampleDelay = const Duration(milliseconds: 20);
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Original image is smaller.'), findsNothing);

      await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();

      final chart = tester.widget<LineChart>(find.byType(LineChart));
      final firstBar = chart.data.lineBarsData.first;
      final lastSpot = firstBar.spots.last;
      chart.data.lineTouchData.touchCallback?.call(
        FlPointerHoverEvent(const PointerHoverEvent(position: Offset.zero)),
        LineTouchResponse(
          touchLocation: Offset.zero,
          touchChartCoordinate: Offset.zero,
          lineBarSpots: [
            TouchLineBarSpot(firstBar, firstBar.spots.length - 1, lastSpot, 0),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Original image is smaller.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
    },
  );

  testWidgets('later openFiles event replaces the session', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final channel = _FakeFileOpenChannel();
    final slimg = _FakeSlimgApi(
      inspectResults: {
        '/tmp/original.png': _metadata('png', 2000),
        '/tmp/new-one.webp': _metadata('webp', 1200),
        '/tmp/new-two.bmp': _metadata('jpeg', 1600),
      },
    );
    final controller = FileOpenController(
      channel: channel,
      slimg: slimg,
      initialPaths: const ['/tmp/original.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();

    expect(find.text('original.png'), findsWidgets);

    await channel.emit(const ['/tmp/new-one.webp', '/tmp/new-two.bmp']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('new-one.webp'), findsWidgets);
    expect(find.text('new-two.bmp'), findsWidgets);
    expect(controller.currentPath, '/tmp/new-one.webp');
  });

  testWidgets(
    'folder rows open a collage and file selection returns to file view',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {
          '/tmp/animals/cat.png': _metadata('png', 2400),
          '/tmp/animals/dog.jpg': _metadata('jpeg', 1800),
          '/tmp/cars/road.png': _metadata('png', 900),
        },
      );
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const [
          '/tmp/animals/cat.png',
          '/tmp/animals/dog.jpg',
          '/tmp/cars/road.png',
        ],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(controller.currentPath, '/tmp/animals/cat.png');
      expect(find.text('4.1 KB'), findsOneWidget);

      await tester.tap(find.text('animals').first);
      await tester.pump();

      expect(controller.isFolderSelected, isTrue);
      expect(find.text('Loaded'), findsNothing);

      await tester.tap(find.text('dog.jpg').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(controller.currentPath, '/tmp/animals/dog.jpg');
      expect(controller.isFolderSelected, isFalse);
    },
  );

  testWidgets('folder summary aggregates original and optimized sizes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {
        '/tmp/animals/cat.png': _metadata('png', 2400),
        '/tmp/animals/dog.jpg': _metadata('jpeg', 1800),
        '/tmp/animals/cat.optimized.jpeg': _metadata('jpeg', 900),
      },
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/animals/cat.png', '/tmp/animals/dog.jpg'],
    );
    await controller.initialize();
    await controller.applyProcessResults([
      BatchItemResult(
        inputPath: '/tmp/animals/cat.png',
        success: true,
        result: ProcessResult(
          outputPath: '/tmp/animals/cat.optimized.jpeg',
          format: 'jpeg',
          width: 48,
          height: 32,
          originalSize: BigInt.from(2400),
          newSize: BigInt.from(900),
          didWrite: true,
        ),
      ),
    ]);

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('animals').first);
    await tester.pumpAndSettle();

    expect(find.text('4.1 KB'), findsOneWidget);
    expect(find.text('2.6 KB'), findsWidgets);
    expect(find.text('35.7%'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('JPEG'), findsWidgets);

    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('savings tile toggles between percent and ratio', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('50.0%'), findsOneWidget);
    expect(find.text('2.0x'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('bottom-stat-Savings')));
    await tester.pump();

    expect(find.text('2.0x'), findsOneWidget);
    expect(find.text('50.0%'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('bottom-stat-Savings')));
    await tester.pump();

    expect(find.text('50.0%'), findsOneWidget);
  });

  testWidgets('similarity tile toggles colors from the context menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = _FakeAppSettingsStore();
    final slimg =
        _FakeSlimgApi(
            inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
          )
          ..pixelMatchValue = 90.0
          ..msSsimValue = 0.5
          ..ssimulacra2Value = 30.0;
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(
      _buildApp(controller: controller, slimg: slimg, store: store),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final initialColor = _bottomStatValueText(
      tester,
      label: 'Similarity',
      value: '56.7%',
    ).style?.color;

    await tester.tap(
      find.byKey(const ValueKey('bottom-stat-Similarity')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Enable similarity colors'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('bottom-stat-similarity-colors-toggle')),
    );
    await tester.pumpAndSettle();

    final settings = AppSettings.fromJsonString((await store.read())!);
    expect(settings.similarityMetricColorsEnabled, isTrue);

    final updatedColor = _bottomStatValueText(
      tester,
      label: 'Similarity',
      value: '56.7%',
    ).style?.color;
    expect(updatedColor, isNotNull);
    expect(updatedColor, isNot(equals(initialColor)));
  });

  testWidgets('savings tile toggles colors from the context menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = _FakeAppSettingsStore();
    final slimg =
        _FakeSlimgApi(
            inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
          )
          ..pixelMatchValue = 90.0
          ..msSsimValue = 0.5
          ..ssimulacra2Value = 30.0;
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(
      _buildApp(controller: controller, slimg: slimg, store: store),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final initialColor = _bottomStatValueText(
      tester,
      label: 'Savings',
      value: '50.0%',
    ).style?.color;

    await tester.tap(
      find.byKey(const ValueKey('bottom-stat-Savings')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Enable savings colors'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('bottom-stat-savings-colors-toggle')),
    );
    await tester.pumpAndSettle();

    final settings = AppSettings.fromJsonString((await store.read())!);
    expect(settings.savingsColorsEnabled, isTrue);

    final percentColor = _bottomStatValueText(
      tester,
      label: 'Savings',
      value: '50.0%',
    ).style?.color;
    expect(percentColor, isNotNull);
    expect(percentColor, isNot(equals(initialColor)));

    await tester.tap(find.byKey(const ValueKey('bottom-stat-Savings')));
    await tester.pump();

    final ratioColor = _bottomStatValueText(
      tester,
      label: 'Savings',
      value: '2.0x',
    ).style?.color;
    expect(ratioColor, equals(percentColor));
  });

  testWidgets('bits per pixel rows toggle colors from the context menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = _FakeAppSettingsStore();
    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(
      _buildApp(controller: controller, slimg: slimg, store: store),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final initialOriginalColor = _bottomInfoValueText(
      tester,
      key: 'original-bpp-value',
    ).style?.color;
    final initialOptimizedColor = _bottomInfoValueText(
      tester,
      key: 'optimized-bpp-value',
    ).style?.color;

    await tester.tap(
      find.byKey(const ValueKey('original-bpp-row')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Enable bits per pixel colors'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('bottom-info-bpp-colors-toggle')),
    );
    await tester.pumpAndSettle();

    final settings = AppSettings.fromJsonString((await store.read())!);
    expect(settings.bitsPerPixelColorsEnabled, isTrue);

    final updatedOriginalColor = _bottomInfoValueText(
      tester,
      key: 'original-bpp-value',
    ).style?.color;
    final updatedOptimizedColor = _bottomInfoValueText(
      tester,
      key: 'optimized-bpp-value',
    ).style?.color;
    expect(updatedOriginalColor, isNot(equals(initialOriginalColor)));
    expect(updatedOptimizedColor, isNot(equals(initialOptimizedColor)));

    await tester.tap(
      find.byKey(const ValueKey('optimized-bpp-row')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Disable bits per pixel colors'), findsOneWidget);
  });

  testWidgets('folder mode bits per pixel rows honor the shared color toggle', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = _FakeAppSettingsStore();
    final slimg = _FakeSlimgApi(
      inspectResults: {
        '/tmp/animals/cat.png': _metadata('png', 2400),
        '/tmp/animals/dog.png': _metadata('jpeg', 1800),
      },
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/animals/cat.png', '/tmp/animals/dog.png'],
    );
    await controller.initialize();
    controller.showFolder('/tmp/animals');

    await tester.pumpWidget(
      _buildApp(controller: controller, slimg: slimg, store: store),
    );
    await tester.pumpAndSettle();

    final initialOptimizedColor = _bottomInfoValueText(
      tester,
      key: 'optimized-bpp-value',
    ).style?.color;

    await tester.tap(
      find.byKey(const ValueKey('optimized-bpp-row')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('bottom-info-bpp-colors-toggle')),
    );
    await tester.pumpAndSettle();

    expect(
      _bottomInfoValueText(tester, key: 'original-bpp-value').style?.color,
      isNotNull,
    );
    expect(
      _bottomInfoValueText(tester, key: 'optimized-bpp-value').style?.color,
      isNot(equals(initialOptimizedColor)),
    );
  });

  testWidgets(
    'file size tiles toggle colors from their own context menu in file mode',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = _FakeAppSettingsStore();
      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      );
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(
        _buildApp(controller: controller, slimg: slimg, store: store),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final initialOriginalColor = _bottomStatValueText(
        tester,
        label: 'Original',
        value: '2.3 KB',
      ).style?.color;
      final initialOptimizedColor = _bottomStatValueText(
        tester,
        label: 'Optimized',
        value: '1.2 KB',
      ).style?.color;

      await tester.tap(
        find.byKey(const ValueKey('bottom-stat-Original')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Enable file size colors'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('bottom-stat-file-size-colors-toggle')),
      );
      await tester.pumpAndSettle();

      final settings = AppSettings.fromJsonString((await store.read())!);
      expect(settings.fileSizeColorsEnabled, isTrue);
      expect(settings.bitsPerPixelColorsEnabled, isFalse);

      expect(
        _bottomStatValueText(
          tester,
          label: 'Original',
          value: '2.3 KB',
        ).style?.color,
        isNot(equals(initialOriginalColor)),
      );
      expect(
        _bottomStatValueText(
          tester,
          label: 'Optimized',
          value: '1.2 KB',
        ).style?.color,
        isNot(equals(initialOptimizedColor)),
      );
    },
  );

  testWidgets(
    'file size tiles toggle colors from their own context menu in folder mode',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = _FakeAppSettingsStore();
      final slimg = _FakeSlimgApi(
        inspectResults: {
          '/tmp/animals/cat.png': _metadata('png', 2400),
          '/tmp/animals/dog.png': _metadata('jpeg', 1800),
        },
      );
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/animals/cat.png', '/tmp/animals/dog.png'],
      );
      await controller.initialize();
      controller.showFolder('/tmp/animals');

      await tester.pumpWidget(
        _buildApp(controller: controller, slimg: slimg, store: store),
      );
      await tester.pumpAndSettle();

      final initialOriginalColor = _bottomStatValueText(
        tester,
        label: 'Original',
        value: '4.1 KB',
      ).style?.color;
      final initialOptimizedColor = _bottomStatValueText(
        tester,
        label: 'Optimized',
        value: '4.1 KB',
      ).style?.color;

      await tester.tap(
        find.byKey(const ValueKey('bottom-stat-Optimized')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Enable file size colors'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('bottom-stat-file-size-colors-toggle')),
      );
      await tester.pumpAndSettle();

      expect(
        _bottomStatValueText(
          tester,
          label: 'Original',
          value: '4.1 KB',
        ).style?.color,
        isNot(equals(initialOriginalColor)),
      );
      expect(
        _bottomStatValueText(
          tester,
          label: 'Optimized',
          value: '4.1 KB',
        ).style?.color,
        isNot(equals(initialOptimizedColor)),
      );
    },
  );

  testWidgets('bits per pixel and file size color toggles are independent', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = _FakeAppSettingsStore();
    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(
      _buildApp(controller: controller, slimg: slimg, store: store),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final initialBppColor = _bottomInfoValueText(
      tester,
      key: 'original-bpp-value',
    ).style?.color;
    final initialFileSizeColor = _bottomStatValueText(
      tester,
      label: 'Original',
      value: '2.3 KB',
    ).style?.color;

    await tester.tap(
      find.byKey(const ValueKey('original-bpp-row')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('bottom-info-bpp-colors-toggle')),
    );
    await tester.pumpAndSettle();

    expect(
      _bottomInfoValueText(tester, key: 'original-bpp-value').style?.color,
      isNot(equals(initialBppColor)),
    );
    expect(
      _bottomStatValueText(
        tester,
        label: 'Original',
        value: '2.3 KB',
      ).style?.color,
      equals(initialFileSizeColor),
    );

    await tester.tap(
      find.byKey(const ValueKey('bottom-stat-Original')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('bottom-stat-file-size-colors-toggle')),
    );
    await tester.pumpAndSettle();

    final settings = AppSettings.fromJsonString((await store.read())!);
    expect(settings.bitsPerPixelColorsEnabled, isTrue);
    expect(settings.fileSizeColorsEnabled, isTrue);
  });

  testWidgets('unavailable bits per pixel values stay neutral when enabled', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = _FakeAppSettingsStore();
    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', null)},
      previewDelay: const Duration(seconds: 5),
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(
      _buildApp(controller: controller, slimg: slimg, store: store),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(_bottomInfoValueText(tester, key: 'original-bpp-value').data, '—');

    final initialOriginalColor = _bottomInfoValueText(
      tester,
      key: 'original-bpp-value',
    ).style?.color;

    await tester.tap(
      find.byKey(const ValueKey('original-bpp-row')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('bottom-info-bpp-colors-toggle')),
    );
    await tester.pumpAndSettle();

    expect(
      _bottomInfoValueText(tester, key: 'original-bpp-value').style?.color,
      equals(initialOriginalColor),
    );
  });

  testWidgets('toggles advanced mode in the settings sidebar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();

    expect(find.text('Lossless'), findsOneWidget);
    expect(find.text('Lossy'), findsOneWidget);
    expect(find.text('Compatibility'), findsOneWidget);
    expect(find.text('Efficiency'), findsOneWidget);
    expect(find.text('Quality'), findsWidgets);
    expect(find.text('80'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.text('PNG'), findsWidgets);
    expect(find.text('WebP'), findsOneWidget);
    expect(find.text('AVIF'), findsOneWidget);
    expect(find.text('JPEG XL'), findsOneWidget);

    await tester.tap(find.text('PNG').first);
    await tester.pumpAndSettle();

    expect(find.text('Quality'), findsOneWidget);
  });

  testWidgets(
    'optimized format value bolds briefly when codec choice changes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      );
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(_optimizedFormatValueText(tester).data, 'JPEG');
      expect(
        _optimizedFormatValueText(tester).style?.fontWeight,
        FontWeight.w500,
      );

      await tester.tap(find.text('Efficiency').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(_optimizedFormatValueText(tester).data, 'AVIF');
      expect(
        _optimizedFormatValueText(tester).style?.fontWeight,
        isNot(equals(FontWeight.w500)),
      );

      await tester.pump(const Duration(milliseconds: 200));
    },
  );

  testWidgets('optimize all uses mixed slimg requests', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {
        '/tmp/first.png': _metadata('png', 2400),
        '/tmp/second.jpg': _metadata('jpeg', 1800),
        '/tmp/first.jpeg': _metadata('jpeg', 900),
      },
      batchDelay: const Duration(milliseconds: 1),
    );
    final channel = _FakeFileOpenChannel();
    final controller = FileOpenController(
      channel: channel,
      slimg: slimg,
      initialPaths: const ['/tmp/first.png', '/tmp/second.jpg'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('Optimize'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    final batch = slimg.lastBatchRequest!;
    expect(channel.lastWritableDirectoryPaths, ['/tmp']);
    expect(batch.requests.length, 2);
    expect(batch.requests[0].outputPath, '/tmp/first.jpeg');
    expect(batch.requests[1].outputPath, isNull);
    batch.requests[0].operation.when(
      convert: (options) => expect(options.targetFormat, 'jpeg'),
      optimize: (_) => fail('expected convert for png -> jpeg'),
      resize: (_) => fail('unexpected resize'),
      crop: (_) => fail('unexpected crop'),
      extend: (_) => fail('unexpected extend'),
    );
    batch.requests[1].operation.when(
      convert: (_) => fail('expected optimize for jpeg source'),
      optimize: (_) {},
      resize: (_) => fail('unexpected resize'),
      crop: (_) => fail('unexpected crop'),
      extend: (_) => fail('unexpected extend'),
    );
  });

  testWidgets('cancel stops queued files after the active item finishes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {
        '/tmp/first.png': _metadata('png', 2400),
        '/tmp/second.png': _metadata('png', 2200),
        '/tmp/third.png': _metadata('png', 2000),
        '/tmp/first.jpeg': _metadata('jpeg', 900),
        '/tmp/second.jpeg': _metadata('jpeg', 850),
      },
      batchDelay: const Duration(seconds: 1),
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const [
        '/tmp/first.png',
        '/tmp/second.png',
        '/tmp/third.png',
      ],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const ValueKey('optimize-action-idle')));
    await tester.pump();

    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('0/3'), findsOneWidget);
    expect(find.text('0:00/--:--'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(find.text('Canceling...'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('optimize button keeps success state after completion', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {
        '/tmp/first.jpg': _metadata('jpeg', 2400),
        '/tmp/second.jpg': _metadata('jpeg', 1800),
      },
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.jpg', '/tmp/second.jpg'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('Optimize'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Success!'), findsOneWidget);
    expect(find.text('Optimize'), findsNothing);

    await tester.pump(const Duration(milliseconds: 1100));

    expect(find.text('Success!'), findsOneWidget);
    expect(find.text('Optimize'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'same-folder optimize stops when save-folder access is canceled',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = _FakeAppSettingsStore()
        ..value = AppSettings.defaults
            .copyWith(
              sameFolderAccesses: const [
                StoredDirectoryAccess(
                  path: '/tmp/old',
                  bookmark: 'old-bookmark',
                ),
              ],
            )
            .toJsonString();
      final channel = _FakeFileOpenChannel()
        ..writableDirectoryAccessResult = false
        ..writablePersistentAccessesResult = const [
          SecurityScopedFileAccess(
            path: '/tmp/refreshed',
            bookmark: 'refreshed-bookmark',
          ),
        ];
      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      );
      final controller = FileOpenController(
        channel: channel,
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(
        _buildApp(controller: controller, slimg: slimg, store: store),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('Optimize'));
      await tester.pump();

      expect(channel.lastWritableDirectoryPaths, ['/tmp']);
      expect(channel.lastWritablePersistentAccesses, hasLength(1));
      expect(
        channel.lastWritablePersistentAccesses!.single.bookmark,
        'old-bookmark',
      );
      final persistedSettings = AppSettings.fromJsonString(
        (await store.read())!,
      );
      expect(persistedSettings.sameFolderAccesses, const [
        StoredDirectoryAccess(
          path: '/tmp/refreshed',
          bookmark: 'refreshed-bookmark',
        ),
      ]);
      expect(slimg.lastBatchRequest, isNull);
      expect(find.text('Choose the save folder to continue.'), findsOneWidget);
      expect(find.text('Success!'), findsNothing);
    },
  );

  testWidgets('completed batch with a failed item does not show success', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      batchFailurePaths: const {'/tmp/first.png'},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('Optimize'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Success!'), findsNothing);
    expect(find.text('Optimize'), findsOneWidget);
    expect(find.text('Some images could not be saved.'), findsOneWidget);
  });

  testWidgets('developer dialog toggles persisted timing logs', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = _FakeAppSettingsStore();
    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(
      _buildApp(controller: controller, slimg: slimg, store: store),
    );
    await tester.pump();

    await tester.tap(find.byIcon(LucideIcons.wrench));
    await tester.pumpAndSettle();

    expect(find.text('Developer'), findsOneWidget);
    expect(find.text('Timing logs'), findsOneWidget);
    expect(slimg.lastTimingLogsEnabled, isFalse);

    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('developer-home-shader-speed-field')),
      '0.25',
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.ancestor(
        of: find.text('Flipper'),
        matching: find.byType(RadioItem<BottomStatAnimationMode>),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.ancestor(
        of: find.text('Acrylic panel'),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.ancestor(
        of: find.text('Timing logs'),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.ancestor(
        of: find.text('Caption buttons on macOS'),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pumpAndSettle();

    expect(slimg.lastTimingLogsEnabled, isTrue);
    expect(store.value, contains('"developerModeEnabled":true'));
    expect(store.value, contains('"timingLogsEnabled":true'));
    expect(store.value, contains('"macOsCaptionButtonsEnabled":true'));
    expect(store.value, contains('"homeShaderSpeed":0.25'));
    expect(store.value, contains('"homeAcrylicPanelEnabled":true'));
    expect(store.value, contains('"bottomStatAnimationMode":"flipper"'));
  });

  testWidgets('title bar keeps developer left of home and settings', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    final developerPosition = tester.getTopLeft(
      find.byKey(const ValueKey('title-bar-developer-button')),
    );
    final homePosition = tester.getTopLeft(
      find.byKey(const ValueKey('title-bar-home-button')),
    );
    final settingsPosition = tester.getTopLeft(
      find.byKey(const ValueKey('title-bar-settings-button')),
    );

    expect(developerPosition.dx, lessThan(homePosition.dx));
    expect(homePosition.dx, lessThan(settingsPosition.dx));
  });

  testWidgets('title bar hides the home button on the empty state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi();
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('title-bar-home-button')), findsNothing);
    expect(
      find.byKey(const ValueKey('title-bar-settings-button')),
      findsOneWidget,
    );
  });

  testWidgets('title bar developer controls match build distribution', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => DeveloperDiagnostics.setTimingLogsEnabled(false));

    final store = _FakeAppSettingsStore()
      ..value = AppSettings.defaults
          .copyWith(
            developerModeEnabled: true,
            timingLogsEnabled: true,
            previewPathHeaderEnabled: true,
          )
          .toJsonString();
    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(
      _buildApp(controller: controller, slimg: slimg, store: store),
    );
    await tester.pumpAndSettle();

    final developerButton = find.byKey(
      const ValueKey('title-bar-developer-button'),
    );
    expect(developerButton, isStoreBuild ? findsNothing : findsOneWidget);
    expect(slimg.lastTimingLogsEnabled, !isStoreBuild);
    expect(find.text('/tmp'), isStoreBuild ? findsNothing : findsOneWidget);

    if (isStoreBuild) {
      return;
    }

    await tester.tap(developerButton);
    await tester.pumpAndSettle();

    expect(find.text('Developer'), findsOneWidget);
  });

  testWidgets('title bar home button returns to the empty state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    var scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    var appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(scaffold.floatingHeader, isFalse);
    expect(appBar.surfaceOpacity, isNull);
    expect(appBar.surfaceBlur, isNull);
    expect(find.text('first.png'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('title-bar-home-button')));
    await tester.pumpAndSettle();

    scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(scaffold.floatingHeader, isTrue);
    expect(appBar.surfaceOpacity, 0.10);
    expect(appBar.surfaceBlur, 4);
    expect(find.text('Optimize images easily'), findsOneWidget);
    expect(find.text('first.png'), findsNothing);
  });

  testWidgets('title bar home button is disabled while optimizing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {
        '/tmp/first.png': _metadata('png', 2400),
        '/tmp/first.jpeg': _metadata('jpeg', 900),
      },
      batchDelay: const Duration(seconds: 1),
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('optimize-action-idle')));
    await tester.pump();

    final homeButton = tester.widget<GhostButton>(
      find.byKey(const ValueKey('title-bar-home-button')),
    );
    expect(homeButton.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('title-bar-home-button')));
    await tester.pump();

    expect(find.text('first.png'), findsWidgets);
    expect(find.text('Optimize images easily'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('title bar settings menu cycles persisted theme preference', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = _FakeAppSettingsStore();
    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(
      _buildApp(controller: controller, slimg: slimg, store: store),
    );
    await tester.pumpAndSettle();

    final settingsButton = find.byKey(
      const ValueKey('title-bar-settings-button'),
    );

    await tester.tap(settingsButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('title-bar-settings-label')),
      findsOneWidget,
    );
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('System'), findsNothing);
    expect(find.text('Color'), findsOneWidget);
    expect(find.text('Slate'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('title-bar-community-label')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('title-bar-bug-tracker-button')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('title-bar-blog-button')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('title-bar-app-name-label')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('title-bar-version-label')),
      findsOneWidget,
    );
    expect(find.text('v0.1.2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('title-bar-donate-button')),
      const bool.fromEnvironment('OIMG_MAS_BUILD')
          ? findsNothing
          : findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('title-bar-contributors-button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('title-bar-theme-toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('title-bar-theme-toggle')),
      findsOneWidget,
    );
    expect(find.text('Light'), findsNothing);
    expect(
      AppSettings.fromJsonString((await store.read())!).themePreference,
      AppThemePreference.light,
    );

    await tester.tap(
      find.byKey(const ValueKey('title-bar-color-scheme-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Zinc'), findsOneWidget);
    expect(
      AppSettings.fromJsonString((await store.read())!).colorSchemePreference,
      AppColorSchemePreference.zinc,
    );

    await tester.tap(find.byKey(const ValueKey('title-bar-theme-toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('title-bar-theme-toggle')),
      findsOneWidget,
    );
    expect(find.text('Dark'), findsNothing);
    expect(
      AppSettings.fromJsonString((await store.read())!).themePreference,
      AppThemePreference.dark,
    );

    await tester.tap(find.byKey(const ValueKey('title-bar-theme-toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('title-bar-theme-toggle')),
      findsOneWidget,
    );
    expect(find.text('System'), findsNothing);
    expect(
      AppSettings.fromJsonString((await store.read())!).themePreference,
      AppThemePreference.system,
    );
  });

  testWidgets('stored color scheme preference maps to app color schemes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> pumpWithColorScheme(
      AppColorSchemePreference colorSchemePreference,
    ) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      final store = _FakeAppSettingsStore()
        ..value = AppSettings.defaults
            .copyWith(colorSchemePreference: colorSchemePreference)
            .toJsonString();
      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      );
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();
      await tester.pumpWidget(
        _buildApp(controller: controller, slimg: slimg, store: store),
      );
      await tester.pumpAndSettle();
    }

    await pumpWithColorScheme(AppColorSchemePreference.zinc);
    expect(
      tester.widget<ShadcnApp>(find.byType(ShadcnApp)).theme.colorScheme,
      ColorSchemes.lightZinc,
    );
    expect(
      tester.widget<ShadcnApp>(find.byType(ShadcnApp)).darkTheme?.colorScheme,
      ColorSchemes.darkZinc,
    );

    await pumpWithColorScheme(AppColorSchemePreference.stone);
    expect(
      tester.widget<ShadcnApp>(find.byType(ShadcnApp)).theme.colorScheme,
      ColorSchemes.lightStone,
    );
    expect(
      tester.widget<ShadcnApp>(find.byType(ShadcnApp)).darkTheme?.colorScheme,
      ColorSchemes.darkStone,
    );
  });

  testWidgets('stored theme preference maps to app theme mode', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> pumpWithTheme(AppThemePreference themePreference) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      final store = _FakeAppSettingsStore()
        ..value = AppSettings.defaults
            .copyWith(themePreference: themePreference)
            .toJsonString();
      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.png': _metadata('png', 2400)},
      );
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.png'],
      );
      await controller.initialize();
      await tester.pumpWidget(
        _buildApp(controller: controller, slimg: slimg, store: store),
      );
      await tester.pumpAndSettle();
    }

    await pumpWithTheme(AppThemePreference.light);
    expect(
      tester.widget<ShadcnApp>(find.byType(ShadcnApp)).themeMode,
      ThemeMode.light,
    );

    await pumpWithTheme(AppThemePreference.dark);
    expect(
      tester.widget<ShadcnApp>(find.byType(ShadcnApp)).themeMode,
      ThemeMode.dark,
    );

    await pumpWithTheme(AppThemePreference.system);
    expect(
      tester.widget<ShadcnApp>(find.byType(ShadcnApp)).themeMode,
      ThemeMode.system,
    );
  });

  testWidgets(
    'lossless preview shows the source image while estimating in background',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = _FakeAppSettingsStore()
        ..value = const AppSettings(
          compressionMethod: CompressionMethod.lossless,
          compressionPriority: CompressionPriority.compatibility,
          advancedMode: false,
          preferredCodec: PreferredCodec.jpeg,
          quality: 80,
          storageDestinationMode: StorageDestinationMode.sameFolder,
          sameFolderAction: SameFolderAction.replaceSource,
          preserveFolderStructure: true,
          preserveOriginalDate: false,
          preserveExif: false,
          preserveColorProfile: false,
          developerModeEnabled: false,
          timingLogsEnabled: false,
        ).toJsonString();
      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.jpg': _metadata('jpeg', 2400)},
      );
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.jpg'],
      );
      await controller.initialize();

      await tester.pumpWidget(
        _buildApp(controller: controller, slimg: slimg, store: store),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Estimating'), findsNothing);
      expect(slimg.previewCallCount, 1);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
    },
  );

  testWidgets(
    'difference stays unavailable for non-advanced lossless jpeg xl mode',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = _FakeAppSettingsStore()
        ..value = const AppSettings(
          compressionMethod: CompressionMethod.lossless,
          compressionPriority: CompressionPriority.efficiency,
          advancedMode: false,
          preferredCodec: PreferredCodec.jpeg,
          quality: 80,
          storageDestinationMode: StorageDestinationMode.sameFolder,
          sameFolderAction: SameFolderAction.replaceSource,
          preserveFolderStructure: true,
          preserveOriginalDate: false,
          preserveExif: false,
          preserveColorProfile: false,
          developerModeEnabled: false,
          timingLogsEnabled: false,
        ).toJsonString();
      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/first.jpg': _metadata('jpeg', 2400)},
      );
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/first.jpg'],
      );
      await controller.initialize();

      await tester.pumpWidget(
        _buildApp(controller: controller, slimg: slimg, store: store),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(slimg.previewCallCount, 1);
      expect(slimg.differenceCallCount, 0);

      await tester.tap(find.byKey(const ValueKey('preview-mode-Difference')));
      await tester.pump();

      expect(slimg.differenceCallCount, 0);
    },
  );

  testWidgets('hovering the quality slider shows and updates the value label', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.jpg': _metadata('jpeg', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.jpg'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(1, 1));

    await mouse.moveTo(_qualitySliderOffset(tester, fraction: 0.2));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('quality-slider-hover-value')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('quality-slider-hover-opacity')),
          )
          .opacity,
      0,
    );

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(
      _qualitySliderHoverText(tester),
      _expectedQualityHoverValue(tester, fraction: 0.2).toString(),
    );
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('quality-slider-hover-opacity')),
          )
          .opacity,
      1,
    );

    await mouse.moveTo(_qualitySliderOffset(tester, fraction: 0.8));
    await tester.pump();

    expect(
      _qualitySliderHoverText(tester),
      _expectedQualityHoverValue(tester, fraction: 0.8).toString(),
    );

    await mouse.moveTo(const Offset(1, 1));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('quality-slider-hover-value')),
      findsNothing,
    );
  });

  testWidgets('dragging the quality slider keeps the value label visible', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.jpg': _metadata('jpeg', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.jpg'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(1, 1));

    final start = _qualitySliderValueOffset(tester, value: 80);
    final end = _qualitySliderValueOffset(tester, value: 55);
    await mouse.moveTo(start);
    await tester.pump();
    await mouse.down(start);
    await tester.pump();
    await mouse.moveTo(end);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('quality-slider-hover-value')),
      findsOneWidget,
    );

    await mouse.up();
    await tester.pump();
  });

  testWidgets('locked quality controls do not show the hover value label', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/first.jpg': _metadata('jpeg', 2400)},
      batchDelay: const Duration(milliseconds: 400),
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/first.jpg'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Optimize'));
    await tester.pump();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(1, 1));
    await mouse.moveTo(_qualitySliderOffset(tester, fraction: 0.5));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('quality-slider-hover-value')),
      findsNothing,
    );

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  });

  testWidgets('storage section shows picker-driven different-location flow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 680));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final channel = _FakeFileOpenChannel()..pickFolderResult = ['/tmp/export'];
    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/source.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: channel,
      slimg: slimg,
      initialPaths: const ['/tmp/source.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pumpAndSettle();

    final scrollFinder = find.byKey(const ValueKey('settings-scroll-view'));
    final settingsScrollable = find.descendant(
      of: scrollFinder,
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('Storage'),
      120,
      scrollable: settingsScrollable,
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('Metadata'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Storage')).dy,
      lessThan(tester.getTopLeft(find.text('Metadata')).dy),
    );

    final storageHeader = find
        .ancestor(of: find.text('Storage'), matching: find.byType(Row))
        .first;
    await tester.tap(
      find.descendant(of: storageHeader, matching: find.byIcon(Icons.add)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Remove original'), findsOneWidget);
    expect(find.text('Keep original'), findsOneWidget);
    expect(find.text('Rename optimized'), findsNothing);
    expect(find.text('Preserve folder structure'), findsNothing);

    final differentLocationFinder = find.byKey(
      const ValueKey('storage-destination-differentLocation'),
    );
    await tester.scrollUntilVisible(
      differentLocationFinder,
      120,
      scrollable: settingsScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(differentLocationFinder);
    await tester.pumpAndSettle();

    expect(channel.pickFolderCallCount, 1);
    expect(find.text('/tmp/export'), findsOneWidget);
    expect(find.text('Preserve folder structure'), findsOneWidget);

    channel.pickFolderResult = const <String>[];
    await tester.scrollUntilVisible(
      differentLocationFinder,
      120,
      scrollable: settingsScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(differentLocationFinder);
    await tester.pumpAndSettle();

    expect(channel.pickFolderCallCount, 2);
    expect(find.text('/tmp/export'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MyApp)),
    );
    await container
        .read(appSettingsProvider.notifier)
        .setStorageDestinationMode(StorageDestinationMode.sameFolder);
    await container
        .read(appSettingsProvider.notifier)
        .setSameFolderAction(SameFolderAction.keepSource);
    await tester.pumpAndSettle();

    expect(find.text('Rename optimized'), findsOneWidget);
    expect(find.text('Rename original'), findsOneWidget);
    expect(find.text('Suffix'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('keep-source-suffix-renameOptimized')),
          )
          .initialValue,
      '_optimized',
    );

    await container
        .read(appSettingsProvider.notifier)
        .setKeepSourceNaming(KeepSourceNaming.renameOriginal);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('keep-source-suffix-renameOriginal')),
          )
          .initialValue,
      '_original',
    );
  });

  testWidgets(
    'storage and metadata fold into the settings scroll view when analyze constrains height',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 680));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/source.png': _metadata('png', 2400)},
      )..analyzeSampleDelay = const Duration(milliseconds: 20);
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/source.png'],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();

      final scrollFinder = find.byKey(const ValueKey('settings-scroll-view'));
      final storageFinder = find.text('Storage');
      final metadataFinder = find.text('Metadata');

      final storageTopBefore = tester.getTopLeft(storageFinder).dy;
      final metadataTopBefore = tester.getTopLeft(metadataFinder).dy;

      await tester.drag(scrollFinder, const Offset(0, -180));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(storageFinder).dy,
        lessThan(storageTopBefore - 20),
      );
      expect(
        tester.getTopLeft(metadataFinder).dy,
        lessThan(metadataTopBefore - 20),
      );
    },
  );

  testWidgets(
    'storage same-folder label shows overwrite for same-format files',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final slimg = _FakeSlimgApi(
        inspectResults: {'/tmp/source.jpg': _metadata('jpeg', 2400)},
      );
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: slimg,
        initialPaths: const ['/tmp/source.jpg'],
      );
      await controller.initialize();

      await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add).first);
      await tester.pumpAndSettle();

      expect(find.text('Overwrite'), findsOneWidget);
      expect(find.text('Remove original'), findsNothing);
    },
  );

  testWidgets('metadata section toggles preserve original date', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = _FakeAppSettingsStore();
    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/source.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/source.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(
      _buildApp(controller: controller, slimg: slimg, store: store),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('metadata-collapsible-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('Preserve original date'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('metadata-preserve-original-date')),
    );
    await tester.pumpAndSettle();

    final settings = AppSettings.fromJsonString((await store.read())!);
    expect(settings.preserveOriginalDate, isTrue);
  });

  testWidgets('metadata section toggles color profile and exif', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = _FakeAppSettingsStore();
    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/source.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/source.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(
      _buildApp(controller: controller, slimg: slimg, store: store),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('metadata-collapsible-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('Preserve color profile'), findsOneWidget);
    expect(find.text('Preserve camera info (EXIF)'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('metadata-preserve-color-profile')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('metadata-preserve-exif')));
    await tester.pumpAndSettle();

    final settings = AppSettings.fromJsonString((await store.read())!);
    expect(settings.preserveColorProfile, isTrue);
    expect(settings.preserveExif, isTrue);
  });

  testWidgets('quality section toggles metric colors from the settings menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = _FakeAppSettingsStore();
    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/source.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/source.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(
      _buildApp(controller: controller, slimg: slimg, store: store),
    );
    await tester.pumpAndSettle();

    final initialMetricText = tester.widget<Text>(find.text('98.7%').first);
    final initialMetricColor = initialMetricText.style?.color;

    await tester.tap(
      find.byKey(const ValueKey('quality-metric-colors-button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Enable metric colors'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('quality-metric-colors-toggle')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quality-metric-colors-toggle')),
      findsOneWidget,
    );
    expect(find.text('Disable metric colors'), findsOneWidget);

    final settings = AppSettings.fromJsonString((await store.read())!);
    expect(settings.qualityMetricColorsEnabled, isTrue);

    final metricText = tester.widget<Text>(find.text('98.7%').first);
    expect(metricText.style?.color, isNotNull);
    expect(metricText.style?.color, isNot(equals(initialMetricColor)));
  });

  testWidgets('quality metrics show colored legend dots', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final slimg = _FakeSlimgApi(
      inspectResults: {'/tmp/source.png': _metadata('png', 2400)},
    );
    final controller = FileOpenController(
      channel: _FakeFileOpenChannel(),
      slimg: slimg,
      initialPaths: const ['/tmp/source.png'],
    );
    await controller.initialize();

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('metric-legend-dot-Pixel Match')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('metric-legend-dot-MS-SSIM')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('metric-legend-dot-SSIMULACRA 2')),
      findsNothing,
    );

    await tester.tap(find.widgetWithText(OutlineButton, 'Analyze'));
    await tester.pump();
    await tester.pumpAndSettle();

    final pixelMatchDot = tester.widget<Container>(
      find.byKey(const ValueKey('metric-legend-dot-Pixel Match')),
    );
    final msSsimDot = tester.widget<Container>(
      find.byKey(const ValueKey('metric-legend-dot-MS-SSIM')),
    );
    final ssimulacra2Dot = tester.widget<Container>(
      find.byKey(const ValueKey('metric-legend-dot-SSIMULACRA 2')),
    );

    expect(
      (pixelMatchDot.decoration! as BoxDecoration).color,
      const Color(0xFF06B6D4),
    );
    expect(
      (msSsimDot.decoration! as BoxDecoration).color,
      const Color(0xFFD946EF),
    );
    expect(
      (ssimulacra2Dot.decoration! as BoxDecoration).color,
      const Color(0xFFEAB308),
    );
  });

  testWidgets('folder collage supports show-in-file-manager context menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final channel = _FakeFileOpenChannel();
    final slimg = _FakeSlimgApi(
      inspectResults: {
        '/tmp/animals/cat.png': _metadata('png', 2400),
        '/tmp/animals/dog.png': _metadata('png', 2200),
      },
    );
    final controller = FileOpenController(
      channel: channel,
      slimg: slimg,
      initialPaths: const ['/tmp/animals/cat.png', '/tmp/animals/dog.png'],
    );
    await controller.initialize();
    controller.showFolder('/tmp/animals');

    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    final tileFinder = find.byKey(
      const ValueKey('folder-collage-tile-/tmp/animals/cat.png'),
    );
    final menuLabel = _showInFileManagerMenuLabel();

    await tester.tap(tileFinder, buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text(menuLabel), findsOneWidget);

    await tester.tap(find.text(menuLabel));
    await tester.pumpAndSettle();

    expect(channel.shownPaths, ['/tmp/animals/cat.png']);

    await tester.tap(tileFinder);
    await tester.pumpAndSettle();

    expect(controller.currentPath, '/tmp/animals/cat.png');
    expect(controller.isFolderSelected, isFalse);
    expect(channel.shownPaths, ['/tmp/animals/cat.png']);
    expect(find.text(menuLabel), findsNothing);
  });

  testWidgets('explorer sidebar supports show-in-file-manager context menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final channel = _FakeFileOpenChannel();
    final slimg = _FakeSlimgApi(
      inspectResults: {
        '/tmp/animals/cat.png': _metadata('png', 2400),
        '/tmp/animals/dog.png': _metadata('png', 2200),
      },
    );
    final controller = FileOpenController(
      channel: channel,
      slimg: slimg,
      initialPaths: const ['/tmp/animals/cat.png', '/tmp/animals/dog.png'],
    );
    await controller.initialize();
    await tester.pumpWidget(_buildApp(controller: controller, slimg: slimg));
    await tester.pumpAndSettle();

    final folderItemFinder = find.byKey(
      const ValueKey('explorer-item-/tmp/animals'),
    );
    final fileItemFinder = find.byKey(
      const ValueKey('explorer-item-/tmp/animals/cat.png'),
    );
    final menuLabel = _showInFileManagerMenuLabel();

    await tester.tap(folderItemFinder, buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text(menuLabel), findsOneWidget);

    await tester.tap(find.text(menuLabel));
    await tester.pumpAndSettle();

    expect(channel.shownPaths, ['/tmp/animals']);

    await tester.tap(fileItemFinder, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(menuLabel));
    await tester.pumpAndSettle();

    expect(channel.shownPaths, ['/tmp/animals', '/tmp/animals/cat.png']);
  });
}

Widget _buildApp({
  required FileOpenController controller,
  required _FakeSlimgApi slimg,
  AppSettingsStore? store,
  Future<PreviewDifferenceFrame?> Function()? differenceFrameBuilder,
}) {
  return ProviderScope(
    overrides: [
      slimgApiProvider.overrideWithValue(slimg),
      fileOpenControllerProvider.overrideWith((ref) => controller),
      appSettingsRepositoryProvider.overrideWithValue(
        AppSettingsRepository(store: store ?? _FakeAppSettingsStore()),
      ),
      if (differenceFrameBuilder != null)
        currentPreviewDifferenceFrameProvider.overrideWith(
          (ref) => differenceFrameBuilder(),
        ),
    ],
    child: const MyApp(),
  );
}

Widget _buildDifferencePreviewHost({required Widget child}) {
  return ProviderScope(
    child: ShadcnApp(home: Scaffold(child: child)),
  );
}

Future<PreviewDifferenceFrame> _differenceFrame({
  required int width,
  required int height,
  required Uint8List rgbaBytes,
  RawImageDifferenceStats? differenceStats,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  return PreviewDifferenceFrame(
    image: image,
    rawImage: RawImageResult(
      rgbaBytes: rgbaBytes,
      width: width,
      height: height,
      differenceStats: differenceStats,
    ),
  );
}

Uint8List _rgbaBytesForSinglePixel({
  required int width,
  required int height,
  required int pixelX,
  required int pixelY,
  required int red,
  required int green,
  required int blue,
}) {
  final bytes = Uint8List(width * height * 4);
  final index = (pixelY * width + pixelX) * 4;
  bytes[index] = red;
  bytes[index + 1] = green;
  bytes[index + 2] = blue;
  bytes[index + 3] = 255;
  return bytes;
}

Uint8List _rgbaBytesFromGrayscaleMeans(List<int> values) {
  final bytes = Uint8List(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    final value = values[i];
    final byteIndex = i * 4;
    bytes[byteIndex] = value;
    bytes[byteIndex + 1] = value;
    bytes[byteIndex + 2] = value;
    bytes[byteIndex + 3] = 255;
  }
  return bytes;
}

ImageMetadata _metadata(
  String format,
  int? bytes, {
  bool hasTransparency = false,
}) {
  return ImageMetadata(
    width: 48,
    height: 32,
    format: format,
    fileSize: bytes == null ? null : BigInt.from(bytes),
    hasTransparency: hasTransparency,
  );
}

String _showInFileManagerMenuLabel() {
  if (Platform.isMacOS) {
    return 'Show in Finder';
  }
  if (Platform.isWindows) {
    return 'Show in File Explorer';
  }
  return 'Show in File Manager';
}

Finder _similarityTileFinder() {
  return find.byKey(const ValueKey('bottom-stat-Similarity'));
}

Finder _similarityValueFinder(String value) {
  return find.descendant(
    of: _similarityTileFinder(),
    matching: find.text(value),
  );
}

Finder _similarityLoadingFinder() {
  return find.descendant(
    of: _similarityTileFinder(),
    matching: find.byType(CircularProgressIndicator),
  );
}

Finder _similarityApproximateValueFinder() {
  return find.descendant(
    of: _similarityTileFinder(),
    matching: find.byWidgetPredicate((widget) {
      return widget is Text &&
          widget.data != null &&
          widget.data!.startsWith('~') &&
          widget.data!.endsWith('%');
    }),
  );
}

Finder _qualitySliderFinder() {
  return find.byKey(const ValueKey('quality-slider'));
}

Offset _qualitySliderOffset(WidgetTester tester, {required double fraction}) {
  final rect = tester.getRect(_qualitySliderFinder());
  return Offset(rect.left + rect.width * fraction, rect.top + 8);
}

Offset _qualitySliderValueOffset(WidgetTester tester, {required int value}) {
  final rect = tester.getRect(_qualitySliderFinder());
  final context = tester.element(_qualitySliderFinder());
  final theme = Theme.of(context);
  final trackInset = theme.density.baseGap * theme.scaling * 0.5;
  final trackWidth = rect.width - trackInset * 2;
  return Offset(
    rect.left + trackInset + trackWidth * (value / 100),
    rect.top + 8,
  );
}

int _expectedQualityHoverValue(
  WidgetTester tester, {
  required double fraction,
}) {
  final context = tester.element(_qualitySliderFinder());
  final theme = Theme.of(context);
  final width = tester.getSize(_qualitySliderFinder()).width;
  final trackInset = theme.density.baseGap * theme.scaling * 0.5;
  final trackWidth = width - trackInset * 2;
  final dx = width * fraction;
  final normalized = ((dx - trackInset) / trackWidth).clamp(0.0, 1.0);
  return (normalized * 100).round();
}

String _qualitySliderHoverText(WidgetTester tester) {
  return tester
          .widget<Text>(
            find.byKey(const ValueKey('quality-slider-hover-value')),
          )
          .data ??
      '';
}

Text _bottomStatValueText(
  WidgetTester tester, {
  required String label,
  required String value,
}) {
  return tester.widget<Text>(
    find.descendant(
      of: find.byKey(ValueKey('bottom-stat-$label')),
      matching: find.text(value),
    ),
  );
}

String _bottomStatDisplayValue(WidgetTester tester, {required String label}) {
  final values = tester
      .widgetList<Text>(
        find.descendant(
          of: find.byKey(ValueKey('bottom-stat-$label')),
          matching: find.byType(Text),
        ),
      )
      .map((text) => text.data)
      .whereType<String>()
      .where((value) => value != label)
      .toList();
  return values.last;
}

Text _optimizedFormatValueText(WidgetTester tester) {
  return tester.widget<Text>(
    find.byKey(const ValueKey('optimized-format-value')),
  );
}

Text _bottomInfoValueText(WidgetTester tester, {required String key}) {
  return tester.widget<Text>(find.byKey(ValueKey(key)));
}

class _FakeFileOpenChannel implements FileOpenChannel {
  OpenFilesHandler? _handler;
  List<String> pickFilesResult = const <String>[];
  List<String> pickFolderResult = const <String>[];
  final List<String> shownPaths = <String>[];
  int pickFilesCallCount = 0;
  int pickFolderCallCount = 0;
  String? lastStartedSecurityScopedBookmark;
  List<String>? lastWritableDirectoryPaths;
  List<SecurityScopedFileAccess>? lastWritablePersistentAccesses;
  bool writableDirectoryAccessResult = true;
  List<SecurityScopedFileAccess>? writablePersistentAccessesResult;

  @override
  Future<void> bind(OpenFilesHandler onOpenFiles) async {
    _handler = onOpenFiles;
  }

  Future<void> emit(List<String> paths) async {
    await _handler?.call(paths);
  }

  @override
  Future<List<String>> pickFiles() async {
    pickFilesCallCount += 1;
    return pickFilesResult;
  }

  @override
  Future<List<String>> pickFolder() async {
    pickFolderCallCount += 1;
    return pickFolderResult;
  }

  @override
  Future<SecurityScopedFileAccess?> pickFolderForPersistentAccess() async {
    final paths = await pickFolder();
    if (paths.isEmpty) {
      return null;
    }
    return SecurityScopedFileAccess(path: paths.first, bookmark: 'bookmark');
  }

  @override
  Future<bool> startAccessingSecurityScopedResource(String bookmark) async {
    lastStartedSecurityScopedBookmark = bookmark;
    return true;
  }

  @override
  Future<WritableDirectoryAccessResult> ensureWritableDirectoryAccess(
    List<String> paths, {
    List<SecurityScopedFileAccess> persistentAccesses =
        const <SecurityScopedFileAccess>[],
  }) async {
    lastWritableDirectoryPaths = paths;
    lastWritablePersistentAccesses = persistentAccesses;
    return WritableDirectoryAccessResult(
      didStartAccess: writableDirectoryAccessResult,
      persistentAccesses:
          writablePersistentAccessesResult ?? persistentAccesses,
    );
  }

  @override
  Future<void> showInFileManager(String path) async {
    shownPaths.add(path);
  }
}

class _FakeAppSettingsStore implements AppSettingsStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}

class _FakeSlimgApi implements SlimgApi {
  _FakeSlimgApi({
    Map<String, ImageMetadata>? inspectResults,
    this.previewDelay = Duration.zero,
    this.batchDelay = Duration.zero,
    this.batchFailurePaths = const <String>{},
  }) : inspectResults = inspectResults ?? {};

  final Map<String, ImageMetadata> inspectResults;
  final Duration previewDelay;
  final Duration batchDelay;
  final Set<String> batchFailurePaths;
  ProcessFileBatchRequest? lastBatchRequest;
  bool lastTimingLogsEnabled = false;
  int previewCallCount = 0;
  int differenceCallCount = 0;
  int pixelMatchCallCount = 0;
  int msSsimCallCount = 0;
  int ssimulacra2CallCount = 0;
  final List<String> disposedPreviewArtifactIds = <String>[];
  int _nextJobId = 0;
  int _nextAnalyzeJobId = 0;
  final Map<String, _FakeBatchJob> _jobs = {};
  final Map<String, _FakeAnalyzeJob> _analyzeJobs = {};

  int get analyzeJobCount => _analyzeJobs.length;

  static final Uint8List _previewBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4////fwAJ+wP9KobjigAAAABJRU5ErkJggg==',
  );

  @override
  Future<ImageMetadata> inspectFile({required String inputPath}) async {
    final result = inspectResults[inputPath];
    if (result == null) {
      throw StateError('unsupported');
    }
    return result;
  }

  @override
  void setTimingLogsEnabled({required bool enabled}) {
    lastTimingLogsEnabled = enabled;
  }

  @override
  Future<PreviewResult> previewFile({
    required PreviewFileRequest request,
  }) async {
    previewCallCount += 1;
    if (previewDelay > Duration.zero) {
      await Future<void>.delayed(previewDelay);
    }
    final artifactSuffix = request.inputPath.replaceAll(
      RegExp(r'[^a-zA-Z0-9]+'),
      '-',
    );
    return PreviewResult(
      encodedBytes: _previewBytes,
      artifactId: 'preview-artifact-$previewCallCount-$artifactSuffix',
      format: 'jpeg',
      width: 48,
      height: 32,
      sizeBytes: BigInt.from(previewSizeBytes),
      sourceHasTransparency:
          inspectResults[request.inputPath]?.hasTransparency ?? false,
    );
  }

  Duration pixelMatchDelay = Duration.zero;
  Duration msSsimDelay = Duration.zero;
  Duration ssimulacra2Delay = Duration.zero;
  Duration differenceDelay = Duration.zero;
  Duration analyzeSampleDelay = Duration.zero;
  double? pixelMatchValue = 98.7;
  double? msSsimValue = 0.9874;
  double? ssimulacra2Value = 92.4;
  int previewSizeBytes = 1200;

  @override
  Future<double?> computePreviewPixelMatchPercentage({
    required PreviewArtifactRequest request,
  }) async {
    pixelMatchCallCount += 1;
    if (pixelMatchDelay > Duration.zero) {
      await Future<void>.delayed(pixelMatchDelay);
    }
    return pixelMatchValue;
  }

  @override
  Future<double?> computePreviewMsSsim({
    required PreviewArtifactRequest request,
  }) async {
    msSsimCallCount += 1;
    if (msSsimDelay > Duration.zero) {
      await Future<void>.delayed(msSsimDelay);
    }
    return msSsimValue;
  }

  @override
  Future<double?> computePreviewSsimulacra2({
    required PreviewArtifactRequest request,
  }) async {
    ssimulacra2CallCount += 1;
    if (ssimulacra2Delay > Duration.zero) {
      await Future<void>.delayed(ssimulacra2Delay);
    }
    return ssimulacra2Value;
  }

  @override
  Future<RawImageResult?> computePreviewDifferenceImage({
    required PreviewArtifactRequest request,
  }) async {
    differenceCallCount += 1;
    if (differenceDelay > Duration.zero) {
      await Future<void>.delayed(differenceDelay);
    }
    return RawImageResult(
      rgbaBytes: Uint8List(48 * 32 * 4),
      width: 48,
      height: 32,
      differenceStats: const RawImageDifferenceStats(
        mean: 0,
        top10Percent: 0,
        top1Percent: 0,
      ),
    );
  }

  @override
  Future<void> disposePreviewArtifact({required String artifactId}) async {
    disposedPreviewArtifactIds.add(artifactId);
  }

  @override
  Future<ProcessResult> processFile({required ProcessFileRequest request}) {
    throw UnimplementedError();
  }

  @override
  Future<List<BatchItemResult>> processFileBatch({
    required ProcessFileBatchRequest request,
  }) async {
    lastBatchRequest = request;
    if (batchDelay > Duration.zero) {
      await Future<void>.delayed(batchDelay);
    }
    return request.requests
        .map((item) {
          final outputPath = item.outputPath ?? item.inputPath;
          return BatchItemResult(
            inputPath: item.inputPath,
            success: true,
            result: ProcessResult(
              outputPath: outputPath,
              format: outputPath.endsWith('.jpeg') ? 'jpeg' : 'jpeg',
              width: 48,
              height: 32,
              originalSize: BigInt.from(2400),
              newSize: BigInt.from(900),
              didWrite: true,
            ),
          );
        })
        .toList(growable: false);
  }

  @override
  Future<BatchJobHandle> startProcessFileBatchJob({
    required ProcessFileBatchRequest request,
  }) async {
    lastBatchRequest = request;
    final jobId = 'job-${++_nextJobId}';
    final snapshot = BatchJobSnapshot(
      jobId: jobId,
      state: BatchJobState.running,
      totalCount: request.requests.length,
      completedCount: 0,
      results: const [],
    );
    final job = _FakeBatchJob(snapshot: snapshot);
    _jobs[jobId] = job;
    unawaited(_runJob(jobId, request));
    return BatchJobHandle(jobId: jobId);
  }

  @override
  Future<BatchJobSnapshot> getProcessFileBatchJob({
    required String jobId,
  }) async {
    final job = _jobs[jobId];
    if (job == null) {
      throw StateError('unknown job');
    }
    return job.snapshot;
  }

  @override
  Future<void> cancelProcessFileBatchJob({required String jobId}) async {
    final job = _jobs[jobId];
    if (job == null) {
      throw StateError('unknown job');
    }
    job.cancelRequested = true;
    if (job.snapshot.state == BatchJobState.running) {
      job.snapshot = BatchJobSnapshot(
        jobId: job.snapshot.jobId,
        state: BatchJobState.cancelRequested,
        totalCount: job.snapshot.totalCount,
        completedCount: job.snapshot.completedCount,
        currentInputPath: job.snapshot.currentInputPath,
        results: job.snapshot.results,
        error: job.snapshot.error,
      );
    }
  }

  @override
  Future<void> disposeProcessFileBatchJob({required String jobId}) async {
    _jobs.remove(jobId);
  }

  @override
  Future<AnalyzeFileJobHandle> startAnalyzeFileJob({
    required AnalyzeFileRequest request,
  }) async {
    final jobId = 'analyze-${++_nextAnalyzeJobId}';
    final snapshot = AnalyzeFileJobSnapshot(
      jobId: jobId,
      state: BatchJobState.running,
      totalCount: request.qualities.length,
      completedCount: 0,
      results: const [],
    );
    final job = _FakeAnalyzeJob(snapshot: snapshot);
    _analyzeJobs[jobId] = job;
    unawaited(_runAnalyzeJob(jobId, request));
    return AnalyzeFileJobHandle(jobId: jobId);
  }

  @override
  Future<AnalyzeFileJobSnapshot> getAnalyzeFileJob({
    required String jobId,
  }) async {
    final job = _analyzeJobs[jobId];
    if (job == null) {
      throw StateError('unknown analyze job');
    }
    return job.snapshot;
  }

  @override
  Future<void> cancelAnalyzeFileJob({required String jobId}) async {
    final job = _analyzeJobs[jobId];
    if (job == null) {
      throw StateError('unknown analyze job');
    }
    job.cancelRequested = true;
    if (job.snapshot.state == BatchJobState.running) {
      job.snapshot = AnalyzeFileJobSnapshot(
        jobId: job.snapshot.jobId,
        state: BatchJobState.cancelRequested,
        totalCount: job.snapshot.totalCount,
        completedCount: job.snapshot.completedCount,
        currentQuality: job.snapshot.currentQuality,
        results: job.snapshot.results,
        error: job.snapshot.error,
      );
    }
  }

  @override
  Future<void> disposeAnalyzeFileJob({required String jobId}) async {
    _analyzeJobs.remove(jobId);
  }

  Future<void> _runJob(String jobId, ProcessFileBatchRequest request) async {
    final job = _jobs[jobId];
    if (job == null) {
      return;
    }

    for (final item in request.requests) {
      if (job.cancelRequested) {
        job.snapshot = BatchJobSnapshot(
          jobId: job.snapshot.jobId,
          state: BatchJobState.canceled,
          totalCount: job.snapshot.totalCount,
          completedCount: job.snapshot.completedCount,
          results: job.snapshot.results,
          error: job.snapshot.error,
        );
        return;
      }

      job.snapshot = BatchJobSnapshot(
        jobId: job.snapshot.jobId,
        state: job.cancelRequested
            ? BatchJobState.cancelRequested
            : BatchJobState.running,
        totalCount: job.snapshot.totalCount,
        completedCount: job.snapshot.completedCount,
        currentInputPath: item.inputPath,
        results: job.snapshot.results,
        error: job.snapshot.error,
      );

      if (batchDelay > Duration.zero) {
        await Future<void>.delayed(batchDelay);
      }

      final shouldFail = batchFailurePaths.contains(item.inputPath);
      final result = shouldFail
          ? BatchItemResult(inputPath: item.inputPath, success: false)
          : BatchItemResult(
              inputPath: item.inputPath,
              success: true,
              result: ProcessResult(
                outputPath: item.outputPath ?? item.inputPath,
                format: 'jpeg',
                width: 48,
                height: 32,
                originalSize: BigInt.from(2400),
                newSize: BigInt.from(900),
                didWrite: true,
              ),
            );
      final results = List<BatchItemResult>.from(job.snapshot.results)
        ..add(result);

      job.snapshot = BatchJobSnapshot(
        jobId: job.snapshot.jobId,
        state: job.cancelRequested
            ? BatchJobState.cancelRequested
            : BatchJobState.running,
        totalCount: job.snapshot.totalCount,
        completedCount: results.length,
        results: results,
        error: job.snapshot.error,
      );
    }

    job.snapshot = BatchJobSnapshot(
      jobId: job.snapshot.jobId,
      state: BatchJobState.completed,
      totalCount: job.snapshot.totalCount,
      completedCount: job.snapshot.completedCount,
      results: job.snapshot.results,
      error: job.snapshot.error,
    );
  }

  Future<void> _runAnalyzeJob(String jobId, AnalyzeFileRequest request) async {
    final job = _analyzeJobs[jobId];
    if (job == null) {
      return;
    }

    for (final quality in request.qualities) {
      if (job.cancelRequested) {
        job.snapshot = AnalyzeFileJobSnapshot(
          jobId: job.snapshot.jobId,
          state: BatchJobState.canceled,
          totalCount: job.snapshot.totalCount,
          completedCount: job.snapshot.completedCount,
          results: job.snapshot.results,
          error: job.snapshot.error,
        );
        return;
      }

      job.snapshot = AnalyzeFileJobSnapshot(
        jobId: job.snapshot.jobId,
        state: job.cancelRequested
            ? BatchJobState.cancelRequested
            : BatchJobState.running,
        totalCount: job.snapshot.totalCount,
        completedCount: job.snapshot.completedCount,
        currentQuality: quality,
        results: job.snapshot.results,
        error: job.snapshot.error,
      );

      if (analyzeSampleDelay > Duration.zero) {
        await Future<void>.delayed(analyzeSampleDelay);
      }

      final results = List<AnalyzeSampleResult>.from(job.snapshot.results)
        ..add(
          AnalyzeSampleResult(
            quality: quality,
            tempOutputPath: '/tmp/analyze-$quality.jpeg',
            encodedBytes: _previewBytes,
            format: 'jpeg',
            width: 48,
            height: 32,
            sizeBytes: BigInt.from(1500 - (quality * 8)),
            pixelMatch: (80 + quality / 5).clamp(0, 100).toDouble(),
            msSsim: (0.7 + quality / 400).clamp(0, 1).toDouble(),
            ssimulacra2: (65 + quality / 3).clamp(0, 100).toDouble(),
            artifactId: 'analyze-artifact-$quality',
          ),
        );

      job.snapshot = AnalyzeFileJobSnapshot(
        jobId: job.snapshot.jobId,
        state: job.cancelRequested
            ? BatchJobState.cancelRequested
            : BatchJobState.running,
        totalCount: job.snapshot.totalCount,
        completedCount: results.length,
        currentQuality: quality,
        results: results,
        error: job.snapshot.error,
      );
    }

    job.snapshot = AnalyzeFileJobSnapshot(
      jobId: job.snapshot.jobId,
      state: BatchJobState.completed,
      totalCount: job.snapshot.totalCount,
      completedCount: job.snapshot.completedCount,
      results: job.snapshot.results,
      error: job.snapshot.error,
    );
  }
}

class _FakeBatchJob {
  _FakeBatchJob({required this.snapshot});

  BatchJobSnapshot snapshot;
  bool cancelRequested = false;
}

class _FakeAnalyzeJob {
  _FakeAnalyzeJob({required this.snapshot});

  AnalyzeFileJobSnapshot snapshot;
  bool cancelRequested = false;
}
