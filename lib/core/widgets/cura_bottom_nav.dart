import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import 'cura_spark.dart';

/// The four primary destinations, in bar order. The center scan FAB sits in the
/// visual gap between [timeline] and [ask].
enum CuraTab { home, timeline, ask, settings }

/// Shared app-shell bottom navigation bar.
///
/// A host screen wires it up like this:
/// ```dart
/// Scaffold(
///   bottomNavigationBar: CuraBottomNavBar(current: CuraTab.home, onSelect: ...),
///   floatingActionButton: CuraScanFab(onPressed: ...),
///   floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
/// )
/// ```
/// `centerDocked` lets the FAB sit elevated over the bar without manual stacking.
class CuraBottomNavBar extends StatelessWidget {
  const CuraBottomNavBar({
    super.key,
    required this.current,
    required this.onSelect,
  });

  final CuraTab current;
  final ValueChanged<CuraTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              _NavItem(
                icon: Icons.home_outlined,
                label: 'Home',
                tab: CuraTab.home,
                current: current,
                onSelect: onSelect,
              ),
              _NavItem(
                icon: Icons.view_timeline_outlined,
                label: 'Timeline',
                tab: CuraTab.timeline,
                current: current,
                onSelect: onSelect,
              ),
              // Gap for the elevated center scan FAB.
              const SizedBox(width: 72),
              _NavItem(
                customIcon: const CuraSpark(size: 34),
                label: 'Ask',
                tab: CuraTab.ask,
                current: current,
                onSelect: onSelect,
              ),
              _NavItem(
                icon: Icons.settings_outlined,
                label: 'Settings',
                tab: CuraTab.settings,
                current: current,
                onSelect: onSelect,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    this.icon,
    this.customIcon,
    required this.label,
    required this.tab,
    required this.current,
    required this.onSelect,
  }) : assert(
         (icon == null) != (customIcon == null),
         'Provide either icon or customIcon, but not both.',
       );

  final IconData? icon;
  final Widget? customIcon;
  final String label;
  final CuraTab tab;
  final CuraTab current;
  final ValueChanged<CuraTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final active = tab == current;
    final color = active ? AppColors.accent : AppColors.faint;

    return Expanded(
      child: InkResponse(
        onTap: () => onSelect(tab),
        radius: 36,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            customIcon ?? Icon(icon, size: 23, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                fontVariations: const [FontVariation('wght', 500)],
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The elevated center add-document action. Use with
/// [FloatingActionButtonLocation.centerDocked].
class CuraAddFab extends StatelessWidget {
  const CuraAddFab({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 58,
      height: 58,
      decoration: BoxDecoration(
        color: AppColors.accent,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withValues(alpha: 0.32),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: const Icon(Icons.add, color: AppColors.canvas, size: 26),
        ),
      ),
    );
  }
}
