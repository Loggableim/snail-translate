import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snail/models/user_identity.dart';
import 'package:snail/services/user_identity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.snail.audio/method');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('rejects an empty peer key before invoking native code', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    expect(await UserIdentityService().deriveSharedSecret('  '), isNull);
    expect(calls, isEmpty);
  });

  test('forwards the device agreement public key request', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'peer-key';
    });

    expect(
        await UserIdentityService().getDeviceAgreementPublicKey(), 'peer-key');
    expect(calls.single.method, 'getDeviceAgreementPublicKey');
  });

  test('includes the agreement key in the contact QR payload', () {
    const identity = UserIdentity(
      userId: 'user-1',
      username: 'Alice',
      publicKey: 'signing-key',
      agreementPublicKey: 'agreement-key',
    );

    final restored = UserIdentity.fromJson(identity.toJson());
    expect(restored.agreementPublicKey, 'agreement-key');
    expect(Uri.parse(identity.qrPayload).queryParameters['agree'],
        'agreement-key');
  });
}
