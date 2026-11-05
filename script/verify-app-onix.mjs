import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { XMLParser, XMLValidator } from "fast-xml-parser";

const path = process.argv[2];
assert.ok(path, "Pass the disposable exported ONIX path.");
const xml = await readFile(path, "utf8");
assert.equal(XMLValidator.validate(xml), true);
const expected = JSON.parse(await readFile(`${path}.json`, "utf8"));
const document = new XMLParser({
  ignoreAttributes: false, parseTagValue: false, trimValues: false,
  htmlEntities: true, // Includes numeric XML references such as the preserved CR (&#13;).
  isArray: (name) => name === "Product" || name === "ProductIdentifier",
}).parse(xml).ONIXMessage;
assert.equal(document["@_release"], "3.0");
assert.equal(document["@_xmlns"], "http://ns.editeur.org/onix/3.0/reference");
assert.equal(document.Header.Sender.SenderName, "Example Press");
assert.equal(document.Header.SentDateTime, "20300102T030405Z");
assert.equal(document.Product.length, 5000);
const forms = { BC: "paperback", BB: "hardback", EA: "ebook", AA: "audio" };
const languages = { eng: "en", fre: "fr", ger: "de", jpn: "ja" };
const statuses = { "01/02": "planned", "02/02": "announced", "03/04": "released", "03/07": "out_of_print" };
for (const [index, product] of document.Product.entries()) {
  const identifier = product.ProductIdentifier.find((item) => item.ProductIDType === "01");
  assert.equal(identifier.IDTypeName, "Bookalog edition");
  assert.equal(product.RecordReference, `urn:uuid:${identifier.IDValue}`);
  const work = product.RelatedMaterial.RelatedWork;
  assert.equal(work.WorkRelationCode, "01");
  assert.equal(work.WorkIdentifier.IDTypeName, "Bookalog work");
  const detail = product.DescriptiveDetail;
  const publishing = product.PublishingDetail;
  assert.equal(publishing.Publisher.PublisherName, "Example Press");
  const date = publishing.PublishingDate.Date;
  const raw = date["#text"];
  const release = date["@_dateformat"] === "05" ? raw
    : date["@_dateformat"] === "01" ? `${raw.slice(0, 4)}-${raw.slice(4, 6)}`
      : `${raw.slice(0, 4)}-${raw.slice(4, 6)}-${raw.slice(6, 8)}`;
  assert.deepEqual({
    id: identifier.IDValue,
    work_id: work.WorkIdentifier.IDValue,
    title: detail.TitleDetail.TitleElement.TitleText,
    format: forms[detail.ProductForm],
    language: languages[detail.Language.LanguageCode],
    isbn13: product.ProductIdentifier.find((item) => item.ProductIDType === "15")?.IDValue ?? "",
    publication_status: statuses[`${product.NotificationType}/${publishing.PublishingStatus}`],
    release_date: release,
    description: product.CollateralDetail.TextContent.Text["#text"],
  }, expected[index], `Changed ONIX metadata at product ${index + 1}`);
}
console.log("Independent ONIX reader verified all nine projected fields of all 5,000 editions.");
