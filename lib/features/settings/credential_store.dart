import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../../core/atomic_file.dart';
import '../../core/log.dart';
import '../../core/paths.dart';

/// API key storage across platforms:
/// - Windows: Windows Credential Manager + DPAPI fallback
/// - macOS: Security.framework Keychain + authenticated local vault fallback
/// - Android: App-private authenticated vault + optional native Keystore bridge
/// Targets: `flDoc/chat`, `flDoc/embedding`.
abstract class CredentialStore {
  Future<void> warmUp();
  String? read(String target);
  void write(String target, String secret);
  void delete(String target);

  static const chatTarget = 'flDoc/chat';
  static const embeddingTarget = 'flDoc/embedding';

  factory CredentialStore.platform() {
    if (Platform.isWindows) return WindowsCredentialStore();
    if (Platform.isMacOS) return MacOsCredentialStore();
    if (Platform.isAndroid) return AndroidCredentialStore();
    return LocalVaultCredentialStore();
  }
}

class MemoryCredentialStore implements CredentialStore {
  final Map<String, String> _m = {};

  @override
  Future<void> warmUp() async {}

  @override
  String? read(String target) => _m[target];

  @override
  void write(String target, String secret) => _m[target] = secret;

  @override
  void delete(String target) => _m.remove(target);
}

class WindowsCredentialStore implements CredentialStore {
  WindowsCredentialStore({this.fallbackFilePath});

  static const int _cryptProtectUiForbidden = 0x01;

  /// Optional explicit path for DPAPI fallback storage (mainly for tests).
  final String? fallbackFilePath;

  String? get _effectiveFallbackPath => fallbackFilePath ?? AppPaths.instanceOrNull?.credentialsFallbackFile;

  @override
  Future<void> warmUp() async {}

  @override
  String? read(String target) {
    final fromCred = _readFromCredManager(target);
    if (fromCred != null && fromCred.isNotEmpty) return fromCred;
    return _readFromFallback(target);
  }

  String? _readFromCredManager(String target) {
    final pTarget = target.toNativeUtf16();
    final ppCred = calloc<Pointer<CREDENTIAL>>();
    try {
      final ok = CredRead(pTarget, CRED_TYPE_GENERIC, 0, ppCred);
      if (ok == 0) return null;
      final cred = ppCred.value.ref;
      final bytes = cred.CredentialBlob.asTypedList(cred.CredentialBlobSize);
      final value = utf8.decode(List<int>.from(bytes));
      CredFree(ppCred.value);
      return value;
    } finally {
      calloc.free(pTarget);
      calloc.free(ppCred);
    }
  }

  @override
  void write(String target, String secret) {
    late Object credError;
    try {
      _writeToCredManager(target, secret);
      if (_readFromCredManager(target) == secret) {
        _deleteFromFallback(target);
        return;
      }
      credError = StateError('CredRead verification mismatch for $target');
    } catch (e) {
      credError = e;
      Log.warn('CredWrite failed for $target ($e), trying DPAPI fallback');
    }

    try {
      _writeToFallback(target, secret);
      if (_readFromFallback(target) == secret) {
        return;
      }
      throw StateError('DPAPI credential fallback verification failed for $target');
    } catch (fallbackError) {
      Log.error('All credential stores failed for $target', fallbackError);
      Error.throwWithStackTrace(credError, StackTrace.current);
    }
  }

  void _writeToCredManager(String target, String secret) {
    final pTarget = target.toNativeUtf16();
    final pUser = 'flDoc'.toNativeUtf16();
    final data = utf8.encode(secret);
    final blob = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    blob.asTypedList(data.isEmpty ? 1 : data.length).setAll(0, data.isEmpty ? [0] : data);
    final cred = calloc<CREDENTIAL>();
    try {
      cred.ref
        ..Type = CRED_TYPE_GENERIC
        ..TargetName = pTarget
        ..UserName = pUser
        ..CredentialBlobSize = data.length
        ..CredentialBlob = blob
        ..Persist = CRED_PERSIST_LOCAL_MACHINE;
      final ok = CredWrite(cred, 0);
      if (ok == 0) {
        throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
      }
    } finally {
      calloc.free(pTarget);
      calloc.free(pUser);
      calloc.free(blob);
      calloc.free(cred);
    }
  }

  @override
  void delete(String target) {
    final pTarget = target.toNativeUtf16();
    try {
      CredDelete(pTarget, CRED_TYPE_GENERIC, 0);
    } finally {
      calloc.free(pTarget);
    }
    _deleteFromFallback(target);
  }

  String? _readFromFallback(String target) {
    final path = _effectiveFallbackPath;
    if (path == null) return null;
    try {
      final loaded = AtomicFile.readWithBackupFallback(path, isValid: _isValidJsonMap);
      if (loaded == null) return null;
      final decoded = jsonDecode(loaded.text);
      if (decoded is! Map) return null;
      final enc = decoded[target];
      if (enc is! String || enc.isEmpty) return null;
      return _unprotectDpapi(base64Decode(enc));
    } catch (e) {
      Log.warn('DPAPI credential read failed for $target: $e');
      return null;
    }
  }

  void _writeToFallback(String target, String secret) {
    final path = _effectiveFallbackPath;
    if (path == null) {
      throw StateError('No DPAPI fallback path available for $target');
    }
    Map<String, dynamic> map = {};
    final loaded = AtomicFile.readWithBackupFallback(path, isValid: _isValidJsonMap);
    if (loaded != null) {
      try {
        final decoded = jsonDecode(loaded.text);
        if (decoded is Map<String, dynamic>) map = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    map[target] = base64Encode(_protectDpapi(secret));
    AtomicFile.writeStringSync(path, jsonEncode(map), keepBackup: true);
  }

  void _deleteFromFallback(String target) {
    final path = _effectiveFallbackPath;
    if (path == null) return;
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return;
      if (!decoded.containsKey(target)) return;
      decoded.remove(target);
      if (decoded.isEmpty) {
        f.deleteSync();
        final bak = File('$path.bak');
        if (bak.existsSync()) bak.deleteSync();
      } else {
        AtomicFile.writeStringSync(path, jsonEncode(decoded), keepBackup: true);
      }
    } catch (_) {}
  }

  static bool _isValidJsonMap(String text) {
    try {
      return jsonDecode(text) is Map<String, dynamic>;
    } catch (_) {
      return false;
    }
  }

  static Uint8List _protectDpapi(String plainText) {
    final data = utf8.encode(plainText);
    final inBuf = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    if (data.isNotEmpty) {
      inBuf.asTypedList(data.length).setAll(0, data);
    }
    final inBlob = calloc<CRYPT_INTEGER_BLOB>();
    final outBlob = calloc<CRYPT_INTEGER_BLOB>();
    inBlob.ref
      ..cbData = data.length
      ..pbData = inBuf;
    outBlob.ref
      ..cbData = 0
      ..pbData = nullptr;
    try {
      final ok = CryptProtectData(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _cryptProtectUiForbidden,
        outBlob,
      );
      if (ok == 0) {
        throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
      }
      final len = outBlob.ref.cbData;
      return Uint8List.fromList(outBlob.ref.pbData.asTypedList(len));
    } finally {
      if (outBlob.ref.pbData != nullptr) {
        LocalFree(outBlob.ref.pbData);
      }
      calloc.free(inBuf);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }

  static String _unprotectDpapi(Uint8List encrypted) {
    final inBuf = calloc<Uint8>(encrypted.isEmpty ? 1 : encrypted.length);
    if (encrypted.isNotEmpty) {
      inBuf.asTypedList(encrypted.length).setAll(0, encrypted);
    }
    final inBlob = calloc<CRYPT_INTEGER_BLOB>();
    final outBlob = calloc<CRYPT_INTEGER_BLOB>();
    inBlob.ref
      ..cbData = encrypted.length
      ..pbData = inBuf;
    outBlob.ref
      ..cbData = 0
      ..pbData = nullptr;
    try {
      final ok = CryptUnprotectData(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _cryptProtectUiForbidden,
        outBlob,
      );
      if (ok == 0) {
        throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
      }
      final len = outBlob.ref.cbData;
      return utf8.decode(outBlob.ref.pbData.asTypedList(len));
    } finally {
      if (outBlob.ref.pbData != nullptr) {
        LocalFree(outBlob.ref.pbData);
      }
      calloc.free(inBuf);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }
}

/// Authenticated encrypted local vault in the OS-protected app support directory.
/// Uses HMAC-SHA256 CTR stream encryption + HMAC-SHA256 integrity tag, atomic
/// writes, `0600` POSIX permissions, and `.bak` recovery.
class LocalVaultCredentialStore implements CredentialStore {
  LocalVaultCredentialStore({this.vaultFilePath});

  /// Explicit vault path (defaults to `AppPaths.instanceOrNull?.credentialsVaultFile`).
  final String? vaultFilePath;

  String? get _effectivePath => vaultFilePath ?? AppPaths.instanceOrNull?.credentialsVaultFile;

  @override
  Future<void> warmUp() async {}

  @override
  String? read(String target) {
    final path = _effectivePath;
    if (path == null) return null;
    final masterKey = _readMasterKey(path);
    if (masterKey == null) return null;

    final vault = _readVaultMap(path);
    final entries = vault?['entries'];
    if (entries is! Map) return null;
    final rawEntry = entries[target];
    if (rawEntry is! Map) return null;
    return _decryptEntry(masterKey, target, rawEntry);
  }

  @override
  void write(String target, String secret) {
    final path = _effectivePath;
    if (path == null) {
      throw StateError('No credential vault path available for $target');
    }
    final masterKey = _ensureMasterKey(path);
    final existing = _readVaultMap(path) ?? <String, dynamic>{'v': 1, 'entries': <String, dynamic>{}};
    final rawEntries = existing['entries'];
    final entries = rawEntries is Map<String, dynamic>
        ? Map<String, dynamic>.from(rawEntries)
        : <String, dynamic>{
            if (rawEntries is Map)
              for (final e in rawEntries.entries) '${e.key}': e.value,
          };

    entries[target] = _encryptEntry(masterKey, target, secret);
    final nextDoc = <String, dynamic>{'v': 1, 'entries': entries};
    AtomicFile.writeStringSync(path, jsonEncode(nextDoc), keepBackup: true, ownerOnly: true);

    if (read(target) != secret) {
      throw StateError('Vault credential verification failed for $target');
    }
  }

  @override
  void delete(String target) {
    final path = _effectivePath;
    if (path == null) return;
    final vault = _readVaultMap(path);
    if (vault == null) return;
    final rawEntries = vault['entries'];
    if (rawEntries is! Map || !rawEntries.containsKey(target)) return;
    final entries = Map<String, dynamic>.from(rawEntries)..remove(target);
    if (entries.isEmpty) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
        final bak = File('$path.bak');
        if (bak.existsSync()) bak.deleteSync();
      } catch (_) {}
      return;
    }
    AtomicFile.writeStringSync(
      path,
      jsonEncode(<String, dynamic>{'v': 1, 'entries': entries}),
      keepBackup: true,
      ownerOnly: true,
    );
  }

  static bool _isValidKeyText(String text) {
    try {
      return base64Decode(text.trim()).length == 32;
    } catch (_) {
      return false;
    }
  }

  static bool _isValidVaultText(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> && decoded['entries'] is Map;
    } catch (_) {
      return false;
    }
  }

  Uint8List? _readMasterKey(String vaultPath) {
    final keyPath = '$vaultPath.key';
    final loaded = AtomicFile.readWithBackupFallback(keyPath, isValid: _isValidKeyText);
    if (loaded == null) return null;
    try {
      final bytes = base64Decode(loaded.text.trim());
      return bytes.length == 32 ? Uint8List.fromList(bytes) : null;
    } catch (_) {
      return null;
    }
  }

  Uint8List _ensureMasterKey(String vaultPath) {
    final existing = _readMasterKey(vaultPath);
    if (existing != null) return existing;
    final rng = Random.secure();
    final key = Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
    AtomicFile.writeStringSync('$vaultPath.key', base64Encode(key), keepBackup: true, ownerOnly: true);
    return key;
  }

  Map<String, dynamic>? _readVaultMap(String vaultPath) {
    final loaded = AtomicFile.readWithBackupFallback(vaultPath, isValid: _isValidVaultText);
    if (loaded == null) return null;
    try {
      final decoded = jsonDecode(loaded.text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static List<int> _deriveSubkey(Uint8List masterKey, String label) =>
      sha256.convert([...masterKey, ...utf8.encode(label)]).bytes;

  static Uint8List _xorKeystream(List<int> encKey, List<int> nonce, List<int> input) {
    final out = Uint8List(input.length);
    var offset = 0;
    var counter = 0;
    while (offset < input.length) {
      final block = Hmac(sha256, encKey).convert([
        ...nonce,
        (counter >> 24) & 0xff,
        (counter >> 16) & 0xff,
        (counter >> 8) & 0xff,
        counter & 0xff,
      ]).bytes;
      for (var i = 0; i < block.length && offset < input.length; i++, offset++) {
        out[offset] = input[offset] ^ block[i];
      }
      counter++;
    }
    return out;
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Map<String, String> _encryptEntry(Uint8List masterKey, String target, String secret) {
    final rng = Random.secure();
    final nonce = List<int>.generate(16, (_) => rng.nextInt(256));
    final encKey = _deriveSubkey(masterKey, 'enc');
    final macKey = _deriveSubkey(masterKey, 'mac');
    final cipher = _xorKeystream(encKey, nonce, utf8.encode(secret));
    final tag = Hmac(sha256, macKey).convert([...utf8.encode(target), 0, ...nonce, ...cipher]).bytes;
    return {
      'n': base64Encode(nonce),
      'c': base64Encode(cipher),
      'm': base64Encode(tag),
    };
  }

  static String? _decryptEntry(Uint8List masterKey, String target, Map<dynamic, dynamic> entry) {
    try {
      final n = entry['n'];
      final c = entry['c'];
      final m = entry['m'];
      if (n is! String || c is! String || m is! String) return null;
      final nonce = base64Decode(n);
      final cipher = base64Decode(c);
      final tag = base64Decode(m);
      final macKey = _deriveSubkey(masterKey, 'mac');
      final expected = Hmac(sha256, macKey).convert([...utf8.encode(target), 0, ...nonce, ...cipher]).bytes;
      if (!_constantTimeEquals(tag, expected)) {
        Log.warn('Credential vault integrity mismatch for $target');
        return null;
      }
      final encKey = _deriveSubkey(masterKey, 'enc');
      final plain = _xorKeystream(encKey, nonce, cipher);
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }
}

typedef _SecFindNative = Int32 Function(
  Pointer<Void> keychainOrArray,
  Uint32 serviceNameLength,
  Pointer<Utf8> serviceName,
  Uint32 accountNameLength,
  Pointer<Utf8> accountName,
  Pointer<Uint32> passwordLength,
  Pointer<Pointer<Void>> passwordData,
  Pointer<Pointer<Void>> itemRef,
);
typedef _SecFindDart = int Function(
  Pointer<Void> keychainOrArray,
  int serviceNameLength,
  Pointer<Utf8> serviceName,
  int accountNameLength,
  Pointer<Utf8> accountName,
  Pointer<Uint32> passwordLength,
  Pointer<Pointer<Void>> passwordData,
  Pointer<Pointer<Void>> itemRef,
);

typedef _SecAddNative = Int32 Function(
  Pointer<Void> keychain,
  Uint32 serviceNameLength,
  Pointer<Utf8> serviceName,
  Uint32 accountNameLength,
  Pointer<Utf8> accountName,
  Uint32 passwordLength,
  Pointer<Void> passwordData,
  Pointer<Pointer<Void>> itemRef,
);
typedef _SecAddDart = int Function(
  Pointer<Void> keychain,
  int serviceNameLength,
  Pointer<Utf8> serviceName,
  int accountNameLength,
  Pointer<Utf8> accountName,
  int passwordLength,
  Pointer<Void> passwordData,
  Pointer<Pointer<Void>> itemRef,
);

typedef _SecModifyNative = Int32 Function(
  Pointer<Void> itemRef,
  Pointer<Void> attrList,
  Uint32 length,
  Pointer<Void> data,
);
typedef _SecModifyDart = int Function(
  Pointer<Void> itemRef,
  Pointer<Void> attrList,
  int length,
  Pointer<Void> data,
);

typedef _SecDeleteNative = Int32 Function(Pointer<Void> itemRef);
typedef _SecDeleteDart = int Function(Pointer<Void> itemRef);

typedef _SecFreeNative = Int32 Function(Pointer<Void> attrList, Pointer<Void> data);
typedef _SecFreeDart = int Function(Pointer<Void> attrList, Pointer<Void> data);

typedef _CfReleaseNative = Void Function(Pointer<Void> cf);
typedef _CfReleaseDart = void Function(Pointer<Void> cf);

class _MacKeychainFfi {
  _MacKeychainFfi._()
      : _sec = DynamicLibrary.open('/System/Library/Frameworks/Security.framework/Security'),
        _cf = DynamicLibrary.open('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation') {
    findGeneric = _sec.lookupFunction<_SecFindNative, _SecFindDart>('SecKeychainFindGenericPassword');
    addGeneric = _sec.lookupFunction<_SecAddNative, _SecAddDart>('SecKeychainAddGenericPassword');
    modifyItem = _sec.lookupFunction<_SecModifyNative, _SecModifyDart>('SecKeychainItemModifyContent');
    deleteItem = _sec.lookupFunction<_SecDeleteNative, _SecDeleteDart>('SecKeychainItemDelete');
    freeContent = _sec.lookupFunction<_SecFreeNative, _SecFreeDart>('SecKeychainItemFreeContent');
    cfRelease = _cf.lookupFunction<_CfReleaseNative, _CfReleaseDart>('CFRelease');
  }

  final DynamicLibrary _sec;
  final DynamicLibrary _cf;
  late final _SecFindDart findGeneric;
  late final _SecAddDart addGeneric;
  late final _SecModifyDart modifyItem;
  late final _SecDeleteDart deleteItem;
  late final _SecFreeDart freeContent;
  late final _CfReleaseDart cfRelease;

  static _MacKeychainFfi? _cached;
  static _MacKeychainFfi? tryLoad() {
    if (!Platform.isMacOS) return null;
    try {
      return _cached ??= _MacKeychainFfi._();
    } catch (e) {
      Log.warn('macOS Security.framework unavailable ($e), using encrypted vault');
      return null;
    }
  }
}

/// macOS credential store: Security.framework Keychain with read-back verification
/// and automatic fallback to [LocalVaultCredentialStore].
class MacOsCredentialStore implements CredentialStore {
  MacOsCredentialStore({String? fallbackVaultPath})
      : _fallback = LocalVaultCredentialStore(vaultFilePath: fallbackVaultPath);

  static const _serviceName = 'dev.fldoc';
  static const int _errSecSuccess = 0;
  static const int _errSecDuplicateItem = -25299;

  final LocalVaultCredentialStore _fallback;

  @override
  Future<void> warmUp() async {}

  @override
  String? read(String target) {
    final fromKeychain = _readKeychain(target);
    if (fromKeychain != null && fromKeychain.isNotEmpty) return fromKeychain;
    return _fallback.read(target);
  }

  @override
  void write(String target, String secret) {
    try {
      if (_writeKeychain(target, secret) && _readKeychain(target) == secret) {
        _fallback.delete(target);
        return;
      }
    } catch (e) {
      Log.warn('macOS Keychain write failed for $target ($e), trying local vault');
    }
    _fallback.write(target, secret);
  }

  @override
  void delete(String target) {
    _deleteKeychain(target);
    _fallback.delete(target);
  }

  String? _readKeychain(String target) {
    final ffi = _MacKeychainFfi.tryLoad();
    if (ffi == null) return null;
    final pSvc = _serviceName.toNativeUtf8();
    final pAcc = target.toNativeUtf8();
    final pLen = calloc<Uint32>();
    final ppData = calloc<Pointer<Void>>();
    try {
      final status = ffi.findGeneric(
        nullptr,
        _serviceName.length,
        pSvc,
        utf8.encode(target).length,
        pAcc,
        pLen,
        ppData,
        nullptr,
      );
      if (status != _errSecSuccess || ppData.value == nullptr) return null;
      final bytes = ppData.value.cast<Uint8>().asTypedList(pLen.value);
      final value = utf8.decode(List<int>.from(bytes));
      ffi.freeContent(nullptr, ppData.value);
      return value;
    } finally {
      calloc.free(pSvc);
      calloc.free(pAcc);
      calloc.free(pLen);
      calloc.free(ppData);
    }
  }

  bool _writeKeychain(String target, String secret) {
    final ffi = _MacKeychainFfi.tryLoad();
    if (ffi == null) return false;
    final pSvc = _serviceName.toNativeUtf8();
    final accBytes = utf8.encode(target);
    final pAcc = target.toNativeUtf8();
    final secBytes = utf8.encode(secret);
    final pSec = calloc<Uint8>(secBytes.isEmpty ? 1 : secBytes.length);
    if (secBytes.isNotEmpty) {
      pSec.asTypedList(secBytes.length).setAll(0, secBytes);
    }
    final pItemRef = calloc<Pointer<Void>>();
    pItemRef.value = nullptr;
    try {
      var status = ffi.addGeneric(
        nullptr,
        _serviceName.length,
        pSvc,
        accBytes.length,
        pAcc,
        secBytes.length,
        pSec.cast<Void>(),
        nullptr,
      );
      if (status == _errSecDuplicateItem) {
        final findStatus = ffi.findGeneric(
          nullptr,
          _serviceName.length,
          pSvc,
          accBytes.length,
          pAcc,
          nullptr,
          nullptr,
          pItemRef,
        );
        if (findStatus == _errSecSuccess && pItemRef.value != nullptr) {
          status = ffi.modifyItem(pItemRef.value, nullptr, secBytes.length, pSec.cast<Void>());
          ffi.cfRelease(pItemRef.value);
        }
      }
      return status == _errSecSuccess;
    } finally {
      calloc.free(pSvc);
      calloc.free(pAcc);
      calloc.free(pSec);
      calloc.free(pItemRef);
    }
  }

  void _deleteKeychain(String target) {
    final ffi = _MacKeychainFfi.tryLoad();
    if (ffi == null) return;
    final pSvc = _serviceName.toNativeUtf8();
    final pAcc = target.toNativeUtf8();
    final pItemRef = calloc<Pointer<Void>>();
    pItemRef.value = nullptr;
    try {
      final status = ffi.findGeneric(
        nullptr,
        _serviceName.length,
        pSvc,
        utf8.encode(target).length,
        pAcc,
        nullptr,
        nullptr,
        pItemRef,
      );
      if (status == _errSecSuccess && pItemRef.value != nullptr) {
        ffi.deleteItem(pItemRef.value);
        ffi.cfRelease(pItemRef.value);
      }
    } finally {
      calloc.free(pSvc);
      calloc.free(pAcc);
      calloc.free(pItemRef);
    }
  }
}

/// Android credential store backed by an authenticated encrypted vault in the
/// app-private FBE directory, with optional native Keystore bridge hooks.
class AndroidCredentialStore implements CredentialStore {
  AndroidCredentialStore({
    String? vaultFilePath,
    this.nativeLoadAll,
    this.nativeWrite,
    this.nativeDelete,
  }) : _vault = LocalVaultCredentialStore(vaultFilePath: vaultFilePath);

  final LocalVaultCredentialStore _vault;
  final Future<Map<String, String>> Function()? nativeLoadAll;
  final Future<void> Function(String target, String secret)? nativeWrite;
  final Future<void> Function(String target)? nativeDelete;
  final Map<String, String> _cache = {};

  @override
  Future<void> warmUp() async {
    for (final target in const [CredentialStore.chatTarget, CredentialStore.embeddingTarget]) {
      final v = _vault.read(target);
      if (v != null && v.isNotEmpty) _cache[target] = v;
    }
    final loader = nativeLoadAll;
    if (loader == null) return;
    try {
      final nativeEntries = await loader();
      for (final e in nativeEntries.entries) {
        if (e.value.isNotEmpty) {
          _cache[e.key] = e.value;
          _vault.write(e.key, e.value);
        }
      }
    } catch (_) {
      // Native Keystore bridge is optional; encrypted private-dir vault remains authoritative.
    }
  }

  @override
  String? read(String target) => _cache[target] ?? _vault.read(target);

  @override
  void write(String target, String secret) {
    _vault.write(target, secret);
    _cache[target] = secret;
    final bridgeWrite = nativeWrite;
    if (bridgeWrite != null) {
      unawaited(bridgeWrite(target, secret).catchError((_) {}));
    }
  }

  @override
  void delete(String target) {
    _cache.remove(target);
    _vault.delete(target);
    final bridgeDelete = nativeDelete;
    if (bridgeDelete != null) {
      unawaited(bridgeDelete(target).catchError((_) {}));
    }
  }
}

/// `sk-abcd...wxyz` style mask for display.
String maskSecret(String? s) {
  if (s == null || s.isEmpty) return '未配置';
  if (s.length <= 8) return '********';
  return '${s.substring(0, 3)}****${s.substring(s.length - 4)}';
}
