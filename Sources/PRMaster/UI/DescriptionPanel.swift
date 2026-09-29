import SwiftUI
import WebKit

/// The pull request's description as GitHub renders it, beside the diff.
struct DescriptionPanel: View {
    let html: String?
    let baseURL: URL
    let isLoading: Bool

    var body: some View {
        if let html {
            DescriptionWebView(html: html, baseURL: baseURL)
        } else {
            Text(isLoading ? "" : "No description provided.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DescriptionWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL

    func makeCoordinator() -> Coordinator { Coordinator(baseURL: baseURL) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // Lets the panel show the window's own background in light and dark.
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(Self.page(html), baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let baseURL: URL
        var loaded: String?

        init(baseURL: URL) { self.baseURL = baseURL }

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .other, action.request.url == baseURL {
                decisionHandler(.allow)
                return
            }
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["https", "http", "mailto"].contains(url.scheme) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }

    static func page(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'">
        <style>
        :root { color-scheme: light dark; }
        body { font: 13px -apple-system, sans-serif; line-height: 1.5; margin: 12px 14px; color: CanvasText; background: transparent; word-wrap: break-word; }
        h1, h2, h3 { line-height: 1.25; margin: 1em 0 .5em; } h1 { font-size: 1.5em; } h2 { font-size: 1.3em; } h3 { font-size: 1.1em; }
        a { color: LinkText; }
        code, pre { font: 12px ui-monospace, monospace; background: color-mix(in srgb, CanvasText 8%, transparent); border-radius: 4px; }
        code { padding: .1em .3em; } pre { padding: 8px 10px; overflow-x: auto; } pre code { padding: 0; background: none; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid color-mix(in srgb, CanvasText 20%, transparent); padding: 4px 8px; }
        blockquote { margin: 0; padding-left: 10px; border-left: 3px solid color-mix(in srgb, CanvasText 25%, transparent); opacity: .8; }
        img { max-width: 100%; } ul.contains-task-list { padding-left: 1.2em; } .task-list-item { list-style: none; }
        hr { border: none; border-top: 1px solid color-mix(in srgb, CanvasText 20%, transparent); }
        </style></head><body>\(body)</body></html>
        """
    }
}
