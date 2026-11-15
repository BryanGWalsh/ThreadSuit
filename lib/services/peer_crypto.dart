import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The cryptography for pairing two copies of Thread Suit, and for the
/// traffic between them once paired. Nothing here touches the network.
///
/// **Pairing** is a key exchange (X25519) checked by a 6-digit code that both
/// screens show. The computer that starts pairing first sends only a hash of
/// its public key ([commit]) and reveals the key after it has the other one,
/// so someone in the middle can't try many keys until the two codes match:
/// they get one guess in a million.
///
/// **Traffic** between paired computers is sealed with AES-256-GCM under the
/// key the exchange made ([seal], [open]): nobody else on the network can
/// read it, change it or send messages as one of them.
class PeerCrypto {
  static final _x25519 = X25519();
  static final _aes = AesGcm.with256bits();
  static final _sha = Sha256();

  static Future<SimpleKeyPair> newKeyPair() => _x25519.newKeyPair();

  static Future<List<int>> publicKey(SimpleKeyPair pair) async => (await pair.extractPublicKey()).bytes;

  /// The hash the starting computer sends before revealing [publicKey].
  static Future<String> commit(List<int> publicKey) async => base64Encode((await _sha.hash(publicKey)).bytes);

  static Future<bool> checkCommit(String commitment, List<int> publicKey) async =>
      commitment == await commit(publicKey);

  /// The shared secret and what comes from it: the code both screens show
  /// and the key for traffic. [startPub] is the public key of the computer
  /// that started pairing and [answerPub] the other's, so both sides get the
  /// same result.
  static Future<({String code, List<int> key})> agree(
    SimpleKeyPair mine,
    List<int> theirs, {
    required List<int> startPub,
    required List<int> answerPub,
  }) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: mine,
      remotePublicKey: SimplePublicKey(theirs, type: KeyPairType.x25519),
    );
    Future<List<int>> derive(String info, int length) async => (await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: length,
    ).deriveKey(secretKey: shared, nonce: [...startPub, ...answerPub], info: utf8.encode(info))).extractBytes();
    final codeBytes = await derive('thread-suit pairing code', 4);
    final n = ByteData.sublistView(Uint8List.fromList(codeBytes)).getUint32(0) % 1000000;
    return (code: n.toString().padLeft(6, '0'), key: await derive('thread-suit traffic key', 32));
  }

  /// "123456" as "123 456", easier to compare at a glance.
  static String spaced(String code) => code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;

  /// [message] sealed under [key]. [context] (method, path, who's sending)
  /// isn't secret but is checked, so a sealed message can't be reused
  /// somewhere else.
  static Future<String> seal(List<int> key, Map<String, dynamic> message, String context) async {
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(message)),
      secretKey: SecretKey(key),
      aad: utf8.encode(context),
    );
    return base64Encode(box.concatenation());
  }

  /// The message [sealed] holds, or null if it wasn't sealed under [key] for
  /// [context] (wrong key, changed, or meant for something else).
  static Future<Map<String, dynamic>?> open(List<int> key, String sealed, String context) async {
    try {
      final box = SecretBox.fromConcatenation(
        base64Decode(sealed),
        nonceLength: _aes.nonceLength,
        macLength: _aes.macAlgorithm.macLength,
      );
      final clear = await _aes.decrypt(box, secretKey: SecretKey(key), aad: utf8.encode(context));
      return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}
