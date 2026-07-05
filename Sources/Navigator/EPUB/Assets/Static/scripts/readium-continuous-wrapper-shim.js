(function () {
  try {
    if (typeof globalThis.readium === "undefined") {
      globalThis.readium = { isFixedLayout: true };
    }

    var cw = globalThis.continuousWrapper;
    if (!cw) return;

    var pending = new Map();
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

      var href = iframe.getAttribute("data-href") || "";
      if (!href) return;

      var prefix = href + ":";
      pending.forEach(function (decs, key) {
        if (key.indexOf(prefix) !== 0) return;
        applyToIframe(iframe, key.slice(prefix.length), decs);
        pending.delete(key);
      });
    }

    function findChapterWrapperByHref(href) {
      if (!href) return null;

      var chapters = document.querySelectorAll('.chapter[data-href]');
      for (var i = 0; i < chapters.length; i++) {
        var h = chapters[i].getAttribute('data-href') || "";
        if (h === href || href.indexOf(h) !== -1 || h.indexOf(href) !== -1) {
          return chapters[i];
        }
      }
      return null;
    }

    function getIframeScrollHeight(iframe) {
      var doc = iframe ? iframe.contentDocument : null;
      if (!doc) return null;
      var bodyHeight = doc.body ? doc.body.scrollHeight : 0;
      var docHeight = doc.documentElement ? doc.documentElement.scrollHeight : 0;
      return Math.max(bodyHeight || 0, docHeight || 0);
    }

    function scrollToLocatorInIframe(wrapper, iframe, locator) {
      var doc = iframe ? iframe.contentDocument : null;
      if (!doc) return false;

      var wrapperTop = wrapper.getBoundingClientRect().top + window.scrollY;
      var offset = 0;

      var selector = locator && locator.locations ? locator.locations.cssSelector : null;
      if (selector) {
        try {
          var el = doc.querySelector(selector);
          if (el) offset = el.getBoundingClientRect().top;
        } catch (e) { }
      }

      var prog = locator && locator.locations ? locator.locations.progression : null;
      if (!offset && typeof prog === 'number') {
        var height = getIframeScrollHeight(iframe) || wrapper.offsetHeight || 0;
        offset = height * Math.max(0, Math.min(1, prog));
      }

      window.scrollTo({ top: wrapperTop + Math.max(0, offset), behavior: 'auto' });
      return true;
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
      var byHref = new Map();
      for (var i = 0; i < decorations.length; i++) {
        var d = decorations[i];
        var href = d && d.locator ? (d.locator.href || "") : "";
        if (!byHref.has(href)) byHref.set(href, []);
        byHref.get(href).push(d);
      }

      byHref.forEach(function (decs, href) {
        var wrapper = findChapterWrapperByHref(href);
        var iframe = wrapper ? wrapper.querySelector('iframe.chapter-iframe') : null;
        var key = href + ":" + groupName;

        if (iframe && getReadium(iframe)) {
          applyToIframe(iframe, groupName, decs);
        } else {
          pending.set(key, decs);
        }
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

    var originalGoTo = cw.goTo;
    cw.goTo = function (locator) {
      var href = locator && locator.href ? locator.href : "";
      var wrapper = findChapterWrapperByHref(href);
      if (!wrapper) {
        return originalGoTo ? originalGoTo(locator) : false;
      }

      wrapper.scrollIntoView({ behavior: 'auto', block: 'start' });

      var tries = 20;
      (function attempt() {
        var iframe = wrapper.querySelector('iframe.chapter-iframe');
        if (iframe && getReadium(iframe)) {
          scrollToLocatorInIframe(wrapper, iframe, locator);
          return;
        }
        tries -= 1;
        if (tries > 0) setTimeout(attempt, 100);
      })();

      return true;
    };

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
