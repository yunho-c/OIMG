import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oimg/src/file_open/file_open_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('oimg/file_open');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('pickFiles parses path lists from the native channel', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'pickFiles');
          return <String>['/tmp/a.png', '/tmp/b.jpg'];
        });

    final fileOpenChannel = MethodChannelFileOpenChannel(channel: channel);

    final paths = await fileOpenChannel.pickFiles();

    expect(paths, ['/tmp/a.png', '/tmp/b.jpg']);
  });

  test('pickFolder parses path lists from the native channel', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'pickFolder');
          return <String>['/tmp/folder'];
        });

    final fileOpenChannel = MethodChannelFileOpenChannel(channel: channel);

    final paths = await fileOpenChannel.pickFolder();

    expect(paths, ['/tmp/folder']);
  });

  test('pickFolderForPersistentAccess parses path and bookmark', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'pickFolderForPersistentAccess');
          return <String, String>{
            'path': '/tmp/folder',
            'bookmark': 'bookmark-data',
          };
        });

    final fileOpenChannel = MethodChannelFileOpenChannel(channel: channel);

    final access = await fileOpenChannel.pickFolderForPersistentAccess();

    expect(access?.path, '/tmp/folder');
    expect(access?.bookmark, 'bookmark-data');
  });

  test(
    'pickFolderForPersistentAccess does not fall back after cancel',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'pickFolderForPersistentAccess') {
              return null;
            }
            fail('Unexpected method call: ${call.method}');
          });

      final fileOpenChannel = MethodChannelFileOpenChannel(channel: channel);

      final access = await fileOpenChannel.pickFolderForPersistentAccess();

      expect(access, isNull);
      expect(calls, ['pickFolderForPersistentAccess']);
    },
  );

  test('startAccessingSecurityScopedResource forwards bookmark', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'startAccessingSecurityScopedResource');
          expect(call.arguments, 'bookmark-data');
          return true;
        });

    final fileOpenChannel = MethodChannelFileOpenChannel(channel: channel);

    final didStart = await fileOpenChannel.startAccessingSecurityScopedResource(
      'bookmark-data',
    );

    expect(didStart, isTrue);
  });

  test('ensureWritableDirectoryAccess forwards and parses bookmarks', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'ensureWritableDirectoryAccess');
          expect(call.arguments, {
            'paths': ['/tmp/images', '/tmp/archive'],
            'accesses': [
              {'path': '/tmp/old', 'bookmark': 'old-bookmark'},
            ],
          });
          return <String, Object>{
            'didStartAccess': true,
            'accesses': <Object>[
              <String, String>{
                'path': '/tmp/images',
                'bookmark': 'new-bookmark',
              },
            ],
          };
        });

    final fileOpenChannel = MethodChannelFileOpenChannel(channel: channel);

    final result = await fileOpenChannel.ensureWritableDirectoryAccess(
      const ['/tmp/images', '/tmp/archive'],
      persistentAccesses: const [
        SecurityScopedFileAccess(path: '/tmp/old', bookmark: 'old-bookmark'),
      ],
    );

    expect(result.didStartAccess, isTrue);
    expect(result.persistentAccesses, hasLength(1));
    expect(result.persistentAccesses.single.path, '/tmp/images');
    expect(result.persistentAccesses.single.bookmark, 'new-bookmark');
  });

  test(
    'ensureWritableDirectoryAccess tolerates unsupported platforms',
    () async {
      final fileOpenChannel = MethodChannelFileOpenChannel(channel: channel);

      final result = await fileOpenChannel.ensureWritableDirectoryAccess(
        const ['/tmp/images'],
        persistentAccesses: const [
          SecurityScopedFileAccess(
            path: '/tmp/images',
            bookmark: 'bookmark-data',
          ),
        ],
      );

      expect(result.didStartAccess, isTrue);
      expect(result.persistentAccesses.single.bookmark, 'bookmark-data');
    },
  );
}
