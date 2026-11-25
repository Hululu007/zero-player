import 'mobile_public_share.dart';
import 'publication_share_provider.dart';
import 'tianyi_public_share.dart';

final class CloudDriveAccounts {
  String? _baidu;
  MobileCloudAccount? _mobile;
  String? _tianyi;

  MobileCloudAccount? get mobile => _mobile;
  String? get tianyi => _tianyi;

  void useMobile(String phone, String authorization) {
    if (!validMobileCloudAccount(phone, authorization)) {
      throw const FormatException('移动云盘号码或会话凭据格式无效');
    }
    _mobile = (phone: phone, authorization: authorization);
  }

  void useTianyi(String token) {
    if (!validTianyiCloudToken(token)) {
      throw const FormatException('天翼云盘访问令牌格式无效');
    }
    _tianyi = token;
  }

  void clearMobile() => _mobile = null;
  void clearTianyi() => _tianyi = null;

  void clear() {
    clearBaidu();
    clearMobile();
    clearTianyi();
  }

  String? get baiduToken => _baidu;

  void useBaiduToken(String value) {
    if (!validBaiduPublicationToken(value)) {
      throw const FormatException('百度网盘令牌格式无效');
    }
    _baidu = value;
  }

  void clearBaidu() => _baidu = null;
}
