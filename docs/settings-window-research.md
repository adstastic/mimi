# macOS settings-window research

## Bottom line

Apple does **not** specify a numeric maximum for settings. It does say to minimize them, choose defaults that work for most people, avoid redundant system settings and automatically discoverable setup questions, keep task-specific options with the task, and reserve the settings area for general options that change infrequently. A config-file schema is therefore not a checklist for the graphical settings window.

For a conventional macOS app, Apple's stated pattern is a Settings item in the App menu (Command-Comma), opening a settings window whose stable, noncustomizable toolbar switches among panes of related settings. SwiftUI's `Settings` scene implements the scene/menu/window lifecycle, `Form` supplies platform-appropriate control layout, and Apple's `Settings` example uses `TabView` to divide General and Advanced collections. A sidebar-style `NavigationSplitView` is technically available, but is better treated as an alternative for an unusually broad hierarchy rather than the default compact settings design.

## Evidence boundary

- **Apple-stated guidance** below is directly stated or demonstrated in current Apple HIG or SwiftUI documentation.
- **Synthesis** is an interpretation for product decisions. Apple does not publish a rule such as “show at most N settings,” a threshold at which a settings window must gain search, or a requirement that every config key have a control.

## Apple-stated guidance

### 1. Which and how many settings

Apple's [Settings HIG](https://developer.apple.com/design/human-interface-guidelines/settings) says to:

- choose defaults that give the best experience to the largest number of people;
- **minimize the number of settings**, because too many make an app less approachable and make individual settings hard to find;
- avoid asking for setup information the app can detect in another way;
- respect systemwide settings and avoid redundant app-specific copies of them;
- put **general, infrequently changed** options in the custom settings area; and
- put task-specific options in the view or task they affect, where they remain contextual and their results are visible.

Apple gives no numeric cap. It describes a selection principle, not a one-control-per-capability requirement.

### 2. macOS entry point, categories, and navigation

The macOS section of the [Settings HIG](https://developer.apple.com/design/human-interface-guidelines/settings#macOS) says:

- include Settings in the App menu rather than adding a settings button to the main window toolbar;
- a typical settings window uses toolbar buttons to switch among *panes*, each containing related settings;
- keep that toolbar visible and noncustomizable, and always indicate its active item;
- update the window title for the visible pane (or use “App Name Settings” for one pane); and
- restore the most recently viewed pane.

For implementation, Apple's [`Settings` scene](https://developer.apple.com/documentation/swiftui/settings) enables the Settings menu item and lets SwiftUI manage presenting and removing the settings window. Its example shows that settings may be one view or grouped into collections with [`TabView`](https://developer.apple.com/documentation/swiftui/tabview); the example collections are “General” and “Advanced.” This is an API demonstration that an Advanced collection is supported, not a HIG instruction that every app needs one.

Apple's [`Form`](https://developer.apple.com/documentation/swiftui/form) is specifically a container for grouping data-entry controls in settings and inspectors. It applies platform-appropriate styling: on macOS, Apple describes forms as aligned vertical stacks rather than the grouped-list appearance used on iOS.

Apple also documents broader hierarchical navigation tools:

- [`NavigationSplitView`](https://developer.apple.com/documentation/swiftui/navigationsplitview) presents two or three columns, with selection in a leading column controlling later detail columns; it commonly coordinates with a selectable [`List`](https://developer.apple.com/documentation/swiftui/list).
- The [Sidebars HIG](https://developer.apple.com/design/human-interface-guidelines/sidebars) describes a sidebar as a broad, flat view of peer areas that consumes substantial horizontal and vertical space. It recommends at most two hierarchy levels in a sidebar and succinct group labels.
- The [Lists and tables HIG](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables) says lists can express information hierarchy and navigation, and that a navigational list should persistently highlight the selected row.

These are valid APIs and patterns, but the settings-specific HIG still names toolbar panes as the typical macOS settings-window pattern.

### 3. Window size, resizability, and scrolling

The macOS [Settings HIG](https://developer.apple.com/design/human-interface-guidelines/settings#macOS) says to dim the minimize and maximize buttons. Its rationale is that the window is quick to reopen and “accommodates the size of the current pane,” so people do not need to enlarge it to reveal more.

SwiftUI's sizing behavior aligns with that guidance:

- [`windowResizability(_:)`](https://developer.apple.com/documentation/swiftui/scene/windowresizability(_:)) controls the minimum/maximum restrictions for windows from a scene. With the default `.automatic` strategy, a `Settings` scene uses `.contentSize`.
- [`WindowResizability.contentSize`](https://developer.apple.com/documentation/swiftui/windowresizability/contentsize) makes the window's minimum and maximum sizes match the content's minimum and maximum sizes. Content layout constraints therefore define whether and how much the settings window can resize.
- [`defaultSize(width:height:)`](https://developer.apple.com/documentation/swiftui/scene/defaultsize(width:height:)) also applies to `Settings` scenes, but only requests the initial size. People may later resize a resizable window, and state restoration uses its last size instead of the default.
- Apple's [`Settings` example](https://developer.apple.com/documentation/swiftui/settings) applies `.scenePadding()` and explicit frame constraints to its tabbed content, demonstrating that the settings content can establish its desired window geometry.

When content genuinely exceeds its viewport, [`ScrollView`](https://developer.apple.com/documentation/swiftui/scrollview) provides platform-appropriate horizontal and/or vertical scrolling. The [Scroll views HIG](https://developer.apple.com/design/human-interface-guidelines/scroll-views) says to make scrollability apparent because indicators are not always visible, preserve standard gestures and shortcuts, and avoid nesting scroll views with the same orientation. The general [Layout HIG](https://developer.apple.com/design/human-interface-guidelines/layout#macOS) also warns against putting critical information or controls at a macOS window's bottom because people sometimes position that edge offscreen.

Apple does not state that a settings pane may never scroll. It does, however, establish content-fitting panes as the normal macOS settings behavior; `ScrollView` is the mechanism when a bounded pane still needs overflow.

### 4. Progressive disclosure and advanced options

The [Layout HIG](https://developer.apple.com/design/human-interface-guidelines/layout#Visual-hierarchy) recommends progressive disclosure when not everything can be visible, using disclosure controls or partial content that signals more is available.

More specifically, the [Disclosure controls HIG](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls) says to put the controls people are most likely to use at the top of the disclosure hierarchy, always visible, and hide more advanced functionality by default. It says disclosure labels should describe what is revealed, such as “Advanced Options,” and cautions that multiple disclosure buttons add complexity and can be confusing.

SwiftUI's [`DisclosureGroup`](https://developer.apple.com/documentation/swiftui/disclosuregroup) provides a labeled control that expands and collapses its content.

### 5. Search

Apple has no settings-specific rule requiring search. Its general [Searching HIG](https://developer.apple.com/design/human-interface-guidelines/searching) says:

- if search is important, consider making it a primary action;
- aim for one clearly identified place to search app content;
- indicate the searchable content and current scope with prompt text, scope controls, or a title; and
- consider suggestions when they help people search faster.

SwiftUI's [search-interface documentation](https://developer.apple.com/documentation/swiftui/adding-a-search-interface-to-your-app) says to apply `.searchable` to a `NavigationSplitView`, `NavigationStack`, or a view inside one; on macOS, automatic placement puts the search field at the trailing edge of the toolbar. The modifier takes a text binding used to perform filtering, and its prompt can clarify scope.

## Synthesis for a macOS settings design

### Curate the UI; do not mirror the config file

**No, every config-file option should not automatically appear in the UI.** That conclusion is synthesis, but follows directly from Apple's instructions to minimize settings, provide strong defaults, detect what can be detected, avoid systemwide duplicates, and move task-specific options into context.

A useful inclusion test is:

1. Is this a user goal rather than an implementation knob?
2. Is it general to the app, yet changed infrequently enough to belong in Settings?
3. Is it valuable to a meaningful share of users and understandable without internal knowledge?
4. Can it be changed safely with immediate validation and a sensible default?
5. Is Settings more appropriate than an in-context control, automatic behavior, or the system setting?

If not, leave it out of the graphical window. A config file can remain the deliberate expert escape hatch for experimental, compatibility, diagnostic, very rare, or fine-grained options. “Supported by the parser” and “deserves permanent UI” are different product commitments.

The UI and file should still edit one validated domain model where they overlap, so the same option does not acquire divergent defaults, names, or semantics. That is engineering synthesis, not an Apple HIG mandate.

### Navigation choice

- **Small coherent set:** one `Form`, no navigation.
- **A few stable peer categories:** `Settings` + `TabView`, matching Apple's settings-specific toolbar-pane example. Use short category names, keep the active pane visible, and remember selection.
- **Many categories or a broader hierarchy:** consider `NavigationSplitView` with a selectable sidebar `List`, but accept the larger minimum window and keep the hierarchy shallow. This is a deviation from the compact toolbar-pane default justified by information scale, not aesthetics.
- Do not add categories merely to make an oversized option inventory look organized; first remove, automate, contextualize, or disclose options.

### Advanced settings and disclosure

Use “Advanced” in one of two ways:

- as a stable pane for a coherent set of less-common, app-wide expert controls; or
- as a `DisclosureGroup` immediately beside the setting it qualifies.

Prefer local disclosure for dependent detail. Keep the common choice visible, hide subordinate tuning, and avoid deeply nested or numerous disclosure groups. A generic Advanced dumping ground is still an uncurated settings list.

### Size and scrolling

Let each pane express a comfortable content size and preserve SwiftUI's content-driven Settings resizability unless there is a tested reason not to. Avoid one huge fixed window sized for the tallest possible pane. If a pane cannot fit common displays after curation and disclosure, bound its viewport and use one obvious vertical scroll region; do not nest it inside another vertical scroller. Keep critical controls away from the bottom edge.

### Search threshold

Search is justified when people are likely to know a setting exists but cannot reliably predict its category, even after the inventory and labels are simplified. It should not be used to excuse exposing every config key. If added, use one settings-wide search location, search user-facing labels and help text, show scope clearly, and take a result directly to (and, if necessary, reveal) the setting. This threshold and result behavior are synthesis; Apple supplies generic search principles and APIs, not a settings-specific trigger.

## Primary sources

- Apple HIG: [Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
- Apple HIG: [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- Apple HIG: [Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)
- Apple HIG: [Searching](https://developer.apple.com/design/human-interface-guidelines/searching)
- Apple HIG: [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- Apple HIG: [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)
- Apple HIG: [Scroll views](https://developer.apple.com/design/human-interface-guidelines/scroll-views)
- SwiftUI: [`Settings`](https://developer.apple.com/documentation/swiftui/settings)
- SwiftUI: [`Form`](https://developer.apple.com/documentation/swiftui/form)
- SwiftUI: [`TabView`](https://developer.apple.com/documentation/swiftui/tabview)
- SwiftUI: [`NavigationSplitView`](https://developer.apple.com/documentation/swiftui/navigationsplitview)
- SwiftUI: [`List`](https://developer.apple.com/documentation/swiftui/list)
- SwiftUI: [`ScrollView`](https://developer.apple.com/documentation/swiftui/scrollview)
- SwiftUI: [`DisclosureGroup`](https://developer.apple.com/documentation/swiftui/disclosuregroup)
- SwiftUI: [Adding a search interface to your app](https://developer.apple.com/documentation/swiftui/adding-a-search-interface-to-your-app)
- SwiftUI: [`windowResizability(_:)`](https://developer.apple.com/documentation/swiftui/scene/windowresizability(_:)) and [`contentSize`](https://developer.apple.com/documentation/swiftui/windowresizability/contentsize)
- SwiftUI: [`defaultSize(width:height:)`](https://developer.apple.com/documentation/swiftui/scene/defaultsize(width:height:))
