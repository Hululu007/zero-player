import 'package:flutter/material.dart';

import 'reading_navigation.dart';

/// Less frequent destinations remain reachable in the full navigation menu.
final class MobileBottomNavigation extends StatelessWidget {
  const MobileBottomNavigation({
    super.key,
    required this.location,
    required this.onNavigate,
    required this.onMore,
  });
  final String location;
  final ValueChanged<String> onNavigate;
  final VoidCallback onMore;
  static const _routes = ['/', '/live', '/music'];

  Future<void> _openReading(BuildContext context) async {
    final route = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            for (final (path, label, icon) in readingDestinations)
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                selected: location == path,
                trailing: location == path ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(sheet).pop(path),
              ),
          ],
        ),
      ),
    );
    if (route != null && context.mounted) onNavigate(route);
  }

  @override
  Widget build(BuildContext context) {
    final selected = isReadingDestination(location)
        ? 3
        : _routes.indexOf(location);
    return NavigationBar(
      key: const ValueKey('mobile-bottom-navigation'),
      height: 60,
      selectedIndex: selected < 0 ? 4 : selected,
      labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
      onDestinationSelected: (index) => switch (index) {
        3 when selected != 3 => onNavigate(readingDestinations.first.$1),
        3 => _openReading(context),
        4 => onMore(),
        _ => onNavigate(_routes[index]),
      },
      destinations: const [
        NavigationDestination(icon: Icon(Icons.movie_outlined), label: '影院'),
        NavigationDestination(icon: Icon(Icons.live_tv), label: '直播'),
        NavigationDestination(
          icon: Icon(Icons.library_music_outlined),
          label: '音乐',
        ),
        NavigationDestination(icon: Icon(readingIcon), label: '阅读'),
        NavigationDestination(icon: Icon(Icons.menu), label: '更多'),
      ],
    );
  }
}
