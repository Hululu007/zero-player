import 'package:flutter/material.dart';

import '../data/cloud_drive_accounts.dart';
import '../domain/publication.dart';
import 'baidu_token_guide.dart';
import 'publication_dialogs.dart';

Future<void> showCloudDriveAccounts(
  BuildContext context,
  CloudDriveAccounts accounts,
  VoidCallback authorize,
) => showDialog<void>(
  context: context,
  builder: (_) =>
      _CloudDriveAccountsDialog(accounts: accounts, authorize: authorize),
);

final class _CloudDriveAccountsDialog extends StatefulWidget {
  const _CloudDriveAccountsDialog({
    required this.accounts,
    required this.authorize,
  });

  final CloudDriveAccounts accounts;
  final VoidCallback authorize;

  @override
  State<_CloudDriveAccountsDialog> createState() => _CloudDriveAccountsState();
}

final class _CloudDriveAccountsState extends State<_CloudDriveAccountsDialog> {
  String? _message;

  Future<void> _useToken() async {
    final value = await publicationPrompt(
      context,
      '输入百度网盘访问令牌',
      password: true,
      limit: 512,
    );
    if (!mounted || value == null) return;
    try {
      widget.authorize();
      widget.accounts.useBaiduToken(value.trim());
      setState(() => _message = '已添加百度网盘授权');
    } on Exception catch (error) {
      _showError(error);
    }
  }

  void _showError(Exception error) {
    if (!mounted) return;
    setState(
      () => _message = switch (error) {
        FormatException(:final message) => message,
        PublicationFailure(:final problem) => problem.label,
        _ => '暂时无法完成网盘授权',
      },
    );
  }

  Future<void> _useMobile() async {
    final phone = await publicationPrompt(
      context,
      '移动云盘手机号',
      password: true,
      limit: 11,
    );
    if (!mounted || phone == null) return;
    final authorization = await publicationPrompt(
      context,
      '移动云盘会话凭据',
      instructions: '输入本人已登录会话签发的 Authorization 值，包含 Basic 前缀。',
      password: true,
      limit: 4102,
    );
    if (!mounted || authorization == null) return;
    try {
      widget.authorize();
      widget.accounts.useMobile(phone.trim(), authorization.trim());
      setState(() => _message = '已添加移动云盘会话');
    } on Exception catch (error) {
      _showError(error);
    }
  }

  Future<void> _useTianyi() async {
    final token = await publicationPrompt(
      context,
      '天翼云盘访问令牌',
      instructions: '输入本人天翼云盘已登录会话签发的 AccessToken。',
      password: true,
      limit: 2048,
    );
    if (!mounted || token == null) return;
    try {
      widget.authorize();
      widget.accounts.useTianyi(token.trim());
      setState(() => _message = '已添加天翼云盘会话');
    } on Exception catch (error) {
      _showError(error);
    }
  }

  Widget _session(
    String name,
    bool active,
    VoidCallback add,
    VoidCallback remove,
  ) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(name),
      subtitle: Text(active ? '已添加会话' : '未添加会话'),
      leading: active
          ? IconButton(
              tooltip: '移除$name会话',
              onPressed: () {
                remove();
                setState(() => _message = null);
              },
              icon: const Icon(Icons.logout),
            )
          : null,
      trailing: TextButton(onPressed: add, child: Text(active ? '更换' : '添加')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = widget.accounts.baiduToken != null;
    return AlertDialog(
      title: const Text('网盘账号管理'),
      scrollable: true,
      content: SizedBox(
        width: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('百度网盘 · ${signedIn ? '已授权' : '未授权'}'),
            const Text('账号授权和会话仅保留在本次运行中。'),
            if (_message case final String message) Text(message),
            Wrap(
              children: [
                TextButton(
                  onPressed: () => showBaiduTokenGuide(
                    context,
                    allowed: () {
                      try {
                        widget.authorize();
                        return true;
                      } on PublicationFailure {
                        return false;
                      }
                    },
                  ),
                  child: const Text('如何获取令牌'),
                ),
                TextButton(
                  onPressed: _useToken,
                  child: Text(signedIn ? '更换令牌' : '添加访问令牌'),
                ),
                if (signedIn)
                  TextButton(
                    onPressed: () {
                      widget.accounts.clearBaidu();
                      setState(() => _message = null);
                    },
                    child: const Text('移除授权'),
                  ),
              ],
            ),
            const Divider(),
            _session(
              '天翼云盘',
              widget.accounts.tianyi != null,
              _useTianyi,
              widget.accounts.clearTianyi,
            ),
            _session(
              '移动云盘',
              widget.accounts.mobile != null,
              _useMobile,
              widget.accounts.clearMobile,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
