// Copy buttons: <button data-copy-target="element-id" hidden> inside .command-box,
// followed by a .copy-status element. The button stays hidden without
// JavaScript, so visitors never see a button that does nothing.
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

  function findStatus(button) {
    var box = button.closest(".command-box");
    var status = box ? box.nextElementSibling : null;
    if (status && status.classList.contains("copy-status")) {
      return status;
    }
    return null;
  }

  // Show the checkmark (copied) or a hint (selected for manual copy), then reset.
  // The "done" class swaps the copy icon for the checkmark (see style.css).
  function showResult(button, copied, message) {
    var status = findStatus(button);
    button.classList.toggle("done", copied);
    button.title = copied ? "Copied" : "Copy";
    if (status) {
      status.textContent = message;
    }
    window.clearTimeout(button.resetTimer);
    button.resetTimer = window.setTimeout(function () {
      button.classList.remove("done");
      button.title = "Copy";
      if (status) {
        status.textContent = "";
      }
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
      showResult(button, false, "Selected. Press Ctrl+C to copy.");
      return;
    }
    navigator.clipboard.writeText(text).then(function () {
      showResult(button, true, "Copied");
    }, function () {
      selectText(source);
      showResult(button, false, "Selected. Press Ctrl+C to copy.");
    });
  }

  var buttons = document.querySelectorAll("button[data-copy-target]");
  for (var index = 0; index < buttons.length; index++) {
    var button = buttons[index];
    button.hidden = false;
    button.addEventListener("click", function (event) {
      copyFromButton(event.currentTarget);
    });
  }
})();
