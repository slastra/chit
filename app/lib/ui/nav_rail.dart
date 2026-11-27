import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/protocol.dart';
import '../data/replica.dart';
import '../state/providers.dart';
import 'shelf.dart';
import 'labels_ui.dart';

/// How the navigation rail shows: collapsed (96dp, icons over labels),
/// expanded beside the content, or expanded as a modal over it.
enum RailMode { collapsed, expanded, modal }

/// The app's navigation, as Material 3 Expressive's navigation rail (which
/// replaces the navigation drawer). To Compose's tokens
/// (NavigationRailCollapsed/Expanded/ColorTokens and the item tokens):
///
/// - collapsed: 96dp wide on surface; each item a 56x32 indicator around
///   its icon with a label-medium label 4dp below, items 4dp apart
/// - expanded: 220 to 360dp wide; each item a 56dp pill hugging its icon
///   and label-large label (16dp, icon, 8dp, label, 16dp), 20dp in from
///   the edge, so icons sit on the same line in both forms
/// - modal: the expanded rail on surface container, its end corners large,
///   at elevation level 2
/// - the menu button on the app bar's line, 40dp between it and the items
/// - the active item: a secondary container indicator, its icon on
///   secondary container, its label secondary; the rest on surface variant
class NavRail extends ConsumerWidget {
  const NavRail({
    super.key,
    required this.mode,
    required this.shelf,
    required this.label,
    required this.onPick,
    required this.onMenu,
    this.footer,
  });

  final RailMode mode;
  final Shelf shelf;
  final String? label;
  final void Function(Shelf shelf, [String? label]) onPick;

  /// The menu button: expand, collapse, or close the modal.
  final VoidCallback onMenu;

  /// Below the items of the expanded rail (the new-note split button).
  final Widget? footer;

  static const collapsedWidth = 96.0;
  static const expandedWidth = 280.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // the labels alone: the rail has nothing to redo for any other change
    final labels = ref.watch(libraryProvider.select((l) => Same(l.value?.labels ?? const <Label>[]))).list;
    final collapsed = mode == RailMode.collapsed;

    void pick(Shelf s, [String? l]) {
      if (mode == RailMode.modal) Navigator.of(context).pop();
      onPick(s, l);
    }

    bool active(Shelf s, [String? l]) => shelf == s && (s != Shelf.labeled || label == l);

    Widget item(Shelf s, {String? id, String? name}) => _RailItem(
      collapsed: collapsed,
      icon: s.icon,
      selectedIcon: s.selectedIcon,
      label: name ?? s.label,
      selected: active(s, id),
      onTap: () => pick(s, id),
    );

    final menu = Padding(
      padding: const EdgeInsetsDirectional.only(start: 24),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: IconButton(
          tooltip: switch (mode) {
            RailMode.collapsed => 'Expand navigation',
            RailMode.expanded => 'Collapse navigation',
            RailMode.modal => 'Close navigation',
          },
          onPressed: onMenu,
          icon: Icon(collapsed ? Icons.menu : Icons.menu_open),
        ),
      ),
    );

    final List<Widget> items;
    if (collapsed) {
      // the shelves, and the label being looked at; the rest of the labels
      // are a tap on the menu button away
      final current = shelf == Shelf.labeled ? labels.where((l) => l.id == label).firstOrNull : null;
      items = [
        item(Shelf.notes),
        item(Shelf.reminders),
        if (current != null) item(Shelf.labeled, id: current.id, name: current.name),
        item(Shelf.archive),
        item(Shelf.trash),
      ];
    } else {
      // section header and divider, on the items' own line
      Widget header(String text) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(36, 16, 20, 8),
        child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
      );
      const divider = Padding(padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4), child: Divider(height: 8));
      items = [
        item(Shelf.notes),
        item(Shelf.reminders),
        divider,
        if (labels.isNotEmpty) header('Labels'),
        for (final l in labels) item(Shelf.labeled, id: l.id, name: l.name),
        _RailItem(
          collapsed: false,
          icon: labels.isEmpty ? Icons.new_label_outlined : Icons.edit_outlined,
          label: labels.isEmpty ? 'Create label' : 'Edit labels',
          selected: false,
          onTap: () {
            if (mode == RailMode.modal) Navigator.of(context).pop();
            unawaited(showEditLabels(context));
          },
        ),
        divider,
        item(Shelf.archive),
        item(Shelf.trash),
      ];
    }

    final content = SafeArea(
      right: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // the token is 44dp, sized to clear a status bar; here the safe
          // area does that, and 12dp puts the menu button on the search
          // bar's center line across the two panes
          const SizedBox(height: 12),
          menu,
          const SizedBox(height: 40),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (_, i) => items[i],
            ),
          ),
          if (footer != null && !collapsed) footer!,
        ],
      ),
    );

    if (mode == RailMode.modal) {
      return Drawer(
        width: expandedWidth,
        backgroundColor: scheme.surfaceContainer,
        elevation: 3,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadiusDirectional.horizontal(end: Radius.circular(16))),
        child: Semantics(container: true, label: 'Navigation', child: content),
      );
    }
    final width = collapsed ? collapsedWidth : expandedWidth;
    // the two forms turn into each other: the width eases, and the new
    // form is laid out at its full width from the start, revealed (or
    // covered) by the moving edge
    return AnimatedContainer(
      duration: Durations.medium4,
      curve: Easing.emphasizedDecelerate,
      width: width,
      color: scheme.surface,
      clipBehavior: Clip.hardEdge,
      child: OverflowBox(
        alignment: AlignmentDirectional.centerStart,
        minWidth: width,
        maxWidth: width,
        child: Semantics(container: true, label: 'Navigation', child: content),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.collapsed,
    required this.icon,
    this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final bool collapsed;
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final iconColor = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    final labelColor = selected ? scheme.secondary : scheme.onSurfaceVariant;
    final glyph = Icon(selected ? (selectedIcon ?? icon) : icon, size: 24, color: iconColor);
    final overlay = WidgetStateProperty.resolveWith(
      (s) => scheme.onSecondaryContainer.withValues(
        alpha: s.contains(WidgetState.pressed) ? 0.1 : (s.contains(WidgetState.hovered) ? 0.08 : 0.1),
      ),
    );

    if (collapsed) {
      // the indicator alone takes the ink; the whole item takes the tap
      return Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: Durations.short4,
                    curve: Easing.standard,
                    width: 56,
                    height: 32,
                    decoration: ShapeDecoration(
                      shape: const StadiumBorder(),
                      color: selected ? scheme.secondaryContainer : Colors.transparent,
                    ),
                    child: glyph,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelMedium?.copyWith(color: labelColor),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Semantics(
          button: true,
          selected: selected,
          child: Material(
            color: selected ? scheme.secondaryContainer : Colors.transparent,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              overlayColor: overlay,
              child: SizedBox(
                height: 56,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      glyph,
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(color: labelColor),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
