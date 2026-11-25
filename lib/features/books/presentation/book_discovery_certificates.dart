part of 'book_discovery_view.dart';

extension _BookDiscoveryCertificates on _BookDiscoveryViewState {
  String _listingFailure(Exception error) {
    _siteAccessDenied = false;
    if (error is SourceCertificateFailure) {
      _certificateError = error;
      _temporaryCertificate = null;
      return error.message;
    }
    _siteAccessDenied =
        error is RemoteFailure &&
        error.status == 403 &&
        _source?.source.endpoint.host == 'czbooks.net';
    if (_siteAccessDenied) return '小说狂人拒绝应用请求（HTTP 403）';
    return _loadMessage(error);
  }

  Future<void> _confirmTemporaryCertificate() async {
    final sourceId = _sourceId;
    final failure = _certificateError;
    if (sourceId == null || failure == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        icon: const Icon(Icons.gpp_maybe_outlined),
        title: const Text('HTTPS 证书无法验证'),
        content: Text(
          '${failure.origin}\n\n证书指纹\n${failure.fingerprint}\n\n'
          '继续访问可能读取到被篡改的目录。临时加载只在本次浏览内对这张证书有效。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('记住并临时加载'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('仅临时加载'),
          ),
        ],
      ),
    );
    if (!mounted ||
        confirmed == null ||
        _sourceId != sourceId ||
        !widget.repository.canConfirmCertificate(sourceId, failure)) {
      return;
    }
    if (confirmed) {
      try {
        final saved = await runSensitive(
          context,
          widget.repository.policy.supervision,
          SensitiveOperation.settings,
          () => widget.repository.rememberSourceCertificate(sourceId, failure),
        );
        if (!saved || !mounted || _sourceId != sourceId) return;
      } on Exception {
        if (mounted) _updateToolbar(() => _error = '保存证书确认失败');
        return;
      }
    }
    _temporaryCertificate = failure;
    await _load();
  }

  Widget? _certificateNotice() {
    final failure = _certificateError;
    final id = _sourceId;
    final source = _source?.source;
    if (_siteAccessDenied &&
        source?.endpoint.host == 'czbooks.net' &&
        widget.repository.certificateExceptionsAvailable) {
      return ListTile(
        leading: const Icon(Icons.open_in_browser),
        title: const Text('小说狂人 · 网页访问'),
        trailing: TextButton(
          onPressed: () {
            if (widget.repository.certificateExceptionsAvailable &&
                _source?.source.id == source!.id) {
              launchUrl(source.endpoint, mode: LaunchMode.externalApplication);
            }
          },
          child: const Text('在浏览器打开'),
        ),
      );
    }
    if (id != null && failure != null) {
      return ListTile(
        leading: const Icon(Icons.gpp_maybe_outlined),
        title: const Text('HTTPS 证书无法验证'),
        subtitle: Text(failure.origin),
        trailing: widget.repository.canConfirmCertificate(id, failure)
            ? TextButton(
                onPressed: _busy ? null : _confirmTemporaryCertificate,
                child: const Text('临时加载'),
              )
            : null,
      );
    }
    if (id == null && _certificateFailures.isNotEmpty) {
      return ListTile(
        leading: const Icon(Icons.gpp_maybe_outlined),
        title: Text('${_certificateFailures.length} 个渠道因 HTTPS 证书校验失败而跳过'),
        trailing: TextButton(
          onPressed: widget.onManage,
          child: const Text('证书设置'),
        ),
      );
    }
    return null;
  }
}
