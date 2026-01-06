import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:common/model/stored_security_context.dart';
import 'package:convert/convert.dart';

/// Generates a random self-signed certificate and security context.
StoredSecurityContext generateSecurityContext([AsymmetricKeyPair? keyPair]) {
  keyPair ??= CryptoUtils.generateRSAKeyPair();
  final privateKey = keyPair.privateKey as RSAPrivateKey;
  final publicKey = keyPair.publicKey as RSAPublicKey;
  final dn = {
    'CN': 'LocalSend CLI',
    'O': '',
    'OU': '',
    'L': '',
    'S': '',
    'C': '',
  };
  final csr = X509Utils.generateRsaCsrPem(dn, privateKey, publicKey);
  final certificate = X509Utils.generateSelfSignedCertificate(
    keyPair.privateKey,
    csr,
    1, // SECURITY: 1 day validity (ephemeral certificates for single transfer)
  );

  final hash = calculateHashOfCertificate(certificate);
  final spki = extractPublicKeyFromCertificate(certificate);

  return StoredSecurityContext(
    privateKey: CryptoUtils.encodeRSAPrivateKeyToPemPkcs1(privateKey),
    publicKey: spki,
    certificate: certificate,
    certificateHash: hash,
  );
}

/// Calculates the SHA-256 hash of a certificate.
String calculateHashOfCertificate(String certificate) {
  // Convert PEM to DER
  final pemContent = certificate
      .replaceAll('\r\n', '\n')
      .split('\n')
      .where((line) => line.isNotEmpty && !line.startsWith('---'))
      .join();
  final der = base64Decode(pemContent);

  // Calculate hash
  return CryptoUtils.getHash(
    Uint8List.fromList(der),
    algorithmName: 'SHA-256',
  );
}

/// Extracts the public key from a certificate.
String extractPublicKeyFromCertificate(String certificate) {
  final cert = X509Utils.x509CertificateFromPem(certificate);
  final publicHex = cert.tbsCertificate!.subjectPublicKeyInfo.bytes!;
  return _hexToSpkiPem(publicHex);
}

String _hexToSpkiPem(String hexBytes) {
  final publicBytes = hex.decode(hexBytes);
  final publicBase64 = base64Encode(publicBytes);
  final temp = '''-----BEGIN PUBLIC KEY-----
$publicBase64
-----END PUBLIC KEY-----''';
  return X509Utils.fixPem(temp);
}

/// Creates a SecurityContext from a StoredSecurityContext.
SecurityContext createSecurityContext(StoredSecurityContext stored) {
  final context = SecurityContext();
  context.useCertificateChainBytes(utf8.encode(stored.certificate));
  context.usePrivateKeyBytes(utf8.encode(stored.privateKey));
  return context;
}

/// Validates that a certificate matches the expected fingerprint.
/// Returns true if valid, false otherwise.
bool validateCertificateFingerprint(String certificate, String expectedFingerprint) {
  try {
    final actualFingerprint = calculateHashOfCertificate(certificate);
    return actualFingerprint == expectedFingerprint;
  } catch (e) {
    return false;
  }
}
