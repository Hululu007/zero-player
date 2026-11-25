import 'package:flutter/material.dart';

import '../../../core/network/source_certificate.dart';

Future<bool> confirmBookCertificate(
  BuildContext context,
  SourceCertificateFailure failure,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('HTTPS 证书无法验证'),
        icon: const Icon(Icons.gpp_maybe_outlined),
        scrollable: true,
        content: Text(
          '${failure.origin}\n\n证书指纹\n${failure.fingerprint}\n\n'
          '继续访问可能收到被篡改的内容。仅对此次手动加载及这张证书生效。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('仅临时加载'),
          ),
        ],
      ),
    ) ??
    false;
