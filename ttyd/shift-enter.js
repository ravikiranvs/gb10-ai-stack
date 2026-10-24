/* gb10-shift-enter: make Shift+Enter insert a new line in Claude Code and similar full-screen programs.
   A terminal sends the same character for Enter and Shift+Enter, so Claude Code cannot tell them apart and submits. Claude Code treats a
   backslash followed by Enter as "insert a new line" (in bash the same keys are a harmless line continuation), so Shift+Enter sends exactly that.
   The handler runs in the capture phase so it sees the key before the terminal does; every other key, and Enter with Ctrl, Alt or Meta, is left alone. */
(function () {
  var NEWLINE = "\\\r";   /* a backslash, then Enter */
  document.addEventListener("keydown", function (e) {
    if (e.key !== "Enter" || !e.shiftKey || e.ctrlKey || e.altKey || e.metaKey || e.isComposing) { return; }
    var term = window.term;
    if (!term) { return; }
    e.preventDefault();
    e.stopImmediatePropagation();
    if (typeof term.input === "function") { term.input(NEWLINE, true); }
    else if (term._core && term._core.coreService) { term._core.coreService.triggerDataEvent(NEWLINE, true); }
  }, true);
})();
