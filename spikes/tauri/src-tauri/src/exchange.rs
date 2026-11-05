use crate::COLUMNS;
use calamine::{Data, Reader, Xlsx};
use roxmltree::{Document, ParsingOptions};
use rust_xlsxwriter::Workbook;
use serde_json::Value;
use std::io::{Cursor, Read};

const MAX_FILE: usize = 8 * 1024 * 1024;
const MAX_EXPANDED: u64 = 32 * 1024 * 1024;

fn xml(source: &str) -> Result<Document<'_>, String> {
    if source.to_ascii_uppercase().contains("<!DOCTYPE")
        || source.to_ascii_uppercase().contains("<!ENTITY")
    {
        return Err("DTD and entity declarations are not accepted.".into());
    }
    Document::parse_with_options(
        source,
        ParsingOptions {
            allow_dtd: false,
            nodes_limit: 1_000_000,
            ..Default::default()
        },
    )
    .map_err(|error| error.to_string())
}

fn cell_reference(value: &str) -> Result<(), String> {
    let bytes = value.as_bytes();
    if bytes.len() < 2
        || !matches!(bytes[0], b'A'..=b'G')
        || !bytes[1..].iter().all(u8::is_ascii_digit)
        || !value[1..]
            .parse::<u32>()
            .is_ok_and(|row| (1..=10001).contains(&row))
    {
        return Err("Only seven columns and at most 10,000 data rows are accepted.".into());
    }
    Ok(())
}

pub fn preview_xlsx(bytes: &[u8]) -> Result<usize, String> {
    if bytes.len() > MAX_FILE {
        return Err("File exceeds 8 MiB.".into());
    }
    let mut archive =
        zip::ZipArchive::new(Cursor::new(bytes)).map_err(|error| error.to_string())?;
    if archive.len() > 100 {
        return Err("Workbook has too many ZIP entries.".into());
    }
    let mut expanded = 0;
    for index in 0..archive.len() {
        let file = archive.by_index(index).map_err(|error| error.to_string())?;
        if file.is_dir() {
            continue;
        }
        let name = file.name().map_err(|error| error.to_string())?.to_string();
        if !(name.ends_with(".xml") || name.ends_with(".rels")) {
            return Err(
                "Only a plain XLSX workbook is accepted; embedded objects are not supported."
                    .into(),
            );
        }
        if file.size() > MAX_EXPANDED - expanded {
            return Err("Workbook exceeds the expanded-size limit.".into());
        }
        let mut content = Vec::new();
        file.take(MAX_EXPANDED - expanded + 1)
            .read_to_end(&mut content)
            .map_err(|error| error.to_string())?;
        expanded += content.len() as u64;
        if expanded > MAX_EXPANDED {
            return Err("Workbook exceeds the expanded-size limit.".into());
        }
        let source = std::str::from_utf8(&content).map_err(|error| error.to_string())?;
        let document = xml(source)?;
        for node in document.descendants().filter(|node| node.is_element()) {
            if node.tag_name().name() == "f" || node.attribute("TargetMode") == Some("External") {
                return Err("Formulas and external links are not accepted.".into());
            }
            if name.starts_with("xl/worksheets/") {
                if node.tag_name().name() == "c" {
                    cell_reference(node.attribute("r").unwrap_or(""))?;
                }
                if node.tag_name().name() == "dimension" {
                    for reference in node.attribute("ref").unwrap_or("").split(':') {
                        cell_reference(reference)?;
                    }
                }
            }
        }
    }
    let mut workbook = Xlsx::new(Cursor::new(bytes)).map_err(|error| error.to_string())?;
    if workbook.sheet_names().len() != 1 {
        return Err("Select a workbook with exactly one sheet.".into());
    }
    let sheet = workbook
        .worksheet_range_at(0)
        .ok_or("Missing sheet.")?
        .map_err(|error| error.to_string())?;
    if sheet.width() != 7 || !(1..=10001).contains(&sheet.height()) {
        return Err("Expected seven columns and at most 10,000 data rows.".into());
    }
    for row in sheet.rows() {
        if row
            .iter()
            .any(|cell| !matches!(cell, Data::String(_) | Data::Empty))
        {
            return Err("Use text cells for identifiers and partial dates. Numeric, date, and formula cells are rejected.".into());
        }
    }
    let header = sheet.rows().next().ok_or("Missing header.")?;
    if header
        .iter()
        .zip(COLUMNS)
        .any(|(cell, name)| !matches!(cell, Data::String(text) if text == name))
    {
        return Err("Expected the seven comparison columns.".into());
    }
    Ok(sheet.height() - 1)
}

pub fn xlsx_projection(rows: &[Value]) -> Result<Vec<u8>, String> {
    if rows.len() > 10000 {
        return Err("The comparison exports at most 10,000 editions.".into());
    }
    let mut workbook = Workbook::new();
    let sheet = workbook.add_worksheet();
    for (column, name) in COLUMNS.iter().enumerate() {
        sheet
            .write_string(0, column as u16, *name)
            .map_err(|error| error.to_string())?;
        for (row, edition) in rows.iter().enumerate() {
            sheet
                .write_string(
                    (row + 1) as u32,
                    column as u16,
                    edition[*name].as_str().unwrap_or(""),
                )
                .map_err(|error| error.to_string())?;
        }
    }
    workbook.save_to_buffer().map_err(|error| error.to_string())
}

pub fn preview_onix(bytes: &[u8]) -> Result<usize, String> {
    if bytes.len() > MAX_FILE {
        return Err("File exceeds 8 MiB.".into());
    }
    let source = std::str::from_utf8(bytes).map_err(|error| error.to_string())?;
    let document = xml(source)?;
    let root = document.root_element();
    if root.tag_name().name() != "ONIXMessage" || root.attribute("release") != Some("3.0") {
        return Err("Only the illustrative ONIX 3.0 profile is accepted.".into());
    }
    let products: Vec<_> = root
        .children()
        .filter(|node| node.has_tag_name("Product"))
        .collect();
    if !(1..=10000).contains(&products.len()) {
        return Err("Expected 1-10,000 illustrative products.".into());
    }
    for product in &products {
        for field in ["RecordReference", "IDValue", "TitleText"] {
            if !product.descendants().any(|node| {
                node.has_tag_name(field) && node.text().is_some_and(|text| !text.trim().is_empty())
            }) {
                return Err(format!("Product is missing {field}."));
            }
        }
    }
    Ok(products.len())
}

fn escaped(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

pub fn onix_projection(rows: &[Value]) -> Result<Vec<u8>, String> {
    if !(1..=10000).contains(&rows.len()) {
        return Err("Expected 1-10,000 editions.".into());
    }
    let mut result = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!-- Synthetic projection only; not a complete or recipient-certified ONIX feed. --><ONIXMessage release=\"3.0\"><Header><Sender><SenderName>Synthetic publisher</SenderName></Sender><SentDateTime>20300101</SentDateTime></Header>",
    );
    for row in rows {
        let id = escaped(row["id"].as_str().ok_or("Missing edition ID.")?);
        let title = escaped(row["title"].as_str().ok_or("Missing title.")?);
        let form = match row["format"].as_str() {
            Some("paperback") => "BC",
            Some("ebook") => "DG",
            _ => return Err("This illustrative profile supports paperback and ebook only.".into()),
        };
        let identifier = match row["isbn13"].as_str() {
            Some(isbn) => format!(
                "<ProductIDType>15</ProductIDType><IDValue>{}</IDValue>",
                escaped(isbn)
            ),
            None => format!(
                "<ProductIDType>01</ProductIDType><IDTypeName>Bookalog synthetic</IDTypeName><IDValue>{id}</IDValue>"
            ),
        };
        result.push_str(&format!("<Product><RecordReference>{id}</RecordReference><NotificationType>03</NotificationType><ProductIdentifier>{identifier}</ProductIdentifier><DescriptiveDetail><ProductComposition>00</ProductComposition><ProductForm>{form}</ProductForm><TitleDetail><TitleType>01</TitleType><TitleElement><TitleElementLevel>01</TitleElementLevel><TitleText>{title}</TitleText></TitleElement></TitleDetail></DescriptiveDetail></Product>"));
    }
    result.push_str("</ONIXMessage>");
    Ok(result.into_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn workbook_with(content: &str) -> Vec<u8> {
        let mut archive = zip::ZipWriter::new(Cursor::new(Vec::new()));
        archive
            .start_file(
                "xl/worksheets/sheet1.xml",
                zip::write::SimpleFileOptions::default(),
            )
            .unwrap();
        archive.write_all(content.as_bytes()).unwrap();
        archive.finish().unwrap().into_inner()
    }

    #[test]
    fn native_xlsx_preserves_text_and_round_trips_5000_rows() {
        assert_eq!(
            preview_xlsx(include_bytes!("../../../fixtures/generated/catalog.xlsx")).unwrap(),
            12
        );
        let fixture: Value = serde_json::from_str(crate::FIXTURE).unwrap();
        let rows = fixture["editions"].as_array().unwrap();
        let bytes = xlsx_projection(rows).unwrap();
        assert_eq!(preview_xlsx(&bytes).unwrap(), 5000);
        let mut workbook = Xlsx::new(Cursor::new(bytes)).unwrap();
        let sheet = workbook.worksheet_range_at(0).unwrap().unwrap();
        assert_eq!(
            sheet.get_value((5, 2)),
            Some(&Data::String(rows[4]["title"].as_str().unwrap().into()))
        );
        assert_eq!(
            sheet.get_value((2, 4)),
            Some(&Data::String(rows[1]["isbn13"].as_str().unwrap().into()))
        );
        assert_eq!(sheet.get_value((2, 6)), Some(&Data::String("2030".into())));
    }

    #[test]
    fn workbook_preflight_rejects_malformed_and_unsafe_input() {
        assert!(
            preview_xlsx(include_bytes!("../../../fixtures/generated/malformed.xlsx")).is_err()
        );
        for content in [
            "<worksheet><sheetData><row><c r=\"XFD1048576\"/></row></sheetData></worksheet>",
            "<worksheet><sheetData><row><c r=\"A1\"><f>1+1</f></c></row></sheetData></worksheet>",
            "<!DOCTYPE x [<!ENTITY x SYSTEM \"file:///synthetic\">]><worksheet/>",
            "<Relationships><Relationship TargetMode=\"External\"/></Relationships>",
        ] {
            assert!(preview_xlsx(&workbook_with(content)).is_err());
        }
    }

    #[test]
    fn workbook_byte_and_expansion_limits_reject_input_before_parsing() {
        assert!(
            preview_xlsx(&vec![0; MAX_FILE + 1])
                .unwrap_err()
                .contains("8 MiB")
        );
        let mut bytes = workbook_with("<worksheet/>");
        let offset = bytes
            .windows(4)
            .position(|value| value == [0x50, 0x4b, 1, 2])
            .unwrap();
        bytes[offset + 24..offset + 28].copy_from_slice(&((MAX_EXPANDED + 1) as u32).to_le_bytes());
        assert!(preview_xlsx(&bytes).unwrap_err().contains("expanded-size"));
    }

    #[test]
    fn illustrative_onix_round_trips_and_rejects_entities() {
        assert_eq!(
            preview_onix(include_bytes!(
                "../../../fixtures/generated/illustrative-onix.xml"
            ))
            .unwrap(),
            1
        );
        let fixture: Value = serde_json::from_str(crate::FIXTURE).unwrap();
        assert_eq!(
            preview_onix(&onix_projection(fixture["editions"].as_array().unwrap()).unwrap())
                .unwrap(),
            5000
        );
        for bytes in [
            include_bytes!("../../../fixtures/generated/malformed-onix.xml").as_slice(),
            include_bytes!("../../../fixtures/generated/external-entity.xml").as_slice(),
            b"<ONIXMessage release=\"3.0\"><Product/></ONIXMessage>",
        ] {
            assert!(preview_onix(bytes).is_err());
        }
        let mut row = fixture["editions"][0].clone();
        row["title"] = Value::String("A & B <C> \"\u{e9}\"".into());
        let output = onix_projection(&[row]).unwrap();
        let source = String::from_utf8(output).unwrap();
        let document = xml(&source).unwrap();
        assert!(
            document
                .descendants()
                .any(|node| node.has_tag_name("TitleText")
                    && node.text() == Some("A & B <C> \"\u{e9}\""))
        );
    }
}
