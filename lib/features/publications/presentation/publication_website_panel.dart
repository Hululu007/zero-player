import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/cancellation_token.dart';
import '../application/publication_website_access.dart';
import '../data/publication_website_markup.dart';
import '../data/publication_website_target.dart';
import '../domain/publication.dart';
import 'publication_dialogs.dart';

Future<bool> showPublicationWebsite(
  BuildContext context,
  PublicationWebsiteAccess access,
  PublicationWebsiteTarget target,
  Future<String> Function(PublicationWebsiteSession) download,
) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WebsitePanel(access, target, download),
    ) ??
    false;

class _WebsitePanel extends StatefulWidget {
  const _WebsitePanel(this.access, this.target, this.download);

  final PublicationWebsiteAccess access;
  final PublicationWebsiteTarget target;
  final Future<String> Function(PublicationWebsiteSession) download;

  @override
  State<_WebsitePanel> createState() => _WebsitePanelState();
}

class _WebsitePanelState extends State<_WebsitePanel> {
  PublicationWebsiteSession? _session;
  PublicationWebsitePage? _page;
  List<PublicationWebsiteAccount> _accounts = [];
  String _account = '';
  String? _message;
  VoidCallback? _unlisten;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(
      _run(() async {
        _accounts = await widget.access.accounts(widget.target);
        if (mounted) await _start();
      }),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on Exception catch (error) {
      if (mounted) setState(() => _message = _websiteMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _endSession() {
    _unlisten?.call();
    _unlisten = null;
    _session?.close();
    _session = null;
  }

  Future<void> _start() async {
    _endSession();
    _page = null;
    final session = await widget.access.open(
      widget.target,
      account: _account.isEmpty ? null : _account,
    );
    if (!mounted) {
      session.close();
      return;
    }
    _session = session;
    _unlisten = session.lifetime.listen(() {
      if (!mounted) return;
      setState(() {
        _page = null;
        _message = '网站会话已关闭';
      });
    });
    _page = await session.open();
  }

  Future<void> _openSystemBrowser() async {
    await widget.access.check(widget.target);
    if (!mounted) return;
    if (!await launchUrl(
      widget.target.address,
      mode: LaunchMode.externalApplication,
    )) {
      throw const FormatException('无法打开系统浏览器');
    }
  }

  Future<void> _submit(PublicationWebsiteForm form) async {
    final session = _session;
    if (session == null) return;
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _WebsiteFormFields(session, form),
    );
    if (!mounted || values == null) return;
    await _run(() async {
      _page = null;
      _page = await session.submit(form, values);
    });
  }

  Future<void> _manage() async {
    await showPublicationWebsiteAccounts(
      context,
      widget.access,
      target: widget.target,
    );
    if (!mounted) return;
    await _run(() async {
      _accounts = await widget.access.accounts(widget.target);
      if (!mounted) return;
      if (_account.isNotEmpty &&
          !_accounts.any((item) => item.id == _account)) {
        _account = '';
      }
      if (_session?.lifetime.isCancelled != false) await _start();
    });
  }

  Future<void> _download() async {
    final session = _session;
    if (session == null) return;
    await _run(() async {
      await widget.download(session);
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  @override
  void dispose() {
    _endSession();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.target;
    final page = _page;
    final session = _session;
    final available = session != null && !session.lifetime.isCancelled;
    final canDownload = available && page != null && !page.guestLimited;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: const Text('网站操作'),
              subtitle: Text(target.origin, textDirection: TextDirection.ltr),
              trailing: IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      DropdownButton<String>(
                        hint: const Text('选择网站账号'),
                        value: _account,
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text('临时会话'),
                          ),
                          for (final account in _accounts)
                            DropdownMenuItem(
                              value: account.id,
                              child: Text(
                                account.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        selectedItemBuilder: (context) => [
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text('临时会话'),
                          ),
                          for (final account in _accounts)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 144,
                                ),
                                child: Text(
                                  account.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) {
                                if (value == null || value == _account) return;
                                _account = value;
                                unawaited(_run(_start));
                              },
                      ),
                      TextButton(
                        onPressed: _busy ? null : _manage,
                        child: const Text('管理账号'),
                      ),
                    ],
                  ),
                  if (_message case final message?)
                    Text(
                      message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (page != null) ...[
                    if (page.title.isNotEmpty)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(page.title),
                      ),
                    if (page.guestLimited)
                      Text(PublicationProblem.guestLimit.label),
                    for (final link in page.links)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(link.label),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _busy || !available
                            ? null
                            : () => _run(() async {
                                _page = null;
                                _page = await session.follow(link);
                              }),
                      ),
                    for (final form in page.forms)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.edit_outlined),
                        title: Text(form.label),
                        onTap: _busy || !available ? null : () => _submit(form),
                      ),
                    if (page.links.isEmpty &&
                        page.forms.isEmpty &&
                        page.file == null)
                      const Text('此页没有可用表单。需要加载完整网页时，可在系统浏览器继续。'),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                alignment: WrapAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => _run(_start),
                    child: const Text('重新打开网站'),
                  ),
                  if (available &&
                      target.task.candidate.link != target.address &&
                      page?.uri != target.address)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              _page = await session.openBookPage();
                            }),
                      child: const Text('打开书目页'),
                    ),
                  TextButton(
                    onPressed: _busy ? null : () => _run(_openSystemBrowser),
                    child: const Text('在系统浏览器打开'),
                  ),
                  if (canDownload)
                    FilledButton(
                      onPressed: _busy ? null : _download,
                      child: Text('下载 ${target.format.label}'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WebsiteFormFields extends StatefulWidget {
  const _WebsiteFormFields(this.session, this.form);
  final PublicationWebsiteSession session;
  final PublicationWebsiteForm form;

  @override
  State<_WebsiteFormFields> createState() => _WebsiteFormFieldsState();
}

class _WebsiteFormFieldsState extends State<_WebsiteFormFields> {
  final _formKey = GlobalKey<FormState>();
  final _checked = <String>{};
  late final _text = {
    for (final field in widget.form.fields)
      if (field.kind != PublicationWebsiteFieldKind.check)
        field.name: TextEditingController(),
  };
  late final Future<Uint8List>? _image;
  late final VoidCallback _unlisten;
  bool _imagePending = false;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _imagePending = widget.form.captcha != null;
    _image = _imagePending ? _loadImage() : null;
    _unlisten = widget.session.lifetime.listen(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).pop();
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  Future<Uint8List> _loadImage() async {
    try {
      return await widget.session.captcha(widget.form);
    } finally {
      if (mounted) setState(() => _imagePending = false);
    }
  }

  void _submit() {
    if (_submitted ||
        _imagePending ||
        widget.session.lifetime.isCancelled ||
        _formKey.currentState?.validate() != true) {
      return;
    }
    _submitted = true;
    Navigator.of(context).pop({
      for (final entry in _text.entries) entry.key: entry.value.text,
      for (final name in _checked) name: 'true',
    });
  }

  @override
  void dispose() {
    _unlisten();
    for (final controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.form.label),
    content: Form(
      key: _formKey,
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.session.target.origin,
              textDirection: TextDirection.ltr,
            ),
            if (_image case final image?)
              FutureBuilder<Uint8List>(
                future: image,
                builder: (_, snapshot) => switch (snapshot) {
                  AsyncSnapshot(:final data?) => Image.memory(
                    data,
                    height: 72,
                    fit: BoxFit.contain,
                    semanticLabel: '网站验证码',
                  ),
                  _ when snapshot.hasError => const Text('验证码图片无法显示'),
                  _ => const LinearProgressIndicator(minHeight: 2),
                },
              ),
            for (final field in widget.form.fields) _field(field),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _imagePending ? null : _submit,
        child: const Text('提交到网站'),
      ),
    ],
  );

  Widget _field(PublicationWebsiteField field) {
    if (field.kind == PublicationWebsiteFieldKind.check) {
      return FormField<bool>(
        initialValue: false,
        validator: (value) => field.required && value != true ? '此项为必选' : null,
        builder: (state) => CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(field.label),
          subtitle: state.errorText == null ? null : Text(state.errorText!),
          value: state.value,
          onChanged: (value) {
            if (value == true) {
              _checked.add(field.name);
            } else {
              _checked.remove(field.name);
            }
            state.didChange(value);
          },
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextFormField(
        controller: _text[field.name],
        decoration: InputDecoration(labelText: field.label),
        keyboardType: switch (field.kind) {
          PublicationWebsiteFieldKind.email => TextInputType.emailAddress,
          PublicationWebsiteFieldKind.phone => TextInputType.phone,
          _ => TextInputType.text,
        },
        obscureText: const {
          PublicationWebsiteFieldKind.password,
          PublicationWebsiteFieldKind.code,
        }.contains(field.kind),
        enableSuggestions: false,
        autocorrect: false,
        enableIMEPersonalizedLearning: false,
        maxLength: 512,
        buildCounter:
            (_, {required currentLength, required isFocused, maxLength}) =>
                null,
        validator: (value) =>
            field.required && (value?.trim().isEmpty ?? true) ? '请填写此字段' : null,
      ),
    );
  }
}

String _websiteMessage(Exception error) => switch (error) {
  PublicationFailure(:final problem) => problem.label,
  RequestCancelled() => '网站会话已关闭',
  TimeoutException() => PublicationProblem.timeout.label,
  IOException() => PublicationProblem.network.label,
  FormatException(:final message)
      when const {
        '请填写网站要求的字段',
        '请输入账号备注',
        '站点账号数量已达上限',
        '无法打开系统浏览器',
      }.contains(message) =>
    message,
  _ => '网站操作未完成',
};

Future<void> showPublicationWebsiteAccounts(
  BuildContext context,
  PublicationWebsiteAccess access, {
  PublicationWebsiteTarget? target,
}) => showDialog<void>(
  context: context,
  builder: (_) => _WebsiteAccounts(access, target),
);

class _WebsiteAccounts extends StatefulWidget {
  const _WebsiteAccounts(this.access, this.target);
  final PublicationWebsiteAccess access;
  final PublicationWebsiteTarget? target;

  @override
  State<_WebsiteAccounts> createState() => _WebsiteAccountsState();
}

class _WebsiteAccountsState extends State<_WebsiteAccounts> {
  late Future<List<PublicationWebsiteAccount>> _accounts = widget.access
      .accounts(widget.target);
  bool _busy = false;
  String? _error;

  Future<void> _change(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) {
        final refreshed = widget.access.accounts(widget.target);
        setState(() {
          _accounts = refreshed;
        });
      }
    } on Exception catch (error) {
      if (mounted) setState(() => _error = _websiteMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([PublicationWebsiteAccount? account]) async {
    final value = await publicationPrompt(
      context,
      '账号备注',
      initial: account?.name ?? '',
      limit: 64,
    );
    if (value == null || !mounted) return;
    final target = widget.target;
    if (account == null && target != null) {
      await _change(() => widget.access.addAccount(target, value));
    } else if (account != null) {
      await _change(() => widget.access.renameAccount(account, value));
    }
  }

  Future<void> _remove(PublicationWebsiteAccount account) async {
    final confirmed = await confirmPublicationDelete(
      context,
      '移除此账号记录？',
      '本机的账号备注和会话将被清除。',
    );
    if (confirmed && mounted) {
      await _change(() => widget.access.removeAccount(account));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('网站账号'),
    content: SizedBox(
      width: 480,
      child: FutureBuilder<List<PublicationWebsiteAccount>>(
        future: _accounts,
        builder: (context, snapshot) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.target case final site?)
              Text(site.origin, textDirection: TextDirection.ltr),
            const Text('账号记录只保存备注。会话保留到本次运行结束。'),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            if (_error case final error?) Text(error),
            if (snapshot.hasError)
              const Text('无法读取网站账号')
            else if (snapshot.connectionState != ConnectionState.done)
              const LinearProgressIndicator(minHeight: 2)
            else
              for (final account
                  in snapshot.data ?? const <PublicationWebsiteAccount>[])
                _accountTile(account),
            if (snapshot.connectionState == ConnectionState.done &&
                snapshot.data?.isEmpty == true)
              Text(
                widget.target == null
                    ? '游客下载被站点拒绝后，可在任务的「网站操作」中添加账号。'
                    : '暂无账号记录',
              ),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.target != null)
        FilledButton(
          onPressed: _busy ? null : () => _edit(),
          child: const Text('添加账号'),
        ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('完成'),
      ),
    ],
  );

  Widget _accountTile(PublicationWebsiteAccount account) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(account.name),
    subtitle: Text(account.origin, textDirection: TextDirection.ltr),
    trailing: PopupMenuButton<String>(
      tooltip: '管理此账号',
      enabled: !_busy,
      onSelected: (action) {
        switch (action) {
          case 'rename':
            unawaited(_edit(account));
          case 'clear':
            widget.access.clearAccount(account.id);
            setState(() {});
          case 'remove':
            unawaited(_remove(account));
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'rename', child: Text('修改备注')),
        if (widget.access.hasSession(account.id))
          const PopupMenuItem(value: 'clear', child: Text('清除本机会话')),
        const PopupMenuItem(value: 'remove', child: Text('移除账号记录')),
      ],
    ),
  );
}
