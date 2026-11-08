// Injected into every frame before page scripts run. Mirrors the hooks used by
// Kazumi's WebView resolver (lib/webview/video/impl/video_webview_apple_impl.dart):
// report any fetch/XHR response whose body is an HLS playlist, and any <video> src.
(() => {
  if (window.__kazumiHooked) return;
  window.__kazumiHooked = true;
  const report = (kind, url) => {
    try {
      if (!url) return;
      const abs = new URL(url, location.href).href;
      window.__kazumiReport && window.__kazumiReport(kind, abs, location.href);
    } catch (_) {}
  };

  const _text = window.Response && window.Response.prototype.text;
  if (_text) {
    window.Response.prototype.text = function () {
      return _text.call(this).then((text) => {
        try {
          if (typeof text === 'string' && text.trim().startsWith('#EXTM3U')) report('m3u8', this.url);
        } catch (_) {}
        return text;
      });
    };
  }

  const _open = window.XMLHttpRequest && window.XMLHttpRequest.prototype.open;
  if (_open) {
    window.XMLHttpRequest.prototype.open = function (...args) {
      this.addEventListener('load', () => {
        try {
          if (this.responseType === '' || this.responseType === 'text') {
            const content = this.responseText;
            if (content && content.trim().startsWith('#EXTM3U')) report('m3u8', args[1]);
          }
        } catch (_) {}
      });
      return _open.apply(this, args);
    };
  }

  const bad = (src) => !src || !src.trim() || src.startsWith('blob:') || src.includes('googleads');
  const scanVideo = (video) => {
    let src = video.getAttribute('src');
    if (!bad(src)) return report('video', src);
    for (const s of video.getElementsByTagName('source')) {
      src = s.getAttribute('src');
      if (!bad(src)) return report('video', src);
    }
  };
  const start = () => {
    // Undo lazy iframes so nested players load in a headless page.
    document.querySelectorAll('iframe[loading="lazy"]').forEach((f) => f.removeAttribute('loading'));
    document.querySelectorAll('video').forEach(scanVideo);
    new MutationObserver((mutations) => {
      for (const m of mutations) {
        if (m.type === 'attributes' && m.target.nodeName === 'VIDEO') scanVideo(m.target);
        m.addedNodes.forEach((n) => {
          if (n.nodeName === 'VIDEO') scanVideo(n);
          if (n.nodeName === 'IFRAME' && n.getAttribute('loading') === 'lazy') n.removeAttribute('loading');
          if (n.querySelectorAll) n.querySelectorAll('video').forEach(scanVideo);
        });
      }
    }).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
