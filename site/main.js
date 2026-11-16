// The silent feature clips play only while on screen, and not at all for
// visitors who asked for reduced motion (they get the controls instead).
(function () {
  var loops = Array.prototype.slice.call(document.querySelectorAll("video.loop"));
  if (!loops.length) return;
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduce || !("IntersectionObserver" in window)) {
    loops.forEach(function (v) { v.controls = true; });
    return;
  }
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      var v = e.target;
      if (e.isIntersecting) {
        var p = v.play();
        // Blocked autoplay gets the controls; a play() interrupted by
        // scrolling away (AbortError) does not.
        if (p && p.catch) p.catch(function (err) { if (err && err.name === "NotAllowedError") v.controls = true; });
      } else {
        v.pause();
      }
    });
  }, { threshold: 0.35 });
  loops.forEach(function (v) { io.observe(v); });
})();

// The score bars grow to the right the first time they scroll into view.
// Without JavaScript, or with reduced motion, they are simply full.
(function () {
  var list = document.querySelector(".scores");
  if (!list || !("IntersectionObserver" in window)) return;
  if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  list.classList.add("anim");
  var io = new IntersectionObserver(function (entries) {
    if (!entries[0].isIntersecting) return;
    list.classList.add("in");
    io.disconnect();
  }, { threshold: 0.4 });
  io.observe(list);
})();

// The star buttons show the repository's current star count, read from the
// GitHub API (no sign-in; 60 requests an hour per visitor, so the number is
// kept for ten minutes). If the request fails the buttons just have no number.
(function () {
  var els = Array.prototype.slice.call(document.querySelectorAll("[data-stars]"));
  if (!els.length) return;
  var KEY = "kb-stars", TTL = 10 * 60 * 1000;
  function show(n) {
    els.forEach(function (el) { el.textContent = n.toLocaleString("en-US"); el.hidden = false; });
  }
  var cached = null;
  try { cached = JSON.parse(localStorage.getItem(KEY)); } catch (e) {}
  if (cached && typeof cached.n === "number") {
    show(cached.n);
    if (Date.now() - cached.t < TTL) return;
  }
  if (!window.fetch) return;
  fetch("https://api.github.com/repos/Hikari-Tsai/karaoke-battle", { headers: { Accept: "application/vnd.github+json" } })
    .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); })
    .then(function (d) {
      if (typeof d.stargazers_count !== "number") return;
      show(d.stargazers_count);
      try { localStorage.setItem(KEY, JSON.stringify({ n: d.stargazers_count, t: Date.now() })); } catch (e) {}
    })
    .catch(function () {});
})();
