globalThis.logseqHighlightCode = function(request) {
  const {text, language} = JSON.parse(request);
  if (typeof text !== "string" || typeof language !== "string" || text.length > 100000) return "[]";
  const name = language.trim().toLowerCase();
  if (!name || name === "calc" || name === "plaintext") return "[]";
  const info = CodeMirror.findModeByName(name) || CodeMirror.findModeByMIME(name) || CodeMirror.findModeByExtension(name);
  if (!info || !Object.prototype.hasOwnProperty.call(modes, info.mode)) return "[]";
  load(modes[info.mode]);
  // runMode normalizes line endings. Locate tokens in the original UTF-16 text
  // so CRLF, astral characters, tabs and trailing blank lines remain untouched.
  const starts = [0], endings = /\r\n?|\n/g;
  let match;
  while ((match = endings.exec(text))) starts.push(match.index + match[0].length);
  const spans = [];
  CodeMirror.runMode(text, info.mime, function(token, style, line, column) {
    if (!style || line === undefined) return;
    const start = starts[line] + column;
    spans.push([start, start + token.length, style]);
  });
  return JSON.stringify(spans);
};
