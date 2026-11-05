#!/usr/bin/env ruby
# frozen_string_literal: true

require 'csv'
require 'json'
require 'fileutils'
require 'tmpdir'
require 'open3'
require 'cgi'

root = File.expand_path('../spikes/fixtures/generated', __dir__)
FileUtils.mkdir_p(root)
uuid = ->(number) { format('00000000-0000-4000-8000-%012d', number) }
isbn = lambda do |number|
  digits = "978#{format('%09d', number)}"
  sum = digits.chars.each_with_index.sum { |digit, index| digit.to_i * (index.even? ? 1 : 3) }
  "#{digits}#{(10 - sum % 10) % 10}"
end
titles = ['A Synthetic Atlas', 'Synthetic Ocean, Volume "Two"', "Synthetic Caf\u00e9",
          "Synthetic \u65e5\u672c\u8a9e", '=Synthetic spreadsheet text']
dates = [nil, '2030', '2030-02', '2030-02-28']
editions = 5_000.times.map do |index|
  {
    'id' => uuid.call(index + 1),
    'work_id' => uuid.call(100_000 + index / 2),
    'title' => "#{titles[index % titles.length]} #{index / 2 + 1}",
    'format' => index.even? ? 'paperback' : 'ebook',
    'isbn13' => (index % 7).zero? ? nil : isbn.call(index),
    'publication_status' => %w[planned announced released out_of_print][index % 4],
    'release_date' => dates[index % dates.length],
    'contributors' => [
      { 'name' => "Synthetic Author #{index % 40}", 'role' => 'author' },
      { 'name' => "Synthetic Translator #{index % 13}", 'role' => 'translator' }
    ],
    'categories' => [index.even? ? 'Fiction' : 'Nonfiction', 'Synthetic'],
    'description' => (index % 11).zero? ? "Synthetic long description.\n" * 100 : 'Synthetic comparison record.',
    'cover_key' => (index % 3).zero? ? nil : 'synthetic-cover.png',
    'revision' => 1
  }
end
File.write(File.join(root, 'catalog.json'), JSON.generate({ 'synthetic' => true, 'editions' => editions }))
%w[flutter/assets tauri/public].each do |target|
  directory = File.expand_path("../spikes/#{target}", __dir__)
  FileUtils.mkdir_p(directory)
  FileUtils.cp(File.join(root, 'catalog.json'), File.join(directory, 'catalog.json'))
end
File.write(File.join(root, 'duplicate.json'), JSON.generate([editions[1], editions[1].merge('id' => uuid.call(999_999))]))
File.write(File.join(root, 'malformed.json'), '{"editions":[')

columns = %w[id work_id title format isbn13 publication_status release_date]
CSV.open(File.join(root, 'catalog.csv'), 'w', write_headers: true, headers: columns) do |csv|
  editions.first(12).each { |edition| csv << columns.map { |column| edition[column] } }
end
File.write(File.join(root, 'malformed.csv'), "title,isbn13\n\"unterminated,9780000000000")

# A minimal workbook with inline strings preserves identifiers without spreadsheet coercion.
Dir.mktmpdir('bookalog-xlsx') do |directory|
  FileUtils.mkdir_p(File.join(directory, '_rels'))
  FileUtils.mkdir_p(File.join(directory, 'xl/_rels'))
  FileUtils.mkdir_p(File.join(directory, 'xl/worksheets'))
  File.write(File.join(directory, '[Content_Types].xml'), <<~XML)
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
  XML
  File.write(File.join(directory, '_rels/.rels'), <<~XML)
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
  XML
  File.write(File.join(directory, 'xl/workbook.xml'), <<~XML)
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets><sheet name="Synthetic editions" sheetId="1" r:id="rId1"/></sheets>
    </workbook>
  XML
  File.write(File.join(directory, 'xl/_rels/workbook.xml.rels'), <<~XML)
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    </Relationships>
  XML
  rows = [columns] + editions.first(12).map { |edition| columns.map { |column| edition[column].to_s } }
  xml_rows = rows.each_with_index.map do |row, row_index|
    cells = row.each_with_index.map do |value, column|
      %(<c r="#{(65 + column).chr}#{row_index + 1}" t="inlineStr"><is><t>#{CGI.escapeHTML(value)}</t></is></c>)
    end.join
    %(<row r="#{row_index + 1}">#{cells}</row>)
  end.join
  File.write(File.join(directory, 'xl/worksheets/sheet1.xml'), <<~XML)
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>#{xml_rows}</sheetData></worksheet>
  XML
  output = File.join(root, 'catalog.xlsx')
  File.delete(output) if File.exist?(output)
  _, error, status = Open3.capture3('zip', '-q', '-X', '-r', output, '.', chdir: directory)
  abort("Workbook fixture generation failed: #{error}") unless status.success?
end
File.write(File.join(root, 'malformed.xlsx'), 'Not a ZIP archive')
File.write(File.join(root, 'illustrative-onix.xml'), <<~XML)
  <?xml version="1.0" encoding="UTF-8"?>
  <!-- Synthetic parser fixture, NOT a complete or recipient-certified ONIX product. -->
  <ONIXMessage release="3.0">
    <Header><Sender><SenderName>Synthetic publisher</SenderName></Sender><SentDateTime>20300101</SentDateTime></Header>
    <Product>
      <RecordReference>synthetic-1</RecordReference><NotificationType>03</NotificationType>
      <ProductIdentifier><ProductIDType>15</ProductIDType><IDValue>#{isbn.call(1)}</IDValue></ProductIdentifier>
      <DescriptiveDetail><ProductComposition>00</ProductComposition><ProductForm>BC</ProductForm>
        <TitleDetail><TitleType>01</TitleType><TitleElement><TitleElementLevel>01</TitleElementLevel><TitleText>Synthetic Atlas</TitleText></TitleElement></TitleDetail>
      </DescriptiveDetail>
    </Product>
  </ONIXMessage>
XML
File.write(File.join(root, 'malformed-onix.xml'), '<ONIXMessage><Product></ONIXMessage>')
File.write(File.join(root, 'external-entity.xml'), '<!DOCTYPE x [<!ENTITY probe SYSTEM "file:///not-a-real-bookalog-fixture">]><ONIXMessage>&probe;</ONIXMessage>')
puts "Generated #{editions.length} synthetic editions and exchange fixtures."
