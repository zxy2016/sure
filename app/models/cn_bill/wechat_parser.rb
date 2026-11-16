# WeChat Pay bill export ("用于个人对账" xlsx). The sheet carries ~17 rows of
# metadata before the real header row (交易时间/交易类型/.../备注). Amounts are
# unsigned with a separate 收/支 direction column; 支付方式 tells which account
# actually moved the money (零钱/零钱通 vs a bank card).
class CnBill::WechatParser
  HEADER = "交易时间".freeze
  # Excel serial dates count days from 1899-12-30 (the 1900 leap-year bug base).
  EXCEL_EPOCH = Date.new(1899, 12, 30)

  def self.parse(content)
    new.parse(content)
  end

  def parse(content)
    rows = sheet_rows(content)
    header_index = rows.index { |r| r[0].to_s.strip == HEADER }
    raise CnBill::Error, "未找到微信账单表头（交易时间）" unless header_index

    rows[(header_index + 1)..].filter_map do |r|
      next if r[0].blank?
      {
        date: parse_date(r[0]),
        type: CnBill.clean(r[1]),
        party: CnBill.clean(r[2]),
        product: CnBill.clean(r[3]),
        direction: CnBill.clean(r[4]),
        amount: CnBill.amount(r[5]),
        method: CnBill.clean(r[6]),
        status: CnBill.clean(r[7]),
        txn_id: CnBill.clean(r[8]),
        note: CnBill.clean(r[10])
      }
    end.uniq { |r| r[:txn_id].presence || [ r[:date], r[:amount], r[:party] ] }
  end

  private
    def parse_date(value)
      if value.is_a?(Numeric) || value.to_s.match?(/\A\d+(\.\d+)?\z/)
        (EXCEL_EPOCH + BigDecimal(value.to_s).floor).iso8601
      else
        CnBill.date(value)
      end
    end

    # Minimal xlsx reader: shared strings + first worksheet, no extra gems.
    def sheet_rows(content)
      shared = []
      sheet_xml = nil
      Zip::File.open_buffer(StringIO.new(content)) do |zip|
        if (entry = zip.find_entry("xl/sharedStrings.xml"))
          doc = Nokogiri::XML(entry.get_input_stream.read)
          doc.remove_namespaces!
          shared = doc.xpath("//si").map { |si| si.xpath(".//t").map(&:text).join }
        end
        entry = zip.find_entry("xl/worksheets/sheet1.xml") ||
                zip.glob("xl/worksheets/*.xml").first
        raise CnBill::Error, "xlsx 中没有工作表" unless entry
        sheet_xml = entry.get_input_stream.read
      end

      doc = Nokogiri::XML(sheet_xml)
      doc.remove_namespaces!
      doc.xpath("//sheetData/row").map do |row|
        cells = {}
        row.xpath("./c").each do |c|
          col = c["r"].to_s[/\A[A-Z]+/]
          next unless col
          cells[col] = cell_value(c, shared)
        end
        next [] if cells.empty?
        last = cells.keys.map { |k| column_index(k) }.max
        (0..last).map { |i| cells[column_letter(i)] }
      end
    end

    def cell_value(cell, shared)
      case cell["t"]
      when "s" then shared[cell.at_xpath("./v")&.text.to_i]
      when "inlineStr" then cell.xpath(".//t").map(&:text).join
      else cell.at_xpath("./v")&.text
      end
    end

    def column_index(letters)
      letters.each_char.reduce(0) { |acc, ch| acc * 26 + (ch.ord - 64) } - 1
    end

    def column_letter(index)
      result = +""
      index += 1
      while index > 0
        index, rem = (index - 1).divmod(26)
        result.prepend((rem + 65).chr)
      end
      result
    end
end
