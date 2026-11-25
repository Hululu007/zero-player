import 'package:flutter/material.dart';

import '../data/book_source_groups.dart';
import '../data/books_repository.dart';

Future<({String? id})?> pickBookSourceGroup(
  BuildContext context,
  BooksRepository repository,
  List<BookSourceGroup> groups,
  String? selected, {
  VoidCallback? manage,
}) => showDialog<({String? id})>(
  context: context,
  builder: (dialog) => ListenableBuilder(
    listenable: repository.policy,
    builder: (context, _) {
      final shown = groups
          .where((group) => repository.policy.textAllowed(group.name))
          .toList();
      return AlertDialog(
        title: const Text('选择渠道分组'),
        content: SizedBox(
          width: 440,
          height: MediaQuery.sizeOf(context).height * .42,
          child: ListView.builder(
            itemCount: shown.length + 1,
            itemBuilder: (_, index) {
              final group = index == 0 ? null : shown[index - 1];
              return ListTile(
                title: Text(group?.name ?? '全部渠道'),
                trailing: selected == group?.id
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(dialog, (id: group?.id)),
              );
            },
          ),
        ),
        actions: [
          if (manage != null)
            TextButton(
              onPressed: () {
                Navigator.pop(dialog);
                manage();
              },
              child: const Text('管理分组'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  ),
);
