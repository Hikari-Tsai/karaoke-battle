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
