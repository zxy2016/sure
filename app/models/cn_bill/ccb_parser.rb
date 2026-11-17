# CCB (建设银行) personal checking statement export (活期账户全部交易明细,
# legacy BIFF .xls from the mobile app / online banking). Header row:
# 序号/摘要/币别/钞汇/交易日期/交易金额/账户余额/交易地点附言/对方账号与户名.
# Amounts are signed (inflows positive), dates are YYYYMMDD strings, and the
# running balance column allows continuity checks like the CMB PDF.
class CnBill::CcbParser
  HEADER = "序号".freeze

  # 客户名称 printed in the metadata rows; used for self-transfer detection.
  attr_reader :account_names

  def initialize
    @account_names = []
  end

  def self.parse(content)
    new.parse(content)
  end

  def parse(content)
    book = Spreadsheet.open(StringIO.new(content))
    sheet = book.worksheet(0)
    rows = sheet.rows.to_a
    rows.first(header_index(rows) || 3).each do |r|
      r.each do |cell|
        name = cell.to_s[/客户名称[:：]\s*(\S+)/, 1]
        @account_names << name if name.present?
      end
    end
    header_index = header_index(rows)
    raise CnBill::Error, "未找到建行账单表头（序号/摘要）" unless header_index

    rows[(header_index + 1)..].filter_map do |r|
      date = r[4].to_s.strip
      next unless date.match?(/\A\d{8}\z/)
      {
        date: "#{date[0, 4]}-#{date[4, 2]}-#{date[6, 2]}",
        summary: r[1].to_s.strip,
        amount: CnBill.amount(r[5]),
        balance: CnBill.amount(r[6]),
        memo: CnBill.clean(r[7]),
        counterparty: CnBill.clean(r[8])
      }
    end.uniq { |r| [ r[:date], r[:amount], r[:balance] ] }
  rescue Ole::Storage::FormatError, IOError => e
    raise CnBill::Error, "无法读取建行 xls 文件（#{e.class.name.demodulize}）"
  end

  # "6214855328267535/张小禹" → "张小禹"; bare account numbers stay as-is.
  def self.party_name(counterparty)
    counterparty.to_s.split("/").last.to_s.strip
  end

  private
    def header_index(rows)
      rows.index { |r| r[0].to_s.strip == HEADER && r[1].to_s.include?("摘要") }
    end
end
