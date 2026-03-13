const adw = @import("adw");
const gtk = @import("gtk");

pub fn install(window: *adw.ApplicationWindow) void {
    const provider = gtk.CssProvider.new();
    provider.loadFromString(
        \\window {
        \\  background: radial-gradient(circle at top, rgba(30, 41, 59, 0.72), rgba(2, 6, 23, 0.98) 52%);
        \\  color: #e5eefb;
        \\}
        \\
        \\.lmux-shell {
        \\  padding: 18px;
        \\  border-spacing: 0;
        \\}
        \\
        \\.lmux-rail,
        \\.lmux-drawer,
        \\.lmux-context-card,
        \\.lmux-workspace,
        \\.lmux-terminal-frame {
        \\  background: rgba(15, 23, 42, 0.84);
        \\  border: 1px solid rgba(148, 163, 184, 0.14);
        \\  border-radius: 24px;
        \\}
        \\
        \\.lmux-rail,
        \\.lmux-drawer,
        \\.lmux-workspace {
        \\  box-shadow: 0 18px 48px rgba(2, 6, 23, 0.32);
        \\}
        \\
        \\.lmux-rail {
        \\  padding: 16px;
        \\}
        \\
        \\.lmux-section-title {
        \\  color: rgba(191, 219, 254, 0.72);
        \\  font-size: 11px;
        \\  font-weight: 700;
        \\  letter-spacing: 0.12em;
        \\  text-transform: uppercase;
        \\}
        \\
        \\.lmux-workspace {
        \\  padding: 14px;
        \\}
        \\
        \\.lmux-topbar {
        \\  background: rgba(15, 23, 42, 0.76);
        \\  border: 1px solid rgba(148, 163, 184, 0.12);
        \\  border-radius: 18px;
        \\  padding: 12px 14px;
        \\}
        \\
        \\.lmux-active-title {
        \\  color: #f8fbff;
        \\  font-size: 17px;
        \\  font-weight: 700;
        \\}
        \\
        \\.lmux-muted,
        \\.lmux-meta {
        \\  color: rgba(203, 213, 225, 0.72);
        \\}
        \\
        \\.lmux-tab-button,
        \\.lmux-pane-chip,
        \\.lmux-notification-row,
        \\.lmux-ghost-button,
        \\.lmux-split-button,
        \\.lmux-latest-button,
        \\.lmux-rail-add {
        \\  background: transparent;
        \\  border-radius: 18px;
        \\  border: 1px solid transparent;
        \\  color: #e2e8f0;
        \\  box-shadow: none;
        \\}
        \\
        \\.lmux-tab-button,
        \\.lmux-notification-row {
        \\  padding: 10px 12px;
        \\}
        \\
        \\.lmux-pane-chip,
        \\.lmux-split-button,
        \\.lmux-ghost-button,
        \\.lmux-latest-button,
        \\.lmux-rail-add {
        \\  padding: 8px 12px;
        \\}
        \\
        \\.lmux-tab-button:hover,
        \\.lmux-pane-chip:hover,
        \\.lmux-notification-row:hover,
        \\.lmux-ghost-button:hover,
        \\.lmux-split-button:hover,
        \\.lmux-latest-button:hover,
        \\.lmux-rail-add:hover {
        \\  background: rgba(51, 65, 85, 0.68);
        \\  border-color: rgba(96, 165, 250, 0.16);
        \\}
        \\
        \\.lmux-tab-button-active,
        \\.lmux-pane-chip-active {
        \\  background: rgba(30, 41, 59, 0.98);
        \\  border-color: rgba(96, 165, 250, 0.28);
        \\}
        \\
        \\.lmux-tab-button-active {
        \\  box-shadow: inset 3px 0 0 rgba(96, 165, 250, 0.92);
        \\}
        \\
        \\.lmux-tab-attention,
        \\.lmux-pane-chip-attention,
        \\.lmux-toggle-attention,
        \\.lmux-notification-unread {
        \\  border-color: rgba(96, 165, 250, 0.46);
        \\  box-shadow: 0 0 0 1px rgba(96, 165, 250, 0.18), 0 0 22px rgba(59, 130, 246, 0.16);
        \\}
        \\
        \\.lmux-pane-attention {
        \\  border-radius: 16px;
        \\  box-shadow: inset 0 0 0 2px rgba(96, 165, 250, 0.9), inset 0 0 28px rgba(59, 130, 246, 0.16);
        \\}
        \\
        \\.lmux-badge {
        \\  background: rgba(37, 99, 235, 0.22);
        \\  color: #dbeafe;
        \\  border-radius: 999px;
        \\  padding: 2px 8px;
        \\  font-size: 11px;
        \\  font-weight: 700;
        \\}
        \\
        \\.lmux-badge-empty {
        \\  opacity: 0.44;
        \\}
        \\
        \\.lmux-chip {
        \\  background: rgba(30, 41, 59, 0.92);
        \\  border: 1px solid rgba(148, 163, 184, 0.14);
        \\  border-radius: 999px;
        \\  color: #dbeafe;
        \\  padding: 4px 10px;
        \\}
        \\
        \\.lmux-terminal-frame {
        \\  padding: 4px;
        \\  background: rgba(2, 6, 23, 0.96);
        \\}
        \\
        \\.lmux-drawer {
        \\  padding: 14px;
        \\}
        \\
        \\.lmux-context-card {
        \\  padding: 14px;
        \\}
        \\
        \\.lmux-context-value {
        \\  color: #f8fbff;
        \\  font-size: 14px;
        \\}
        \\
        \\.lmux-section-divider {
        \\  min-height: 1px;
        \\  background: rgba(148, 163, 184, 0.1);
        \\}
    );

    const display = window.as(gtk.Widget).getDisplay();
    gtk.StyleContext.addProviderForDisplay(
        display,
        provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}
