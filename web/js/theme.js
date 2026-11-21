// Runs before first paint (loaded in <head>) so the page never flashes the wrong theme.
(function () {
  var t = "light";
  try { if (localStorage.getItem("wz_theme") === "dark") t = "dark"; } catch (e) {}
  document.documentElement.setAttribute("data-theme", t);
})();
