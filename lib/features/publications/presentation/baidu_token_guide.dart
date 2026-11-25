import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/publication_module.dart';
import '../data/publication_share_provider.dart';
import '../data/publication_store.dart';
import '../domain/acquisition_task.dart';
import '../domain/publication.dart';

const _seenKey = 'baidu_token_guide_seen';
final _showingOrSeen = Expando<bool>();
final _oauthGuide = Uri.https('openauth.baidu.com', '/doc/doc.html');

bool isBaiduTokenRefusal(Uri link, PublicationProblem? problem) =>
    isBaiduPublicationShare(link) &&
    const {
      PublicationProblem.login,
      PublicationProblem.challenge,
      PublicationProblem.guestLimit,
    }.contains(problem);

Future<void> showBaiduTokenGuideOnce(
  BuildContext context,
  PublicationModule module,
  Uri link,
  PublicationProblem? problem, {
  bool Function()? visible,
}) async {
  if (!isBaiduTokenRefusal(link, problem)) return;
  bool canShow() =>
      (visible?.call() ?? true) &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true &&
      module.discovery.allowed(link.host);

  final PublicationStore store = module.store;
  if (_showingOrSeen[store] == true || !context.mounted || !canShow()) return;
  _showingOrSeen[store] = true;
  var seen = false;
  try {
    seen = await store.preference(_seenKey) == '1';
    if (seen || !context.mounted || !canShow()) return;
    await showBaiduTokenGuide(
      context,
      problem: problem,
      allowed: () => module.discovery.allowed(link.host),
    );
    seen = true;
    await store.setPreference(_seenKey, '1');
  } on Exception {
    // Guidance must not replace the original download error.
  } finally {
    _showingOrSeen[store] = seen ? true : null;
  }
}

void scheduleBaiduTaskTokenGuide(
  BuildContext context,
  PublicationModule module,
  List<AcquisitionTask> tasks,
  bool Function() visible,
) {
  final task = tasks
      .where(
        (task) =>
            task.state == AcquisitionState.failed &&
            isBaiduTokenRefusal(task.candidate.link, task.problem),
      )
      .firstOrNull;
  if (task == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    showBaiduTokenGuideOnce(
      context,
      module,
      task.candidate.link,
      task.problem,
      visible: visible,
    );
  });
}

Future<void> showBaiduTokenGuide(
  BuildContext context, {
  PublicationProblem? problem,
  bool Function()? allowed,
}) => showDialog<void>(
  context: context,
  builder: (dialog) => AlertDialog(
    title: const Text('获取百度网盘访问令牌'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (problem != null) Text(problem.label),
          const Text(
            '1. 登录百度网盘开放平台，在你有权使用的应用中开通网盘 API，并配置授权回调地址。\n\n'
            '2. 按百度 OAuth 指南登录并同意网盘授权。应用通过授权码换取令牌后，从返回结果中取出 access_token。请通过你有权使用的应用完成授权，并保管好应用密钥。\n\n'
            '3. 在网盘账号管理中粘贴 access_token，可在本次运行中使用。也可在重试下载时单独输入令牌。\n\n'
            '如果百度仍要求网页验证或限制客户端，打开官方分享页继续处理。',
          ),
          TextButton(
            onPressed: () async {
              if (allowed?.call() == false) return;
              final opened = await launchUrl(
                _oauthGuide,
                mode: LaunchMode.externalApplication,
              ).catchError((Object _) => false);
              if (!opened && dialog.mounted) {
                ScaffoldMessenger.maybeOf(dialog)?.showSnackBar(
                  const SnackBar(content: Text('无法打开百度 OAuth 指南')),
                );
              }
            },
            child: const Text('打开百度 OAuth 指南'),
          ),
        ],
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(dialog),
        child: const Text('知道了'),
      ),
    ],
  ),
);
