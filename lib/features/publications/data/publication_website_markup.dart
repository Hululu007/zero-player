import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import '../domain/publication.dart';

enum PublicationWebsiteFieldKind { text, email, phone, password, code, check }

typedef PublicationWebsiteLink = ({Uri uri, String label});

bool publicationWebsiteHtml(String? mime) =>
    const {'text/html', 'application/xhtml+xml'}.contains(mime);

typedef PublicationWebsiteField = ({
  String name,
  String label,
  PublicationWebsiteFieldKind kind,
  bool required,
  String checkedValue,
});

final class PublicationWebsiteForm {
  const PublicationWebsiteForm._(
    this._hidden, {
    required this.action,
    required this.label,
    required this.fields,
    this.captcha,
  });

  final Uri action;
  final String label;
  final List<PublicationWebsiteField> fields;
  final Uri? captcha;
  final Map<String, String> _hidden;

  Map<String, String> encode(Map<String, String> input) {
    final values = {..._hidden};
    for (final field in fields) {
      final value = input[field.name] ?? '';
      final checked = field.kind == PublicationWebsiteFieldKind.check;
      if (value.length > 512 ||
          (field.required &&
              (checked ? value != 'true' : value.trim().isEmpty))) {
        throw const FormatException('请填写网站要求的字段');
      }
      if (checked) {
        if (value == 'true') values[field.name] = field.checkedValue;
      } else {
        values[field.name] = value;
      }
    }
    return values;
  }
}

final class PublicationWebsitePage {
  const PublicationWebsitePage({
    required this.uri,
    this.title = '',
    this.links = const [],
    this.forms = const [],
    this.file,
    this.guestLimited = false,
  });

  final Uri uri;
  final String title;
  final List<PublicationWebsiteLink> links;
  final List<PublicationWebsiteForm> forms;
  final PublicationFormat? file;
  final bool guestLimited;
}

final _activeContent = RegExp(
  r'[\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]',
);
final _fieldName = RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]{0,63}$');
final _codeField = RegExp(
  r'captcha|otp|verif|vcode|sms.?code|passcode|^code$',
  caseSensitive: false,
);
final _siteAction = RegExp(
  r'下载|下載|领取|領取|登录|登入|登錄|注册|註冊|验证|驗證|帳號|账号|下一步|download|sign[ -]?(in|up)|log[ -]?in|register|verify|account',
  caseSensitive: false,
);
final _guestLimit = RegExp(
  r'(?:游客|訪客|访客|未登录|未登入|未登錄).{0,24}(?:下載|下载|配額|配额|限額|限额).{0,20}'
  r'(?:已達.{0,4}上限|已达.{0,4}上限|已超[過过出]|超[過过出]限制|耗[盡尽]|用[完尽盡])|'
  r'超[過过出].{0,16}(?:游客|訪客|访客|未登录|未登入|未登錄).{0,18}'
  r'(?:下載|下载|配額|配额|限額|限额).{0,5}(?:上限|限制|配額|配额)|'
  r'\b(?:guest|visitor|anonymous)\b.{0,30}(?:download|quota).{0,26}'
  r'\b(?:exceeded|reached|exhausted|used up)\b',
  caseSensitive: false,
);
final _guestCondition = RegExp(
  r'^(?:如果|若|如遇|当|當|if\b|when\b|whenever\b)',
  caseSensitive: false,
);

String publicationWebsiteLabel(String raw, {int max = 160}) =>
    publicationLabel(raw.replaceAll(_activeContent, ''), max: max);

/// A whitelist of native controls. Nothing in the document executes or
/// resolves a network resource here, including styles, base URLs and frames.
PublicationWebsitePage parsePublicationWebsitePage(
  String body,
  Uri address,
  bool Function(Uri) allowed,
) {
  final document = html.parse(body);
  for (final node in document.querySelectorAll(
    'script, style, template, noscript, iframe, object, embed, svg, canvas, [hidden], [aria-hidden="true"]',
  )) {
    node.remove();
  }
  Uri? target(String? raw) {
    if (raw == null || raw.trim().isEmpty || raw.length > 2048) return null;
    final reference = Uri.tryParse(raw.trim());
    if (reference == null) return null;
    final uri = address.resolveUri(reference).removeFragment();
    return allowed(uri) ? uri : null;
  }

  final links = <Uri, PublicationWebsiteLink>{};
  for (final anchor in document.querySelectorAll('a[href]')) {
    if (links.length >= 16) break;
    final href = anchor.attributes['href'];
    final uri = target(href);
    if (uri == null || uri == address) continue;
    final label = publicationWebsiteLabel(anchor.text, max: 96);
    if (label.isEmpty ||
        !(anchor.attributes.containsKey('download') ||
            _siteAction.hasMatch('$label ${uri.path}') ||
            PublicationFormat.fromName(uri.path) != null ||
            _downloadFormatLabel.hasMatch(label))) {
      continue;
    }
    links.putIfAbsent(uri, () => (uri: uri, label: label));
  }

  return PublicationWebsitePage(
    uri: address,
    title: publicationWebsiteLabel(
      document.querySelector('h1')?.text ??
          document.querySelector('title')?.text ??
          '',
    ),
    links: List.unmodifiable(links.values),
    forms: List.unmodifiable(
      [
        for (final element in document.querySelectorAll('form').take(8))
          ?_parseForm(element, address, target),
      ].take(4),
    ),
    guestLimited: document
        .querySelectorAll('title, h1, h2, h3, [role="alert"], p')
        .take(32)
        .any((node) {
          final message = publicationWebsiteLabel(node.text, max: 256);
          return !_guestCondition.hasMatch(message) &&
              _guestLimit.hasMatch(message);
        }),
  );
}

final _downloadFormatLabel = RegExp(
  r'^(?:epub|pdf|mobi|azw3?|zip)\s*(?:格式)?$',
  caseSensitive: false,
);

PublicationWebsiteForm? _parseForm(
  Element form,
  Uri address,
  Uri? Function(String?) target,
) {
  final attributes = form.attributes;
  final action = attributes['action'];
  final destination = action == null || action.trim().isEmpty
      ? address
      : target(action);
  if (destination == null ||
      attributes['method']?.toLowerCase() != 'post' ||
      !const {'', '_self'}.contains(attributes['target'] ?? '') ||
      (attributes['enctype'] ?? 'application/x-www-form-urlencoded')
              .toLowerCase() !=
          'application/x-www-form-urlencoded' ||
      form.querySelector(
            'select, textarea, [formaction], [formenctype], [formmethod], [formtarget], fieldset[disabled]',
          ) !=
          null) {
    return null;
  }

  final fields = <PublicationWebsiteField>[];
  final names = <String>{};
  final hidden = <String, String>{};
  Element? submit;
  final controls = form.querySelectorAll('input, button');
  if (controls.isEmpty || controls.length > 24) return null;
  for (final control in controls) {
    final attrs = control.attributes;
    if (attrs.containsKey('disabled')) continue;
    if (attrs.containsKey('form') || attrs.containsKey('readonly')) return null;
    final button = control.localName == 'button';
    final type = attrs['type']?.toLowerCase() ?? (button ? 'submit' : 'text');
    if (const {'button', 'reset'}.contains(type)) continue;
    if (type == 'submit') {
      if (submit != null) return null;
      submit = control;
    }
    final name = attrs['name'];
    if (type == 'submit' && name == null) continue;
    if (name == null || !_fieldName.hasMatch(name) || !names.add(name)) {
      return null;
    }
    final value = attrs['value'] ?? '';
    if (type == 'submit' || type == 'hidden') {
      if (value.length > 2048) return null;
      hidden[name] = value;
      continue;
    }
    final kind = _fieldKind(type, name, attrs['autocomplete']);
    if (kind == null || fields.length >= 12 || value.length > 512) return null;
    fields.add((
      name: name,
      label: _fieldLabel(form, control, name),
      kind: kind,
      required:
          attrs.containsKey('required') ||
          kind == PublicationWebsiteFieldKind.password ||
          kind == PublicationWebsiteFieldKind.code,
      checkedValue: value.isEmpty ? 'on' : value,
    ));
  }

  final buttonLabel = publicationWebsiteLabel(
    submit?.localName == 'button'
        ? submit!.text
        : (submit?.attributes['value'] ?? ''),
    max: 64,
  );
  // Prefer recognizable access forms. A mutation such as a comment, payment
  // or upload should be completed in the actual browser.
  final accessForm =
      fields.any(
        (field) => const {
          PublicationWebsiteFieldKind.password,
          PublicationWebsiteFieldKind.code,
        }.contains(field.kind),
      ) ||
      _siteAction.hasMatch('${destination.path} $buttonLabel');
  if (fields.isEmpty || !accessForm || submit == null) return null;

  final captcha = form.querySelector(
    'img[alt*="验证码"], img[alt*="驗證碼"], img[src*="captcha"], img[src*="verifycode"]',
  );
  return PublicationWebsiteForm._(
    Map.unmodifiable(hidden),
    action: destination,
    label: buttonLabel.isEmpty ? '提交网站表单' : buttonLabel,
    fields: List.unmodifiable(fields),
    captcha: target(captcha?.attributes['src']),
  );
}

PublicationWebsiteFieldKind? _fieldKind(
  String type,
  String name,
  String? autocomplete,
) {
  if (type == 'password') return PublicationWebsiteFieldKind.password;
  if (const {'text', 'tel', 'number'}.contains(type) &&
      (autocomplete == 'one-time-code' || _codeField.hasMatch(name))) {
    return PublicationWebsiteFieldKind.code;
  }
  return switch (type) {
    'text' => PublicationWebsiteFieldKind.text,
    'email' => PublicationWebsiteFieldKind.email,
    'tel' => PublicationWebsiteFieldKind.phone,
    'checkbox' => PublicationWebsiteFieldKind.check,
    _ => null,
  };
}

String _fieldLabel(Element form, Element control, String name) {
  final fieldId = control.id;
  final associated = fieldId.isEmpty
      ? null
      : form
            .querySelectorAll('label')
            .where((label) => label.attributes['for'] == fieldId)
            .firstOrNull;
  final text = publicationWebsiteLabel(
    associated?.text ??
        (control.parent?.localName == 'label' ? control.parent?.text : null) ??
        control.attributes['aria-label'] ??
        control.attributes['placeholder'] ??
        name,
    max: 96,
  );
  return text.isEmpty ? name : text;
}
