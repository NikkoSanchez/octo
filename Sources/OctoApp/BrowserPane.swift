import AppKit
import Combine
import SwiftUI
import WebKit
import OctoCore

enum BrowserAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "System" : self == .light ? "Light" : "Dark" }
}

/// Viewport presets. WebKit on macOS keeps its desktop engine and user agent, so this emulates width and
/// height for responsive CSS only, not touch input or mobile-only server behavior.
enum BrowserDevice: String, CaseIterable, Identifiable {
    case phone, tablet, laptop
    var id: String { rawValue }
    var title: String { self == .phone ? "Phone" : self == .tablet ? "Tablet" : "Laptop" }
    var size: CGSize {
        switch self {
        case .phone: return CGSize(width: 390, height: 844)
        case .tablet: return CGSize(width: 820, height: 1180)
        case .laptop: return CGSize(width: 1280, height: 800)
        }
    }
}

/// One browser tab. The web view lives here, not in a view, so hiding the tab or switching
/// projects keeps page state. Annotation runs in an isolated content world: page scripts can
/// neither call its message handler nor read its state.
@MainActor final class BrowserSession: NSObject, ObservableObject {
    @Published var address = ""
    @Published private(set) var title = ""
    @Published private(set) var currentURL: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var annotating = false
    @Published private(set) var zoom: Double = 1
    @Published var appearance: BrowserAppearance = .system {
        didSet { webView.appearance = appearance == .system ? nil : NSAppearance(named: appearance == .dark ? .darkAqua : .aqua) }
    }
    @Published var device: BrowserDevice?
    @Published var landscape = false
    @Published private(set) var detached = false
    @Published var error: String?
    let webView: WKWebView
    /// Private tabs use a non-persistent data store; pop-ups share their opener's store.
    let isPrivate: Bool
    var onAnnotation: ((BrowserAnnotation, Data?) -> Void)?
    var onAddressChange: ((String) -> Void)?
    /// Receives pages opened with `target=_blank` or `window.open`, already bound to WebKit's pop-up configuration.
    var onOpenTab: ((BrowserSession) -> Void)?
    /// The page called `window.close()`.
    var onClose: (() -> Void)?
    private let world = WKContentWorld.world(name: "OctoAnnotate")
    private var observers: Set<AnyCancellable> = []
    private var pendingAddress: String?
    private var fitScale: Double = 1
    private var window: NSWindow?
    private let developerExtras: Bool

    /// Pass WebKit's configuration for a pop-up so it keeps its opener and website data.
    init(configuration: WKWebViewConfiguration? = nil, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        let configuration = configuration ?? {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
            configuration.applicationNameForUserAgent = Self.applicationName
            return configuration
        }()
        // A pop-up's configuration carries its opener's controller, which already has a handler with this name.
        configuration.userContentController = WKUserContentController()
        // WebKit's inspector does not open unless this preference is on; it also adds Inspect Element to the
        // context menu. The key is SPI, so KVC is used only when its setter exists.
        developerExtras = configuration.preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:"))
        if developerExtras { configuration.preferences.setValue(true, forKey: "developerExtrasEnabled") }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakScriptHandler(self), contentWorld: world, name: "octoAnnotate")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        webView.publisher(for: \.title).sink { [weak self] in
            self?.title = $0 ?? ""
            self?.window?.title = ($0 ?? "").isEmpty ? "Browser" : $0 ?? ""
        }.store(in: &observers)
        webView.publisher(for: \.url).sink { [weak self] url in
            self?.currentURL = url
            if let url, url.absoluteString != "about:blank" { self?.address = url.absoluteString; self?.onAddressChange?(url.absoluteString) }
        }.store(in: &observers)
        webView.publisher(for: \.canGoBack).sink { [weak self] in self?.canGoBack = $0 }.store(in: &observers)
        webView.publisher(for: \.canGoForward).sink { [weak self] in self?.canGoForward = $0 }.store(in: &observers)
        webView.publisher(for: \.isLoading).sink { [weak self] in self?.isLoading = $0 }.store(in: &observers)
    }

    /// WKWebView's default user agent stops after the WebKit token, so sites such as Google treat it as an
    /// unknown browser and serve fallback pages. Appending exactly what Safari appends keeps WebKit's own
    /// platform/engine string, so the identity matches the engine and bot checks see a consistent Safari.
    static func safariApplicationName(version: String?) -> String {
        let version = version.flatMap { $0.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil ? $0 : nil } ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }

    static func installedSafariVersion() -> String? {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") ?? URL(fileURLWithPath: "/Applications/Safari.app")
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static let applicationName = safariApplicationName(version: installedSafariVersion())
    static let userAgentDefaultsKey = "browserApplicationNameForUserAgent"

    /// WebKit caches a redirect together with the follow-up request, user agent included, and replays that request
    /// on a cache hit. After the agent changes (this fix's first launch, or a Safari update), a cached
    /// `google.com` → `www.google.com` redirect would keep sending the old identity, so drop the HTTP cache.
    /// Cookies and other website data are untouched.
    static func discardCacheIfUserAgentChanged(_ applicationName: String, defaults: UserDefaults, store: WKWebsiteDataStore) async {
        guard defaults.string(forKey: userAgentDefaultsKey) != applicationName else { return }
        await store.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast)
        defaults.set(applicationName, forKey: userAgentDefaultsKey)
    }

    /// Navigations wait for this, so no request can hit a cache entry recorded under a previous agent.
    private static let cacheReady = Task { @MainActor in
        await discardCacheIfUserAgentChanged(applicationName, defaults: .standard, store: .default())
    }

    /// Accepts full http(s) URLs, bare hosts, `localhost:3000`-style dev servers, or a search.
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil { return url }
        if !text.contains(" ") {
            let local = text.range(of: #"^(localhost|127\.0\.0\.1|\[::1\]|[\w-]+\.local|\d{1,3}(\.\d{1,3}){3})(:\d+)?([/?#].*)?$"#, options: .regularExpression) != nil
            if local || text.range(of: #"^[\w.-]+:\d+([/?#].*)?$"#, options: .regularExpression) != nil { return URL(string: "http://" + text) }
            if text.range(of: #"^[\w-]+(\.[\w-]+)+([/?#:].*)?$"#, options: .regularExpression) != nil, let url = URL(string: "https://" + text), url.host != nil { return url }
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }

    func go() {
        guard let url = Self.url(from: address) else { return }
        error = nil; address = url.absoluteString; pendingAddress = nil
        Task { await Self.cacheReady.value; webView.load(URLRequest(url: url)) }
    }
    func open(_ address: String) { self.address = address; go() }
    /// A restored tab shows its address and loads only when first shown.
    func restore(_ address: String) { self.address = address; pendingAddress = address }
    func loadIfRestoring() { if let pendingAddress { open(pendingAddress) } }
    var isRestoring: Bool { pendingAddress != nil }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { if isLoading { webView.stopLoading() } else { error = nil; webView.reload() } }
    /// Revalidates every resource instead of using cached copies.
    func hardReload() { error = nil; webView.reloadFromOrigin() }
    func openExternally() { if let currentURL { NSWorkspace.shared.open(currentURL) } }

    static let zoomLevels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    func zoomIn() { zoom = Self.zoomLevels.first { $0 > zoom + 0.001 } ?? zoom; applyZoom() }
    func zoomOut() { zoom = Self.zoomLevels.last { $0 < zoom - 0.001 } ?? zoom; applyZoom() }
    func resetZoom() { zoom = 1; applyZoom() }

    var viewport: CGSize? {
        device.map { landscape ? CGSize(width: $0.size.height, height: $0.size.width) : $0.size }
    }
    /// The page lays out `frame / pageZoom` CSS pixels wide, so shrinking both by the same factor keeps the
    /// emulated viewport exact while it fits in the panel.
    static func fitScale(viewport: CGSize, in available: CGSize) -> Double {
        guard viewport.width > 0, viewport.height > 0 else { return 1 }
        return max(0.1, min(1, available.width / viewport.width, available.height / viewport.height))
    }
    func setFitScale(_ scale: Double) { guard scale != fitScale else { return }; fitScale = scale; applyZoom() }
    private func applyZoom() { webView.pageZoom = zoom * fitScale }

    /// WebKit has no public API to open its inspector from code. `_inspector` and the developer extras preference
    /// are WebKit SPI, so both are looked up at runtime and the command reports unavailable if a WebKit release
    /// removes them. Because the page is inspectable, Safari's Develop menu works either way.
    private static let inspectorSelector = NSSelectorFromString("_inspector"), showSelector = NSSelectorFromString("show")
    private var inspector: NSObject? {
        guard webView.responds(to: Self.inspectorSelector),
              let inspector = webView.perform(Self.inspectorSelector)?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: Self.showSelector) else { return nil }
        return inspector
    }
    var canOpenDevTools: Bool { developerExtras && webView.responds(to: Self.inspectorSelector) }
    func openDevTools() {
        if canOpenDevTools, let inspector { inspector.perform(Self.showSelector) }
        else { error = "This version of WebKit cannot open the inspector from Octo. Use Safari → Develop → this Mac → Octo." }
    }

    /// Clears cookies for this tab's profile: the shared default store, or this private tab and its pop-ups.
    func clearCookies() async {
        await webView.configuration.websiteDataStore.removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast)
    }
    func clearCache() async {
        await webView.configuration.websiteDataStore.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache], modifiedSince: .distantPast)
    }

    /// Moves the live page into its own window; closing that window returns it to the panel.
    func openInWindow() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title.isEmpty ? "Browser" : title
        let container = NSView(frame: window.contentLayoutRect)
        webView.removeFromSuperview()
        webView.frame = container.bounds; webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        window.contentView = container
        window.delegate = self
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window; detached = true
    }
    func returnFromWindow() { window?.close() }

    /// Ends the page. The session is not reused afterwards.
    func close() {
        onAnnotation = nil; onAddressChange = nil; onOpenTab = nil; onClose = nil
        window?.close()
        webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
    }

    func toggleAnnotating() {
        guard currentURL != nil else { return }
        let starting = !annotating
        annotating = starting
        webView.evaluateJavaScript(Self.annotationScript + (starting ? "window.__octoAnnotate.start();" : "window.__octoAnnotate.stop();"),
                                   in: nil, in: world) { [weak self] result in
            if case .failure = result, starting { self?.annotating = false; self?.error = "This page does not allow annotation." }
        }
    }

    func captureViewport(_ completion: @escaping (Data?) -> Void) { snapshot(nil, completion) }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.world == world, let body = message.body as? [String: Any] else { return }
        annotating = false
        guard let kind = (body["kind"] as? String).flatMap(BrowserAnnotation.Kind.init(rawValue:)) else { return }
        func number(_ object: Any?, _ key: String) -> Double { ((object as? [String: Any])?[key] as? NSNumber)?.doubleValue ?? 0 }
        let rect = BrowserAnnotation.Rect(x: number(body["rect"], "x"), y: number(body["rect"], "y"),
                                          width: number(body["rect"], "width"), height: number(body["rect"], "height"))
        // The page reports its own URL and title; prefer the web view's values.
        let annotation = BrowserAnnotation(kind: kind, url: currentURL?.absoluteString ?? "", pageTitle: title,
                                           selector: body["selector"] as? String ?? "", element: body["element"] as? String ?? "",
                                           text: body["text"] as? String ?? "", html: body["html"] as? String ?? "",
                                           rect: rect, viewport: .init(width: number(body["viewport"], "width"), height: number(body["viewport"], "height")))
        snapshot(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)) { [weak self] data in
            self?.onAnnotation?(annotation, data)
        }
    }

    /// `rect` is in CSS pixels relative to the viewport; nil captures the visible page.
    private func snapshot(_ rect: CGRect?, _ completion: @escaping (Data?) -> Void) {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        if let rect {
            let scale = webView.pageZoom * webView.magnification
            let target = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
                .insetBy(dx: -6, dy: -6).intersection(webView.bounds)
            guard !target.isNull, target.width >= 2, target.height >= 2 else { completion(nil); return }
            configuration.rect = target
        }
        webView.takeSnapshot(with: configuration) { image, _ in completion(image?.tiffRepresentation) }
    }

    static let annotationScript = #"""
    (() => {
      if (window.__octoAnnotate) return;
      let overlay = null, box = null, label = null, origin = null, dragging = false;
      const escape = (value) => (window.CSS && CSS.escape) ? CSS.escape(value) : value.replace(/[^\w-]/g, '\\$&');
      const unique = (el) => el.id && document.querySelectorAll('#' + escape(el.id)).length === 1;
      function selectorFor(el) {
        const parts = [];
        while (el && el.nodeType === 1 && el !== document.documentElement && parts.length < 8) {
          if (unique(el)) { parts.unshift('#' + escape(el.id)); break; }
          let part = el.localName;
          const parent = el.parentElement;
          if (parent) {
            const same = Array.from(parent.children).filter((child) => child.localName === el.localName);
            if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
          }
          parts.unshift(part); el = parent;
        }
        return parts.join(' > ');
      }
      function describe(el) {
        let text = el.localName;
        if (el.id) text += '#' + el.id;
        const classes = Array.from(el.classList || []).slice(0, 3);
        if (classes.length) text += '.' + classes.join('.');
        return text;
      }
      const target = (x, y) => document.elementsFromPoint(x, y).find((el) => !overlay.contains(el)) || null;
      const region = (a, e) => ({ x: Math.min(a.x, e.clientX), y: Math.min(a.y, e.clientY), width: Math.abs(e.clientX - a.x), height: Math.abs(e.clientY - a.y) });
      function show(r, text) {
        Object.assign(box.style, { display: 'block', left: r.x + 'px', top: r.y + 'px', width: r.width + 'px', height: r.height + 'px' });
        label.textContent = text;
        Object.assign(label.style, { display: 'block', left: r.x + 'px', top: Math.max(0, r.y - 24) + 'px' });
      }
      function move(e) {
        if (origin) {
          if (Math.abs(e.clientX - origin.x) > 5 || Math.abs(e.clientY - origin.y) > 5) dragging = true;
          if (dragging) { const r = region(origin, e); show(r, Math.round(r.width) + ' × ' + Math.round(r.height)); }
          return;
        }
        const el = target(e.clientX, e.clientY);
        if (el) { const b = el.getBoundingClientRect(); show({ x: b.left, y: b.top, width: b.width, height: b.height }, describe(el)); }
      }
      function down(e) { if (e.button !== 0) return; e.preventDefault(); e.stopPropagation(); origin = { x: e.clientX, y: e.clientY }; dragging = false; }
      function up(e) {
        if (!origin) return;
        e.preventDefault(); e.stopPropagation();
        const start = origin, wasDragging = dragging;
        origin = null; dragging = false;
        let payload;
        if (wasDragging) {
          const r = region(start, e);
          if (r.width < 4 || r.height < 4) return;
          const el = target(r.x + r.width / 2, r.y + r.height / 2);
          payload = { kind: 'region', rect: r, selector: el ? selectorFor(el) : '', element: el ? describe(el) : '', text: '', html: '' };
        } else {
          const el = target(e.clientX, e.clientY);
          if (!el) return;
          const b = el.getBoundingClientRect();
          payload = { kind: 'element', rect: { x: b.left, y: b.top, width: b.width, height: b.height }, selector: selectorFor(el),
                      element: describe(el), text: (el.innerText || el.textContent || '').trim().slice(0, 2000), html: el.outerHTML.slice(0, 4000) };
        }
        payload.viewport = { width: innerWidth, height: innerHeight };
        stop();
        // The app snapshots after screen updates, so the removed overlay is not captured.
        window.webkit.messageHandlers.octoAnnotate.postMessage(payload);
      }
      function key(e) {
        if (e.key !== 'Escape') return;
        e.preventDefault(); stop();
        window.webkit.messageHandlers.octoAnnotate.postMessage({ kind: 'cancel' });
      }
      function start() {
        if (overlay) return;
        overlay = document.createElement('div');
        overlay.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;cursor:crosshair;';
        box = document.createElement('div');
        box.style.cssText = 'all:initial;position:fixed;pointer-events:none;display:none;border:2px solid #7c8cff;background:rgba(124,140,255,.16);border-radius:3px;box-sizing:border-box;';
        label = document.createElement('div');
        label.style.cssText = 'all:initial;position:fixed;pointer-events:none;display:none;font:12px -apple-system,system-ui,sans-serif;color:#fff;background:#3b4261;padding:3px 7px;border-radius:4px;white-space:nowrap;';
        overlay.append(box, label);
        overlay.addEventListener('mousemove', move, true);
        overlay.addEventListener('mousedown', down, true);
        overlay.addEventListener('mouseup', up, true);
        overlay.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); }, true);
        window.addEventListener('keydown', key, true);
        document.documentElement.appendChild(overlay);
      }
      function stop() {
        window.removeEventListener('keydown', key, true);
        if (overlay) overlay.remove();
        overlay = null; origin = null; dragging = false;
      }
      window.__octoAnnotate = { start, stop };
    })();
    """#
}

extension BrowserSession: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "data", "blob"].contains(scheme) { decisionHandler(.allow); return }
        // Other schemes (mailto:, app links) leave the browser only on an explicit click.
        if action.navigationType == .linkActivated, let url = action.request.url, !["javascript", "file"].contains(scheme) { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { annotating = false; error = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    private func report(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        self.error = error.localizedDescription
    }
    /// Pop-ups and `target=_blank` links open as new tabs that keep `window.opener`, so sign-in pop-ups work.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil else { return nil }
        if let onOpenTab {
            let child = BrowserSession(configuration: configuration, isPrivate: isPrivate)
            onOpenTab(child)
            return child.webView
        }
        if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { webView.load(action.request) }
        return nil
    }
    func webViewDidClose(_ webView: WKWebView) { onClose?() }
}

extension BrowserSession: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        webView.removeFromSuperview()
        window.delegate = nil; self.window = nil; detached = false
    }
}

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var session: BrowserSession?
    init(_ session: BrowserSession) { self.session = session }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { session?.receive(message) }
    }
}

/// Hosts the session's web view, re-parenting it when the panel or project changes.
private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> NSView { let container = NSView(); attach(to: container); return container }
    func updateNSView(_ container: NSView, context: Context) { if webView.superview !== container { attach(to: container) } }
    static func dismantleNSView(_ container: NSView, coordinator: ()) { container.subviews.forEach { $0.removeFromSuperview() } }
    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.frame = container.bounds; webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

struct BrowserPane: View {
    @ObservedObject var session: BrowserSession
    var isVisible: Bool
    var attachScreenshot: (Data) -> Void
    @Environment(\.octoTheme) private var theme
    @FocusState private var addressFocused: Bool
    @State private var clearingCookies = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: session.goBack) { Image(systemName: "chevron.left") }.disabled(!session.canGoBack)
                    .buttonStyle(HoverButtonStyle()).help("Back").accessibilityLabel("Back")
                Button(action: session.goForward) { Image(systemName: "chevron.right") }.disabled(!session.canGoForward)
                    .buttonStyle(HoverButtonStyle()).help("Forward").accessibilityLabel("Forward")
                Button(action: session.reload) { Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise") }
                    .disabled(session.currentURL == nil)
                    .buttonStyle(HoverButtonStyle()).help(session.isLoading ? "Stop" : "Reload").accessibilityLabel(session.isLoading ? "Stop loading" : "Reload")
                HStack(spacing: 6) {
                    if session.isPrivate {
                        Image(systemName: "eye.slash").font(.system(size: 12)).foregroundStyle(theme.secondary)
                            .help("Private tab: cookies and website data are discarded when the tab closes").accessibilityLabel("Private tab")
                    }
                    TextField(session.isPrivate ? "Search or enter address privately" : "Search or enter address", text: $session.address)
                        .textFieldStyle(.plain).font(.system(size: 13)).focused($addressFocused)
                        .onSubmit { session.go(); addressFocused = false }
                        .accessibilityLabel("Address")
                }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 7))
                Button(action: session.toggleAnnotating) { Image(systemName: "cursorarrow.rays") }
                    .buttonStyle(HoverButtonStyle(selected: session.annotating)).disabled(session.currentURL == nil)
                    .help("Annotate elements and regions: click an element or drag a region to attach it to the draft")
                    .accessibilityLabel(session.annotating ? "Stop annotating" : "Annotate elements and regions")
                Button { session.captureViewport { if let data = $0 { attachScreenshot(data) } } } label: { Image(systemName: "camera") }
                    .buttonStyle(HoverButtonStyle()).disabled(session.currentURL == nil)
                    .help("Attach a screenshot of the visible page to the draft").accessibilityLabel("Attach page screenshot")
                Button(action: session.openExternally) { Image(systemName: "safari") }
                    .buttonStyle(HoverButtonStyle()).disabled(session.currentURL == nil)
                    .help("Open in default browser").accessibilityLabel("Open in default browser")
                moreMenu
            }.padding(.horizontal, 8).padding(.vertical, 6)
            ProgressView(value: session.isLoading ? 0.5 : 0).progressViewStyle(.linear).opacity(session.isLoading ? 1 : 0).frame(height: 2)
            if session.device != nil { deviceToolbar }
            Divider()
            ZStack(alignment: .top) {
                if session.detached {
                    ContentUnavailableView {
                        Label("Open in a separate window", systemImage: "macwindow")
                    } description: { Text(session.title.isEmpty ? "This page is showing in its own window." : session.title) }
                    actions: { Button("Return to Panel", action: session.returnFromWindow) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.background)
                } else { page }
                if session.currentURL == nil && !session.detached {
                    ContentUnavailableView {
                        Label(session.isPrivate ? "Private Browser" : "Browser", systemImage: session.isPrivate ? "eye.slash" : "globe")
                    } description: {
                        Text(session.isPrivate
                             ? "Cookies, storage and history in this tab are discarded when it closes."
                             : "Open your dev server or any page. Annotate elements and regions to attach them to the draft with a screenshot.")
                    } actions: {
                        Button("Open localhost:3000") { session.open("localhost:3000") }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.background)
                }
                if session.annotating {
                    Text("Click an element or drag a region · Esc to cancel")
                        .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(theme.panel, in: Capsule()).overlay(Capsule().stroke(theme.border)).padding(8)
                        .allowsHitTesting(false)
                }
                if let error = session.error {
                    HStack {
                        Text(error).font(.system(size: 12)).foregroundStyle(theme.red).lineLimit(2)
                        Spacer()
                        Button { session.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(HoverButtonStyle()).accessibilityLabel("Dismiss error")
                    }.padding(10).background(theme.panel).overlay(alignment: .bottom) { Divider() }
                }
            }
        }
        .onChange(of: isVisible, initial: true) { _, visible in
            guard visible else { return }
            if session.isRestoring { session.loadIfRestoring() }
            else if session.currentURL == nil { addressFocused = true }
        }
        .alert("Clear cookies?", isPresented: $clearingCookies) {
            Button("Clear Cookies", role: .destructive) { Task { await session.clearCookies() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(session.isPrivate
                 ? "This signs you out of sites in this private tab and the pop-ups it opened."
                 : "This signs you out of sites in every non-private browser tab in Octo. Private tabs are unaffected.")
        }
    }
    /// The web view keeps one position in the hierarchy, so toggling the device toolbar never reloads the page.
    private var page: some View {
        GeometryReader { geometry in
            let viewport = session.viewport
            let scale = viewport.map { BrowserSession.fitScale(viewport: $0, in: CGSize(width: geometry.size.width - 24, height: geometry.size.height - 24)) } ?? 1
            BrowserWebView(webView: session.webView)
                .frame(width: viewport.map { $0.width * scale }, height: viewport.map { $0.height * scale })
                .overlay { if viewport != nil { RoundedRectangle(cornerRadius: 2).stroke(theme.border) } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(viewport != nil ? theme.surface : Color.clear)
                .onChange(of: scale, initial: true) { _, scale in session.setFitScale(scale) }
        }
    }
    private var deviceToolbar: some View {
        HStack(spacing: 8) {
            Picker("Device", selection: Binding(get: { session.device ?? .phone }, set: { session.device = $0 })) {
                ForEach(BrowserDevice.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).frame(width: 210)
            Button { session.landscape.toggle() } label: { Image(systemName: "rotate.right") }
                .buttonStyle(HoverButtonStyle()).help("Rotate").accessibilityLabel("Rotate viewport")
            if let viewport = session.viewport {
                Text("\(Int(viewport.width)) × \(Int(viewport.height))").font(.system(size: 12).monospacedDigit()).foregroundStyle(theme.secondary)
            }
            Spacer()
            Button { session.device = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(HoverButtonStyle()).help("Hide device toolbar").accessibilityLabel("Hide device toolbar")
        }.padding(.horizontal, 8).padding(.vertical, 4)
    }
    private var moreMenu: some View {
        Menu {
            Button("Hard Reload", action: session.hardReload).disabled(session.currentURL == nil)
            Button("Open Web Inspector", action: session.openDevTools).disabled(!session.canOpenDevTools || session.currentURL == nil)
            if session.detached { Button("Return Page to Panel", action: session.returnFromWindow) }
            else { Button("Open in Separate Window", action: session.openInWindow).disabled(session.currentURL == nil) }
            Button(session.device == nil ? "Show Device Toolbar" : "Hide Device Toolbar") { session.device = session.device == nil ? .phone : nil }
            Picker("Appearance", selection: $session.appearance) {
                ForEach(BrowserAppearance.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
            Divider()
            Section("Zoom: \(Int((session.zoom * 100).rounded()))%") {
                Button("Zoom In", action: session.zoomIn).disabled(session.zoom >= BrowserSession.zoomLevels.last!)
                Button("Zoom Out", action: session.zoomOut).disabled(session.zoom <= BrowserSession.zoomLevels.first!)
                Button("Actual Size", action: session.resetZoom).disabled(session.zoom == 1)
            }
            Divider()
            Section(session.isPrivate ? "Profile: Private" : "Profile: Default") {
                Button("Clear Cookies…") { clearingCookies = true }
                Button("Clear Cache") { Task { await session.clearCache() } }
            }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.horizontal, 6).frame(minHeight: 26).hoverFeedback()
            .help("More browser actions").accessibilityLabel("More browser actions")
    }
}
