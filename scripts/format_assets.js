const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const files = ["subjectGraph.js", "assistant.js", "aggregateGraph.js"].map((f) =>
  path.join(root, "assets", f)
);

function formatJs(input) {
  let out = "";
  let indent = 0;
  let quote = null;
  let escaped = false;
  let inRegex = false;
  let regexClass = false;

  function newline(extra = 0) {
    out = out.replace(/[ \t]+$/g, "");
    out += "\n" + "  ".repeat(Math.max(0, indent + extra));
  }

  function prevSig() {
    for (let i = out.length - 1; i >= 0; i--) {
      const c = out[i];
      if (!/\s/.test(c)) return c;
    }
    return "";
  }

  for (let i = 0; i < input.length; i++) {
    const c = input[i];
    const p = prevSig();

    if (quote) {
      out += c;
      if (escaped) escaped = false;
      else if (c === "\\") escaped = true;
      else if (c === quote) quote = null;
      continue;
    }

    if (inRegex) {
      out += c;
      if (escaped) escaped = false;
      else if (c === "\\") escaped = true;
      else if (c === "[") regexClass = true;
      else if (c === "]") regexClass = false;
      else if (c === "/" && !regexClass) inRegex = false;
      continue;
    }

    if (c === "'" || c === '"' || c === "`") {
      quote = c;
      out += c;
      continue;
    }

    if (
      c === "/" &&
      "({[=,:!&|?;".includes(p) &&
      input[i + 1] !== "/" &&
      input[i + 1] !== "*"
    ) {
      inRegex = true;
      out += c;
      continue;
    }

    if (c === "{") {
      out += c;
      indent++;
      newline();
    } else if (c === "}") {
      indent--;
      newline();
      out += c;
      if (input[i + 1] !== ")" && input[i + 1] !== "," && input[i + 1] !== ";") {
        newline();
      }
    } else if (c === ";") {
      out += c;
      newline();
    } else if (c === "," && input[i + 1] !== " ") {
      out += c + " ";
    } else {
      out += c;
    }
  }

  return out
    .split("\n")
    .map((line) => line.replace(/[ \t]+$/g, ""))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trimStart() + "\n";
}

for (const file of files) {
  fs.writeFileSync(file, formatJs(fs.readFileSync(file, "utf8")));
}
