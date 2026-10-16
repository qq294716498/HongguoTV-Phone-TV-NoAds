import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_build.dart';
import 'windows_update_runtime.dart';
import 'app_layout.dart' show appVersion, windowsBuildNumber;

const updateRepository = 'qq294716498/HongguoTV-Phone-TV-NoAds';
const updateApi =
    'https://api.github.com/repos/$updateRepository/releases/latest';
const updatePage = 'https://github.com/$updateRepository/releases/latest';
const windowsUpdateApi =
    'https://api.github.com/repos/$updateRepository/releases?per_page=100';
const windowsUpdatePage = 'https://github.com/$updateRepository/releases';
final windowsUpdateTag = RegExp(
  r'^windows-v(\d+\.\d+\.\d+-preview\.\d+)-(\d+)$',
);
const updateMaximumBytes = 256 * 1024 * 1024;
const updateAbiOffsets = {
  'armeabi-v7a': 1000,
  'arm64-v8a': 2000,
  'x86_64': 4000,
};

class InstalledApp {
  const InstalledApp({
    required this.version,
    required this.code,
    required this.abi,
  });
  final String version;
  final int code;
  final String abi;

  factory InstalledApp.fromMap(Map<Object?, Object?> data) {
    final version = data['version'];
    final code = data['code'];
    final abi = data['abi'];
    if (version is! String ||
        code is! int ||
        code <= 0 ||
        abi is! String ||
        !updateAbiOffsets.containsKey(abi)) {
      throw const FormatException('无法确认已安装版本与架构');
    }
    return InstalledApp(version: version, code: code, abi: abi);
  }
}

class AppRelease {
  const AppRelease({
    required this.version,
    required this.code,
    required this.abi,
    required this.notes,
    required this.url,
    required this.bytes,
    required this.sha256,
  });
  final String version;
  final int code;
  final String abi;
  final String notes;
  final Uri url;
  final int bytes;
  final String sha256;

  static AppRelease? parse(Map<String, dynamic> json, InstalledApp installed) {
    if (json['draft'] != false || json['prerelease'] != false) {
      throw const FormatException('更新信息不是正式稳定版本');
    }
    final tag = json['tag_name'];
    if (tag is! String) throw const FormatException('缺少版本标签');
    final match = RegExp(r'^app-v(\d+\.\d+\.\d+)-(\d+)$').firstMatch(tag);
    if (match == null) throw const FormatException('版本标签无法识别');
    final build = int.parse(match[2]!);
    final offset = updateAbiOffsets[installed.abi];
    if (offset == null || build < 1 || build >= 1000) {
      throw const FormatException('版本编号或设备架构不受支持');
    }
    final code = offset + build;
    if (code <= installed.code) return null;
    final version = match[1]!;
    final name = 'HongguoTV-$version-${installed.abi}.apk';
    final assets = json['assets'];
    if (assets is! List) throw const FormatException('缺少安装包列表');
    final matches = assets
        .whereType<Map>()
        .where((a) => a['name'] == name)
        .toList();
    if (matches.length != 1) throw const FormatException('未找到适合当前架构的唯一安装包');
    final asset = matches.single;
    final bytes = asset['size'];
    final digest = asset['digest'];
    final url = Uri.tryParse(asset['browser_download_url']?.toString() ?? '');
    final expected = Uri.parse(
      'https://github.com/$updateRepository/releases/download/$tag/$name',
    );
    if (bytes is! int ||
        bytes <= 0 ||
        bytes > updateMaximumBytes ||
        digest is! String ||
        !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest) ||
        asset['state'] != 'uploaded' ||
        url != expected) {
      throw const FormatException('安装包地址、大小或校验信息无效');
    }
    final body = json['body'];
    final notes = body is String && body.trim().isNotEmpty
        ? body
        : '此版本未提供更新说明。';
    return AppRelease(
      version: version,
      code: code,
      abi: installed.abi,
      notes: notes.length > 12000 ? '${notes.substring(0, 12000)}…' : notes,
      url: url!,
      bytes: bytes,
      sha256: digest.substring(7).toLowerCase(),
    );
  }

  static AppRelease? parseWindows(
    Map<String, dynamic> json,
    InstalledApp installed,
  ) {
    if (json['draft'] != false || json['prerelease'] != true) {
      throw const FormatException('更新信息不是 Windows 测试版本');
    }
    final tag = json['tag_name'];
    final match = tag is String ? windowsUpdateTag.firstMatch(tag) : null;
    if (match == null || installed.abi != 'windows-x64') {
      throw const FormatException('Windows 标签或架构无法识别');
    }
    final code = int.parse(match[2]!);
    if (code <= installed.code) return null;
    final version = match[1]!;
    final name = 'HongguoTV-$version-windows-x64.zip';
    final assets = json['assets'];
    if (assets is! List) throw const FormatException('缺少 Windows 压缩包');
    final matches = assets
        .whereType<Map>()
        .where((a) => a['name'] == name)
        .toList();
    if (matches.length != 1) throw const FormatException('Windows 压缩包不唯一');
    final asset = matches.single;
    final bytes = asset['size'];
    final digest = asset['digest'];
    final url = Uri.tryParse(asset['browser_download_url']?.toString() ?? '');
    final expected = Uri.parse(
      'https://github.com/$updateRepository/releases/download/$tag/$name',
    );
    if (bytes is! int ||
        bytes <= 0 ||
        bytes > 512 * 1024 * 1024 ||
        digest is! String ||
        !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest) ||
        asset['state'] != 'uploaded' ||
        url != expected) {
      throw const FormatException('Windows 压缩包地址、大小或校验信息无效');
    }
    final body = json['body'];
    final notes = body is String && body.trim().isNotEmpty
        ? body
        : '此版本未提供更新说明。';
    return AppRelease(
      version: version,
      code: code,
      abi: installed.abi,
      notes: notes.length > 12000 ? '${notes.substring(0, 12000)}…' : notes,
      url: url!,
      bytes: bytes,
      sha256: digest.substring(7).toLowerCase(),
    );
  }

  Map<String, Object> get validation => {
    'version': version,
    'code': code,
    'abi': abi,
    'bytes': bytes,
    'sha256': sha256,
  };
}

bool trustedUpdateUrl(
  Uri uri, {
  required bool metadata,
  required bool initial,
}) {
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      uri.fragment.isNotEmpty) {
    return false;
  }
  if (metadata) {
    return uri.toString() == updateApi || uri.toString() == windowsUpdateApi;
  }
  if (uri.host == 'github.com') {
    return uri.query.isEmpty &&
        uri.path.startsWith('/$updateRepository/releases/download/') &&
        uri.pathSegments.length == 6 &&
        !uri.pathSegments.any((s) => s == '..' || s == '.');
  }
  return !initial &&
      (uri.host == 'release-assets.githubusercontent.com' ||
          uri.host == 'objects.githubusercontent.com');
}

abstract class UpdateTransport {
  Future<Map<String, dynamic>> latest();
  Future<void> download(
    AppRelease release,
    File output,
    void Function(int) progress,
  );
  void cancel();
}

class GithubUpdateTransport implements UpdateTransport {
  GithubUpdateTransport({
    HttpClient Function()? clientFactory,
    this.windows = false,
  }) : clientFactory = clientFactory ?? HttpClient.new;
  final HttpClient Function() clientFactory;
  final bool windows;
  HttpClient? _active;
  bool _cancelled = false;

  Future<HttpClientResponse> _open(
    HttpClient client,
    Uri uri, {
    required bool metadata,
  }) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (_cancelled || !identical(_active, client)) {
        throw const UpdateCancelled();
      }
      if (!trustedUpdateUrl(uri, metadata: metadata, initial: redirects == 0)) {
        throw const FormatException('更新地址或重定向不受信任');
      }
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(HttpHeaders.userAgentHeader, 'HongguoTV-Updater');
      request.headers.set(
        HttpHeaders.acceptHeader,
        metadata ? 'application/vnd.github+json' : 'application/octet-stream',
      );
      if (metadata) {
        request.headers.set('X-GitHub-Api-Version', '2022-11-28');
        request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) throw const FormatException('更新重定向缺少地址');
        await response.drain<void>().timeout(const Duration(seconds: 5));
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        throw HttpException(
          response.statusCode == 403 || response.statusCode == 429
              ? 'GitHub 暂时限流，请稍后手动重试'
              : 'GitHub 更新请求失败（${response.statusCode}）',
        );
      }
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      if (encoding != null && encoding.toLowerCase() != 'identity') {
        throw const FormatException('更新服务器返回了不支持的压缩内容');
      }
      return response;
    }
    throw const FormatException('更新重定向次数过多');
  }

  HttpClient _begin() {
    _cancelled = false;
    final client = clientFactory()
      ..connectionTimeout = const Duration(seconds: 15)
      ..autoUncompress = false;
    _active = client;
    return client;
  }

  @override
  Future<Map<String, dynamic>> latest() async {
    final client = _begin();
    try {
      return await (() async {
        final response = await _open(
          client,
          Uri.parse(windows ? windowsUpdateApi : updateApi),
          metadata: true,
        );
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 15),
        )) {
          bytes.addAll(chunk);
          if (bytes.length > 1024 * 1024) throw const FormatException('更新信息过大');
        }
        final data = jsonDecode(utf8.decode(bytes));
        if (windows) return selectWindowsRelease(data);
        if (data is! Map<String, dynamic>) {
          throw const FormatException('更新信息格式错误');
        }
        return data;
      })().timeout(const Duration(seconds: 45));
    } finally {
      client.close(force: true);
      if (identical(_active, client)) _active = null;
    }
  }

  @override
  Future<void> download(
    AppRelease release,
    File output,
    void Function(int) progress,
  ) async {
    final client = _begin();
    IOSink? sink;
    try {
      await (() async {
        final response = await _open(client, release.url, metadata: false);
        if (response.contentLength != -1 &&
            response.contentLength != release.bytes) {
          throw const FormatException('下载大小与发布信息不一致');
        }
        sink = output.openWrite();
        var received = 0;
        var buffered = 0;
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          if (_cancelled || !identical(_active, client)) {
            throw const UpdateCancelled();
          }
          received += chunk.length;
          if (received > release.bytes) {
            throw const FormatException('安装包超出预期大小');
          }
          sink!.add(chunk);
          buffered += chunk.length;
          if (buffered >= 1024 * 1024) {
            await sink!.flush();
            buffered = 0;
          }
          progress(received);
        }
        if (_cancelled || !identical(_active, client)) {
          throw const UpdateCancelled();
        }
        await sink!.flush();
        if (received != release.bytes) throw const FormatException('下载不完整，请重试');
      })().timeout(const Duration(minutes: 30));
    } finally {
      client.close(force: true);
      await sink?.close();
      if (identical(_active, client)) _active = null;
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    _active?.close(force: true);
  }
}

Map<String, dynamic> selectWindowsRelease(Object? data) {
  if (data is! List) throw const FormatException('Windows 更新列表格式错误');
  final candidates = data
      .whereType<Map<String, dynamic>>()
      .where(
        (item) =>
            item['draft'] == false &&
            item['prerelease'] == true &&
            item['tag_name'] is String &&
            windowsUpdateTag.hasMatch(item['tag_name'] as String),
      )
      .toList();
  candidates.sort(
    (a, b) =>
        int.parse(
          windowsUpdateTag.firstMatch(b['tag_name'] as String)![2]!,
        ).compareTo(
          int.parse(windowsUpdateTag.firstMatch(a['tag_name'] as String)![2]!),
        ),
  );
  if (candidates.isEmpty) throw const FormatException('尚无可用的 Windows 测试版本');
  return candidates.first;
}

class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

enum UpdateStage {
  idle,
  checking,
  available,
  downloading,
  validating,
  ready,
  permission,
  installValidating,
  installing,
  failed,
}

abstract class UpdatePlatform {
  Future<InstalledApp> installed();
  Future<String> directory();
  Future<void> validate(AppRelease release);
  Future<bool> canInstall();
  Future<void> openPermission();
  Future<String> install(AppRelease release);
}

class AndroidUpdatePlatform implements UpdatePlatform {
  static const channel = MethodChannel('hongguo/updates');
  @override
  Future<InstalledApp> installed() async => InstalledApp.fromMap(
    (await channel.invokeMapMethod<Object?, Object?>('installedInfo')) ?? {},
  );
  @override
  Future<String> directory() async =>
      (await channel.invokeMethod<String>('directory'))!;
  @override
  Future<void> validate(AppRelease release) =>
      channel.invokeMethod<void>('validate', release.validation);
  @override
  Future<bool> canInstall() async =>
      await channel.invokeMethod<bool>('canInstall') == true;
  @override
  Future<void> openPermission() => channel.invokeMethod<void>('openPermission');
  @override
  Future<String> install(AppRelease release) async =>
      await channel.invokeMethod<String>('install', release.validation) ??
      'returned';
}

class WindowsUpdatePlatform implements UpdatePlatform {
  @override
  Future<InstalledApp> installed() async => const InstalledApp(
    version: appVersion,
    code: windowsBuildNumber,
    abi: 'windows-x64',
  );
  @override
  Future<String> directory() async =>
      '${(await getApplicationSupportDirectory()).path}/windows-updates';
  @override
  Future<void> validate(AppRelease release) async {
    if (release.abi != 'windows-x64') throw const FormatException('更新架构不匹配');
    final file = File('${await directory()}/pending.zip');
    if (await file.length() != release.bytes ||
        (await sha256.bind(file.openRead()).first).toString() !=
            release.sha256) {
      throw const FormatException('Windows 压缩包大小或 SHA-256 校验失败');
    }
  }

  @override
  Future<bool> canInstall() async => true;
  @override
  Future<void> openPermission() async {}
  @override
  Future<String> install(AppRelease release) async {
    await validate(release);
    return WindowsUpdateRuntime.install(
      zipPath: '${await directory()}/pending.zip',
      version: release.version,
      build: release.code,
    );
  }
}

class AppUpdates extends ChangeNotifier {
  AppUpdates({
    required this.preferences,
    this.supportedEdition = allSourcesEnabled,
    UpdateTransport? transport,
    UpdatePlatform? platform,
    DateTime Function()? now,
    bool? windows,
  }) : windows = windows ?? Platform.isWindows,
       transport =
           transport ??
           GithubUpdateTransport(windows: windows ?? Platform.isWindows),
       platform =
           platform ??
           ((windows ?? Platform.isWindows)
               ? WindowsUpdatePlatform()
               : AndroidUpdatePlatform()),
       now = now ?? DateTime.now;
  static AppUpdates? current;
  final SharedPreferences preferences;
  final bool supportedEdition;
  final bool windows;
  final UpdateTransport transport;
  final UpdatePlatform platform;
  final DateTime Function() now;
  InstalledApp? installedApp;
  AppRelease? release;
  UpdateStage stage = UpdateStage.idle;
  String message = '启动后自动检查，也可手动检查更新';
  int downloaded = 0;
  bool _disposed = false;
  bool _cancelled = false;
  File? _file;
  File? _partial;
  DateTime? _lastAttempt;
  bool _permissionOpened = false;
  bool _startupCleaned = false;
  String get _cacheKey =>
      windows ? 'app_update_windows_cache_v1' : 'app_update_stable_cache_v1';
  String get _checkedKey =>
      windows ? 'app_update_windows_checked_at_v1' : 'app_update_checked_at_v1';
  String get _pendingName => windows ? 'pending.zip' : 'pending.apk';
  bool get busy => [
    UpdateStage.checking,
    UpdateStage.downloading,
    UpdateStage.validating,
    UpdateStage.installValidating,
    UpdateStage.installing,
  ].contains(stage);
  bool get automatic => preferences.getBool('app_update_automatic') ?? true;
  bool get hasUpdate => release != null;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> setAutomatic(bool value) async {
    await preferences.setBool('app_update_automatic', value);
    _notify();
  }

  Future<void> check({bool manual = false}) async {
    if (!supportedEdition) {
      message = '当前构建不使用此更新频道，请手动获取相同站源范围的版本';
      _notify();
      return;
    }
    if (_disposed ||
        busy ||
        stage == UpdateStage.permission ||
        (!manual && !automatic)) {
      return;
    }
    if (!manual && stage == UpdateStage.ready) return;
    final attemptAge = _lastAttempt == null
        ? null
        : now().difference(_lastAttempt!);
    if (!manual &&
        attemptAge != null &&
        !attemptAge.isNegative &&
        attemptAge < const Duration(hours: 1)) {
      return;
    }
    _lastAttempt = now();
    stage = UpdateStage.checking;
    message = windows ? '正在检查 Windows 测试版本…' : '正在检查稳定版本…';
    _notify();
    try {
      installedApp = await platform.installed().timeout(
        const Duration(seconds: 5),
      );
      if (_disposed) return;
      await _cleanCompletedUpdate();
      if (_disposed) return;
      final last = preferences.getInt(_checkedKey);
      final age = last == null
          ? null
          : now().difference(DateTime.fromMillisecondsSinceEpoch(last));
      final fresh =
          age != null && !age.isNegative && age < const Duration(hours: 12);
      final cached = preferences.getString(_cacheKey);
      Map<String, dynamic>? data;
      if (!manual && fresh && cached != null) {
        try {
          data = jsonDecode(cached) as Map<String, dynamic>;
        } catch (_) {}
      }
      if (_disposed) return;
      data ??= await transport.latest();
      if (_disposed) return;
      final candidate = windows
          ? AppRelease.parseWindows(data, installedApp!)
          : AppRelease.parse(data, installedApp!);
      await preferences.setString(_cacheKey, jsonEncode(data));
      if (manual || !fresh) {
        await preferences.setInt(_checkedKey, now().millisecondsSinceEpoch);
      }
      if (_disposed) return;
      release = candidate;
      stage = candidate == null ? UpdateStage.idle : UpdateStage.available;
      final channel = windows ? 'Windows 测试版本' : '稳定版本';
      message = candidate == null
          ? '已是最新$channel'
          : '发现$channel ${candidate.version}';
    } catch (error) {
      if (_disposed) return;
      release = null;
      stage = UpdateStage.failed;
      message = '暂时无法检查更新：${_error(error)}';
    }
    _notify();
  }

  Future<bool> _candidateStillNewer(AppRelease candidate) async {
    final current = await platform.installed().timeout(
      const Duration(seconds: 5),
    );
    if (_disposed) return false;
    installedApp = current;
    if (candidate.abi != current.abi) {
      release = null;
      throw const FormatException('安装架构已变化，请重新检查更新');
    }
    if (candidate.code > current.code) return true;
    await _removeFile();
    await preferences.remove('app_update_installing_code');
    if (_disposed) return false;
    release = null;
    stage = UpdateStage.idle;
    message = '当前已安装 ${current.version}，无需重复下载或安装';
    _notify();
    return false;
  }

  Future<void> download() async {
    final candidate = release;
    if (!supportedEdition ||
        _disposed ||
        busy ||
        candidate == null ||
        stage == UpdateStage.permission) {
      return;
    }
    _cancelled = false;
    stage = UpdateStage.downloading;
    downloaded = 0;
    message = '正在确认当前版本…';
    _notify();
    try {
      if (!await _candidateStillNewer(candidate)) return;
      if (_cancelled || _disposed) throw const UpdateCancelled();
      message = '正在下载 ${candidate.version}，可取消';
      final progressClock = Stopwatch()..start();
      var notifiedAt = -200;
      final directory = Directory(await platform.directory());
      await directory.create(recursive: true);
      _file = File('${directory.path}/$_pendingName');
      _partial = File('${directory.path}/$_pendingName.part');
      await _removeFile();
      if (_cancelled || _disposed) throw const UpdateCancelled();
      await transport.download(candidate, _partial!, (bytes) {
        if (_cancelled || _disposed || stage != UpdateStage.downloading) return;
        downloaded = bytes;
        if (bytes == candidate.bytes ||
            progressClock.elapsedMilliseconds - notifiedAt >= 200) {
          notifiedAt = progressClock.elapsedMilliseconds;
          _notify();
        }
      });
      if (_cancelled || _disposed) throw const UpdateCancelled();
      await _partial!.rename(_file!.path);
      if (_cancelled || _disposed) throw const UpdateCancelled();
      stage = UpdateStage.validating;
      message = windows ? '正在验证压缩包大小与 SHA-256…' : '正在验证大小、SHA-256、签名、版本与架构…';
      _notify();
      await platform.validate(candidate);
      if (_cancelled || _disposed) throw const UpdateCancelled();
      stage = UpdateStage.ready;
      message = windows
          ? '下载校验通过。暂停播放后点击安装并重启，将自动验证、替换并保留旧版。'
          : '安装包验证通过。点击安装后由 Android 确认';
    } catch (error) {
      await _removeFile();
      if (_disposed) return;
      stage = _cancelled ? UpdateStage.available : UpdateStage.failed;
      message = _cancelled ? '已取消下载，可重新下载' : '下载或验证失败：${_error(error)}';
    }
    _notify();
  }

  void cancelDownload() {
    if (stage != UpdateStage.downloading && stage != UpdateStage.validating) {
      return;
    }
    _cancelled = true;
    transport.cancel();
    message = '正在取消…';
    _notify();
  }

  Future<void> install() async {
    final candidate = release;
    if (!supportedEdition ||
        _disposed ||
        stage != UpdateStage.ready ||
        candidate == null) {
      return;
    }
    stage = UpdateStage.installValidating;
    message = '正在重新验证安装包…';
    _notify();
    try {
      if (!await _candidateStillNewer(candidate)) return;
      await platform.validate(candidate);
      if (_disposed) return;
      if (windows) {
        final result = await platform.install(candidate);
        if (_disposed) return;
        stage = UpdateStage.ready;
        message = result == 'playing'
            ? '正在播放或准备下一集。请先暂停，再点击安装并重启。'
            : '更新事务已准备，正在保存并重启。';
        _notify();
        return;
      }
      final allowed = await platform.canInstall();
      if (_disposed) return;
      if (!allowed) {
        stage = UpdateStage.permission;
        message = 'Android 需要允许本应用安装更新。只有你能在系统设置中开启';
      } else {
        stage = UpdateStage.installing;
        message = '请在 Android 安装界面确认；返回或取消不会删除观看记录';
        _notify();
        await preferences.setInt('app_update_installing_code', candidate.code);
        if (_disposed) return;
        final result = await platform.install(candidate);
        if (_disposed) return;
        installedApp = await platform.installed();
        if (installedApp!.code >= candidate.code) {
          await _removeFile();
          release = null;
          stage = UpdateStage.idle;
          message = '更新已安装';
        } else {
          stage = UpdateStage.ready;
          message = result == 'cancelled'
              ? '安装已取消，可稍后重试'
              : '已返回应用，尚未确认更新安装，可重试';
        }
      }
    } catch (error) {
      if (_disposed) return;
      stage = UpdateStage.failed;
      message = '无法安装更新：${_error(error)}';
    }
    _notify();
  }

  Future<void> openPermission() async {
    if (stage != UpdateStage.permission) return;
    if (_permissionOpened) return;
    _permissionOpened = true;
    try {
      await platform.openPermission();
    } catch (error) {
      _permissionOpened = false;
      message = '无法打开安装权限设置：${_error(error)}';
      _notify();
    }
  }

  Future<void> returnedFromSettings() async {
    if (stage != UpdateStage.permission || _disposed || !_permissionOpened) {
      return;
    }
    _permissionOpened = false;
    try {
      final allowed = await platform.canInstall();
      if (_disposed || stage != UpdateStage.permission) return;
      stage = UpdateStage.ready;
      message = allowed ? '安装权限已开启，请再次点击安装确认' : '未开启安装权限，可稍后重试安装';
    } catch (error) {
      message = '无法确认安装权限：${_error(error)}';
    }
    _notify();
  }

  void cancelPermission() {
    if (stage != UpdateStage.permission) return;
    _permissionOpened = false;
    stage = UpdateStage.ready;
    message = '已取消权限设置，安装包保留，可稍后安装';
    _notify();
  }

  Future<void> _cleanCompletedUpdate() async {
    final code = preferences.getInt('app_update_installing_code');
    final complete =
        code != null && installedApp != null && installedApp!.code >= code;
    if (_startupCleaned && !complete) return;
    final path = await platform.directory();
    if (_disposed) return;
    _file = File('$path/$_pendingName');
    _partial = File('$path/$_pendingName.part');
    try {
      if (await _partial!.exists()) await _partial!.delete();
    } catch (_) {}
    _startupCleaned = true;
    if (complete) {
      await _removeFile();
      await preferences.remove('app_update_installing_code');
    }
  }

  Future<void> _removeFile() async {
    for (final file in [_file, _partial]) {
      try {
        if (file != null && await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  String _error(Object error) => error is PlatformException
      ? (error.message ?? error.code)
      : error.toString();

  @override
  void dispose() {
    _disposed = true;
    transport.cancel();
    super.dispose();
  }
}
