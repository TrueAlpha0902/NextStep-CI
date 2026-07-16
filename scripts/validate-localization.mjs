import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const appRoot = path.join(repoRoot, "Sources", "NotesApp");
const catalogPath = path.join(appRoot, "Resources", "Localizable.xcstrings");
const catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
const catalogKeys = new Set(Object.keys(catalog.strings ?? {}));
const locales = ["en", "zh-Hant"];
const failures = [];

for (const [key, entry] of Object.entries(catalog.strings ?? {})) {
  for (const locale of locales) {
    const unit = entry?.localizations?.[locale]?.stringUnit;
    if (!unit || unit.state !== "translated" || typeof unit.value !== "string") {
      failures.push(`Catalog key ${JSON.stringify(key)} is missing a translated ${locale} string.`);
    }
  }
}

const swiftFiles = [];
function collect(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const candidate = path.join(directory, entry.name);
    if (entry.isDirectory()) collect(candidate);
    else if (entry.isFile() && candidate.endsWith(".swift")) swiftFiles.push(candidate);
  }
}
collect(appRoot);

const localizedCall = /(?:(?:String\s*\(\s*localized:\s*)|(?:(?:Text|Label|Button|Picker|Section|ProgressView|TextField|LabeledContent|navigationTitle|accessibilityLabel|accessibilityValue)\s*\(\s*))"((?:\\.|[^"\\])*)"/g;
for (const file of swiftFiles) {
  const source = fs.readFileSync(file, "utf8");
  for (const match of source.matchAll(localizedCall)) {
    const key = match[1].replaceAll('\\"', '"').replaceAll('\\n', "\n");
    if (!catalogKeys.has(key)) {
      failures.push(`${path.relative(repoRoot, file)} uses missing localization key ${JSON.stringify(key)}.`);
    }
  }
}

if (failures.length > 0) {
  for (const failure of failures) process.stderr.write(`${failure}\n`);
  process.exit(1);
}

process.stdout.write(`Localization catalog covers ${catalogKeys.size} keys in ${locales.join(" and ")}.\n`);
