import { XMLParser, XMLValidator } from 'fast-xml-parser';

export function inspectIllustrativeOnix(source) {
  if (Buffer.byteLength(source, 'utf8') > 8 * 1024 * 1024) throw new Error('The parser probe accepts up to 8 MiB.');
  if (/<!\s*(DOCTYPE|ENTITY)\b/i.test(source)) throw new Error('DTDs and external entities are not permitted.');
  if (XMLValidator.validate(source) !== true) throw new Error('Malformed XML.');
  const parsed = new XMLParser({ parseTagValue: false, processEntities: false, ignoreAttributes: false }).parse(source);
  if (!parsed.ONIXMessage || parsed.ONIXMessage['@_release'] !== '3.0') {
    throw new Error('This probe only inspects the illustrative ONIX 3.0 fixture; it is not an ONIX importer.');
  }
  return parsed.ONIXMessage;
}
