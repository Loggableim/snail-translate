import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/models/snail_contact.dart';
import 'package:snail/services/contact_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ContactService.addFromQr', () {
    test('adds a scanned identity as a pending contact', () async {
      final service = ContactService();
      addTearDown(service.dispose);

      final added = await service.addFromQr(
          'snail://user/device-a?name=Alice');

      expect(added, isTrue);
      expect(service.contacts, hasLength(1));
      expect(service.contacts.single.userId, 'device-a');
      expect(service.contacts.single.username, 'Alice');
      // A scanned contact is a request, not an accepted relationship.
      expect(service.contacts.single.isPending, isTrue);
      expect(service.pendingRequests, hasLength(1));
    });

    test('rejects scanning your own QR code', () async {
      final service = ContactService();
      addTearDown(service.dispose);

      // Scanning your own code used to create a pending contact with your own
      // id, which the other side can never accept — the list then looked
      // broken with a request that could never resolve.
      final added = await service.addFromQr(
        'snail://user/device-self?name=Me',
        ownUserId: 'device-self',
      );

      expect(added, isFalse);
      expect(service.contacts, isEmpty);
    });

    test('accepts the same identity scanned twice without duplicating',
        () async {
      final service = ContactService();
      addTearDown(service.dispose);

      await service.addFromQr('snail://user/device-a?name=Alice');
      final again = await service.addFromQr('snail://user/device-a?name=Alice');

      expect(again, isTrue);
      expect(service.contacts, hasLength(1));
    });

    test('rejects a payload that is not a Snail identity', () async {
      final service = ContactService();
      addTearDown(service.dispose);

      expect(await service.addFromQr('https://example.com'), isFalse);
      expect(await service.addFromQr('snail://room/ABCD'), isFalse);
      expect(await service.addFromQr(''), isFalse);
      expect(service.contacts, isEmpty);
    });

    test('keeps the agreement key so the conversation can be encrypted',
        () async {
      final service = ContactService();
      addTearDown(service.dispose);

      await service.addFromQr(
          'snail://user/device-a?name=Alice&agree=key-a');

      expect(service.contacts.single.agreementPublicKey, 'key-a');
    });

    test('accept and reject move a pending contact out of the request list',
        () async {
      final service = ContactService();
      addTearDown(service.dispose);

      await service.addFromQr('snail://user/device-a?name=Alice');
      await service.addFromQr('snail://user/device-b?name=Bob');

      final alice = service.contacts.firstWhere((c) => c.userId == 'device-a');
      final bob = service.contacts.firstWhere((c) => c.userId == 'device-b');
      await service.accept(alice);
      await service.reject(bob);

      expect(service.pendingRequests, isEmpty);
      expect(service.acceptedContacts.map((c) => c.userId), ['device-a']);
      expect(
        service.contacts.firstWhere((c) => c.userId == 'device-b').status,
        ContactStatus.rejected,
      );
    });

    test('blocking hides a contact from the active list', () async {
      final service = ContactService();
      addTearDown(service.dispose);

      await service.addFromQr('snail://user/device-a?name=Alice');
      final alice = service.contacts.single;
      await service.block(alice);

      expect(service.contacts.single.isBlocked, isTrue);
      expect(service.acceptedContacts, isEmpty);
      expect(service.isBlocked('device-a'), isTrue);
    });
  });
}
