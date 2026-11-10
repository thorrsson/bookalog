import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import readXlsxFile from "read-excel-file/node";

const path = process.argv[2];
assert.ok(path, "Pass the disposable exported workbook path.");
const expected = JSON.parse(await readFile(`${path}.json`, "utf8"));
const sheets = await readXlsxFile(path);
assert.equal(sheets.length, 1, "The workbook must contain exactly one sheet.");
const actual = sheets[0].data;
assert.equal(actual.length, 5001, "The workbook must contain every edition plus its header.");
assert.equal(expected.length, actual.length);
for (let index = 0; index < actual.length; index++) {
  assert.ok(actual[index].length <= expected[0].length, `Unexpected columns in row ${index + 1}`);
  const row = Array.from({ length: expected[0].length }, (_, column) => actual[index][column] ?? "");
  assert.ok(row.every((value) => typeof value === "string"), `Non-text cell in row ${index + 1}`);
  assert.deepEqual(row, expected[index], `Changed value in row ${index + 1}`);
}
console.log("Independent XLSX reader verified all ten fields of all 5,000 production-profile editions.");
