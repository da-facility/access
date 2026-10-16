import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/glinet/access_book_api.dart';
import 'package:flutter_hbb/glinet/kvm_profile.dart';

void main() {
  test('account KVM passwords are isolated by server and account', () {
    const profile = KvmProfile(
        id: 'one', name: 'KVM', address: 'https://kvm.example', model: 'RM4PE');
    final alice = AccessBookApi('https://book.example', 'unused')
      ..owner = 'alice';
    final bob = AccessBookApi('https://book.example', 'unused')..owner = 'bob';
    final otherServer = AccessBookApi('https://other.example', 'unused')
      ..owner = 'alice';
    final key = alice.sessionProfile(profile).credentialKey;
    expect(key, isNot(profile.credentialKey));
    expect(key, isNot(bob.sessionProfile(profile).credentialKey));
    expect(key, isNot(otherServer.sessionProfile(profile).credentialKey));
    expect(alice.sessionProfile(profile).model, 'RM4PE');
    expect(alice.sessionProfile(profile).address, profile.address);
  });
}
