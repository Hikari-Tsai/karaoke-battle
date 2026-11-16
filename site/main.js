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
