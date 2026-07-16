import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "..");
const schemaDirectory = path.join(repositoryRoot, "Schemas", "AI");
const expectedFiles = [
  "citation.schema.json",
  "daily-action.schema.json",
  "document-parse.schema.json",
  "guided-learning-package.schema.json",
  "highlight.schema.json",
  "ink-recognition.schema.json",
  "paper-search.schema.json",
  "quiz.schema.json",
  "replan.schema.json",
  "source-verification.schema.json",
  "weekly-plan.schema.json"
].sort();

const actualFiles = fs.readdirSync(schemaDirectory)
  .filter((name) => name.endsWith(".json"))
  .sort();
assert(
  JSON.stringify(actualFiles) === JSON.stringify(expectedFiles),
  `AI schema inventory differs: ${actualFiles.join(", ")}`
);

const ids = new Set();
const schemaVersions = new Map([
  ["document-parse.schema.json", 2]
]);
for (const fileName of actualFiles) {
  const filePath = path.join(schemaDirectory, fileName);
  let schema;
  try {
    schema = JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    throw new Error(`${fileName} is not valid JSON: ${error.message}`);
  }

  assert(
    schema.$schema === "https://json-schema.org/draft/2020-12/schema",
    `${fileName} must declare Draft 2020-12`
  );
  assert(
    typeof schema.$id === "string"
      && schema.$id.startsWith("https://nextstep.local/schemas/ai/"),
    `${fileName} has an invalid canonical $id`
  );
  assert(!ids.has(schema.$id), `${fileName} reuses schema $id ${schema.$id}`);
  ids.add(schema.$id);
  assert(schema.type === "object", `${fileName} root must be an object`);
  assert(
    schema.additionalProperties === false,
    `${fileName} root must reject unknown fields`
  );
  assert(
    schema.properties?.schemaVersion?.const === (schemaVersions.get(fileName) ?? 1),
    `${fileName} must pin its declared schemaVersion`
  );

  const propertyNames = Object.keys(schema.properties ?? {}).sort();
  const requiredNames = [...(schema.required ?? [])].sort();
  assert(
    JSON.stringify(propertyNames) === JSON.stringify(requiredNames),
    `${fileName} must make every envelope field explicit (nullable when unknown)`
  );
  validateNode(schema, fileName, "#");
}

const legacyFileName = "Legacy/document-parse-v1.schema.json";
const legacyFilePath = path.join(schemaDirectory, legacyFileName);
let legacySchema;
try {
  legacySchema = JSON.parse(fs.readFileSync(legacyFilePath, "utf8"));
} catch (error) {
  throw new Error(`${legacyFileName} is not valid JSON: ${error.message}`);
}
assert(
  legacySchema.$schema === "https://json-schema.org/draft/2020-12/schema",
  `${legacyFileName} must declare Draft 2020-12`
);
assert(
  legacySchema.$id === "https://nextstep.local/schemas/ai/document-parse-v1.json",
  `${legacyFileName} has an invalid canonical $id`
);
assert(!ids.has(legacySchema.$id), `${legacyFileName} reuses an active schema $id`);
assert(legacySchema.type === "object", `${legacyFileName} root must be an object`);
assert(
  legacySchema.additionalProperties === false,
  `${legacyFileName} root must reject unknown fields`
);
assert(
  legacySchema.properties?.schemaVersion?.const === 1,
  `${legacyFileName} must pin schemaVersion to 1`
);
assert(
  JSON.stringify(Object.keys(legacySchema.properties ?? {}).sort())
    === JSON.stringify([...(legacySchema.required ?? [])].sort()),
  `${legacyFileName} must make every envelope field explicit`
);
validateNode(legacySchema, legacyFileName, "#");

console.log(
  `AI contract validation passed: ${actualFiles.length} active schemas and 1 legacy migration schema.`
);

function validateNode(node, fileName, location) {
  if (Array.isArray(node)) {
    node.forEach((value, index) => validateNode(
      value,
      fileName,
      `${location}/${index}`
    ));
    return;
  }
  if (node === null || typeof node !== "object") return;

  const declaredTypes = Array.isArray(node.type) ? node.type : [node.type];
  const isObjectSchema = declaredTypes.includes("object")
    || Object.hasOwn(node, "properties");
  if (isObjectSchema) {
    assert(
      node.additionalProperties === false,
      `${fileName} ${location} must reject unknown object fields`
    );
  }
  if (typeof node.$ref === "string") {
    assert(
      node.$ref.startsWith("#/"),
      `${fileName} ${location} may only use local schema references`
    );
  }
  for (const [key, value] of Object.entries(node)) {
    validateNode(value, fileName, `${location}/${escapePointer(key)}`);
  }
}

function escapePointer(value) {
  return value.replaceAll("~", "~0").replaceAll("/", "~1");
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
