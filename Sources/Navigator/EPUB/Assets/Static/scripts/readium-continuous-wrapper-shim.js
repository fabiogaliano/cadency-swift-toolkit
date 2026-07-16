(function () {
  try {
    if (typeof globalThis.readium === "undefined") {
      globalThis.readium = { isFixedLayout: true };
    }

    var cw = globalThis.continuousWrapper;
    if (!cw) return;

    var decorationSnapshots = new Map();
    var activable = new Set();
    var templates = null;
    var cssProps = null;

    function forEachIframe(fn) {
      var iframes = document.querySelectorAll("iframe.chapter-iframe");
      for (var i = 0; i < iframes.length; i++) {
        try {
          fn(iframes[i]);
        } catch (e) { }
      }
    }

    function getReadium(iframe) {
      return iframe && iframe.contentWindow ? iframe.contentWindow.readium : null;
    }

    function decorationsForIframe(iframe, decorations) {
      var iframeHref = iframe.getAttribute("data-href") || "";
      return decorations.filter(function (decoration) {
        var href = decoration && decoration.locator ? (decoration.locator.href || "") : "";
        if (!href || !iframeHref) return false;
        return href === iframeHref || href.indexOf(iframeHref) !== -1 || iframeHref.indexOf(href) !== -1;
      });
    }

    function applyToIframe(iframe, groupName, decorations) {
      var r = getReadium(iframe);
      if (!r || !r.getDecorations) return;

      var group = r.getDecorations(groupName);
      group.clear();

      if (activable.has(groupName) && group.setActivable) {
        group.setActivable();
      }

      for (var i = 0; i < decorations.length; i++) {
        group.add(decorations[i]);
      }
    }

    function applyStoredToIframe(iframe) {
      var r = getReadium(iframe);
      if (!r) return;

      if (templates && r.registerDecorationTemplates) {
        try {
          r.registerDecorationTemplates(templates);
        } catch (e) { }
      }

      if (cssProps && r.setCSSProperties) {
        try {
          r.setCSSProperties(cssProps);
        } catch (e) { }
      }

      decorationSnapshots.forEach(function (decorations, groupName) {
        applyToIframe(iframe, groupName, decorationsForIframe(iframe, decorations));
      });
    }

    // Override APIs to avoid iframe.contentWindow.eval in the bundled output.

    cw.registerDecorationTemplates = function (t) {
      templates = t;
      forEachIframe(function (iframe) {
        var r = getReadium(iframe);
        if (r && r.registerDecorationTemplates) {
          try {
            r.registerDecorationTemplates(t);
          } catch (e) { }
        }
      });
      return true;
    };

    cw.setCSSProperties = function (p) {
      cssProps = p;
      forEachIframe(function (iframe) {
        var r = getReadium(iframe);
        if (r && r.setCSSProperties) {
          try {
            r.setCSSProperties(p);
          } catch (e) { }
        }
      });
      return true;
    };

    cw.setDecorationGroupActivable = function (groupName, isActivable) {
      if (isActivable) {
        activable.add(groupName);
      } else {
        activable.delete(groupName);
      }

      forEachIframe(function (iframe) {
        try {
          var r = getReadium(iframe);
          if (r && r.getDecorations) {
            r.getDecorations(groupName).setActivable();
          }
        } catch (e) { }
      });

      return true;
    };

    cw.applyDecorations = function (groupName, decorations) {
      decorationSnapshots.set(groupName, decorations);

      forEachIframe(function (iframe) {
        applyToIframe(iframe, groupName, decorationsForIframe(iframe, decorations));
      });

      return true;
    };

    cw.findFirstVisibleLocator = function () {
      var best = null;
      var bestVisible = 0;

      var chapters = document.querySelectorAll('.chapter');
      for (var i = 0; i < chapters.length; i++) {
        var wrapper = chapters[i];
        var iframe = wrapper.querySelector('iframe.chapter-iframe');
        if (!iframe || !getReadium(iframe)) continue;

        var rect = wrapper.getBoundingClientRect();
        var vh = window.innerHeight;
        var vt = Math.max(0, rect.top);
        var vb = Math.min(vh, rect.bottom);
        var visibleHeight = Math.max(0, vb - vt);

        if (visibleHeight > bestVisible) {
          bestVisible = visibleHeight;
          best = { wrapper: wrapper, iframe: iframe };
        }
      }

      if (!best) return null;

      var href = best.wrapper.getAttribute('data-href') || "";
      try {
        var r = getReadium(best.iframe);
        var loc = r && r.findFirstVisibleLocator ? r.findFirstVisibleLocator() : null;
        if (loc) {
          var copy = {};
          for (var k in loc) copy[k] = loc[k];
          copy.href = href;
          return copy;
        }
      } catch (e) { }

      return { href: href, type: 'application/xhtml+xml', locations: { progression: 0 } };
    };

    // goTo is intentionally NOT overridden: the bundled wrapper resolves it
    // event-driven from the iframe load (pending-navigation.js) and is
    // eval-free, so shimming it would only reintroduce timer polling.

    // Apply stored state to iframes as they get mounted.
    var root = document.getElementById('chapters') || document.body;
    if (root && globalThis.MutationObserver) {
      var observer = new MutationObserver(function (mutations) {
        for (var i = 0; i < mutations.length; i++) {
          var rec = mutations[i];
          for (var j = 0; j < rec.addedNodes.length; j++) {
            var node = rec.addedNodes[j];
            if (!node || node.nodeType !== 1) continue;

            var iframes = [];
            if (node.matches && node.matches('iframe.chapter-iframe')) {
              iframes = [node];
            } else if (node.querySelectorAll) {
              iframes = node.querySelectorAll('iframe.chapter-iframe');
            }

            for (var k = 0; k < iframes.length; k++) {
              (function (iframe) {
                iframe.addEventListener('load', function () {
                  applyStoredToIframe(iframe);
                }, { once: true });
                applyStoredToIframe(iframe);
              })(iframes[k]);
            }
          }
        }
      });

      observer.observe(root, { subtree: true, childList: true });
    }

    forEachIframe(function (iframe) {
      iframe.addEventListener('load', function () {
        applyStoredToIframe(iframe);
      }, { once: true });
      applyStoredToIframe(iframe);
    });


  } catch (e) { }
})();
