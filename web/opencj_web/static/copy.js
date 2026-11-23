// Copy buttons: <button data-copy-target="element-id" hidden>. The button stays
// hidden without JavaScript, so visitors never see a button that does nothing.
(function () {
  "use strict";

  var CONFIRMATION_MS = 2000;

  function selectText(element) {
    var range = document.createRange();
    range.selectNodeContents(element);
    var selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }

  function showResult(button, label) {
    var originalLabel = button.dataset.label;
    button.textContent = label;
    window.clearTimeout(button.resetTimer);
    button.resetTimer = window.setTimeout(function () {
      button.textContent = originalLabel;
    }, CONFIRMATION_MS);
  }

  function copyFromButton(button) {
    var source = document.getElementById(button.dataset.copyTarget);
    if (!source) {
      return;
    }
    var text = source.textContent.trim();
    // The clipboard API needs HTTPS or localhost; elsewhere, select the text
    // so the visitor can press Ctrl+C.
    if (!navigator.clipboard || !window.isSecureContext) {
      selectText(source);
      showResult(button, "Press Ctrl+C");
      return;
    }
    navigator.clipboard.writeText(text).then(function () {
      showResult(button, "Copied");
    }, function () {
      selectText(source);
      showResult(button, "Press Ctrl+C");
    });
  }

  var buttons = document.querySelectorAll("button[data-copy-target]");
  for (var index = 0; index < buttons.length; index++) {
    var button = buttons[index];
    button.dataset.label = button.textContent;
    button.hidden = false;
    button.addEventListener("click", function (event) {
      copyFromButton(event.currentTarget);
    });
  }
})();
